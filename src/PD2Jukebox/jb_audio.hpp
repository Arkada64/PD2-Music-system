// PD2 Jukebox audio core (0.4).
// - Plays one "phase" (1..N variant files with loop points) at a time.
// - Phase changes work like PAYDAY 2's own music events: the new phase starts at once at full volume
//   (no fade-in) while the old one rings out underneath for transition_ms (PD2 uses 2000 ms). 0 = hard cut.
// - All file reading and decoder setup happens on a loader thread, never on the game thread, and the whole
//   song can be preloaded into memory at heist start, so phase changes cost the game nothing.
// - Safety: any non-finite/huge sample mutes the block and logs.
#pragma once
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <condition_variable>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <fstream>
#include <filesystem>
#include "miniaudio.h"

namespace jb {

using Bytes = std::shared_ptr<std::vector<unsigned char>>;

struct Variant { ma_decoder dec; ma_uint64 ls = 0, le = 0; bool ok = false; Bytes data; };

struct Voice {
    std::vector<Variant*> v;
    int cur = 0;
    ~Voice() { for (auto* x : v) { if (x->ok) ma_decoder_uninit(&x->dec); delete x; } }
};

class Player {
public:
    using LogFn = void (*)(const std::string&);
    explicit Player(LogFn log) : log_(log) {}
    ~Player() { shutdown(); }

    // ---- called from the game thread: all of these return immediately ----
    // spec lines: "path|loop_start|loop_end" (UTF-8 path). Empty spec = stop.
    void play(const std::string& spec) { start_loader(); { std::lock_guard<std::mutex> g(lm_); playReq_ = spec; hasPlay_ = true; } lcv_.notify_all(); }
    // spec lines: "path" (or "path|..."): read these files into memory ahead of time. Replaces the previous preload set.
    void preload(const std::string& spec) { start_loader(); { std::lock_guard<std::mutex> g(lm_); preReq_ = spec; hasPre_ = true; } lcv_.notify_all(); }
    void set_volume(float v) { if (!(v >= 0.f)) v = 0.f; if (v > 1.f) v = 1.f; vol_.store(v); }
    void set_transition_ms(int ms) { if (ms < 0) ms = 0; if (ms > 10000) ms = 10000; transMs_.store(ms); }
    bool playing() { return playing_.load(); }
    // called every frame from on_update: frees voices the audio thread no longer uses (cheap when there are none)
    void collect() {
        if (hasRetired_.load()) {
            std::vector<Voice*> dead;
            { std::lock_guard<std::mutex> g(m_); dead.swap(retired_); hasRetired_.store(false); }
            for (auto* d : dead) delete d;
        }
        if (bad_.exchange(false)) log_("bad audio data detected - block muted");
    }

    void shutdown() {
        { std::lock_guard<std::mutex> g(lm_); lstop_ = true; } lcv_.notify_all();
        if (loader_.joinable()) loader_.join();
        { std::lock_guard<std::mutex> g(tm_); stop_ = true; } tcv_.notify_all();
        if (thread_.joinable()) thread_.join();
        std::lock_guard<std::mutex> g(m_);
        delete cur_; cur_ = nullptr; delete fading_; fading_ = nullptr;
        for (auto* r : retired_) delete r; retired_.clear();
    }

private:
    // ---- audio device: its own thread, started on first use (never at mod load, never on the game thread) ----
    bool init_device() {
        std::unique_lock<std::mutex> lk(tm_);
        if (thread_.joinable()) { tcv_.wait(lk, [this] { return ready_; }); return started_; }
        stop_ = false; ready_ = false; started_ = false;
        thread_ = std::thread([this] {
            ma_device_config dc = ma_device_config_init(ma_device_type_playback);
            dc.playback.format = ma_format_f32; dc.playback.channels = 2; dc.sampleRate = 44100;
            dc.dataCallback = &Player::cb_s; dc.pUserData = this;
            dc.periodSizeInMilliseconds = 60;   // music doesn't need low latency: bigger buffer = fewer wake-ups, no crackle under load
            bool ok = ma_device_init(nullptr, &dc, &dev_) == MA_SUCCESS;
            if (ok && ma_device_start(&dev_) != MA_SUCCESS) { ma_device_uninit(&dev_); ok = false; }
            { std::lock_guard<std::mutex> g(tm_); started_ = ok; ready_ = true; }
            tcv_.notify_all();
            log_(ok ? "audio device ready" : "audio device init failed");
            if (!ok) return;
            std::unique_lock<std::mutex> w(tm_);
            tcv_.wait(w, [this] { return stop_; });
            w.unlock();
            ma_device_uninit(&dev_);
        });
        tcv_.wait(lk, [this] { return ready_; });
        return started_;
    }

    // ---- loader thread ----
    void start_loader() {
        std::lock_guard<std::mutex> g(lstart_);
        if (loader_.joinable()) return;
        loader_ = std::thread([this] { loader_main(); });
    }
    void loader_main() {
        for (;;) {
            std::string spec; bool isPlay = false;
            {
                std::unique_lock<std::mutex> lk(lm_);
                lcv_.wait(lk, [this] { return lstop_ || hasPlay_ || hasPre_; });
                if (lstop_) return;
                if (hasPlay_) { spec.swap(playReq_); hasPlay_ = false; isPlay = true; }   // play wins; only the latest request counts
                else { spec.swap(preReq_); hasPre_ = false; }
            }
            if (isPlay) do_play(spec); else do_preload(spec);
        }
    }
    static std::vector<std::string> lines(const std::string& s) {
        std::vector<std::string> out; size_t p = 0;
        while (p < s.size()) { size_t e = s.find('\n', p); if (e == std::string::npos) e = s.size(); if (e > p) out.push_back(s.substr(p, e - p)); p = e + 1; }
        return out;
    }
    Bytes get_bytes(const std::string& path) {   // loader thread only
        auto it = cache_.find(path);
        if (it != cache_.end()) return it->second;
        auto b = std::make_shared<std::vector<unsigned char>>();
        std::ifstream f(std::filesystem::path(widen(path)), std::ios::binary);
        if (f) { f.seekg(0, std::ios::end); auto n = f.tellg(); f.seekg(0); if (n > 0) { b->resize((size_t)n); f.read((char*)b->data(), n); if (!f) b->clear(); } }
        if (b->empty()) return nullptr;
        cache_[path] = b;
        return b;
    }
    void do_preload(const std::string& spec) {
        std::unordered_set<std::string> keep;
        size_t bytes = 0; int n = 0;
        for (auto& l : lines(spec)) {
            std::string path = l.substr(0, l.find('|'));
            keep.insert(path);
            if (auto b = get_bytes(path)) { bytes += b->size(); ++n; }
        }
        for (auto it = cache_.begin(); it != cache_.end();) { if (!keep.count(it->first)) it = cache_.erase(it); else ++it; }   // voices keep their own reference
        log_("preloaded " + std::to_string(n) + " file(s), " + std::to_string(bytes / 1024) + " KB");
    }
    void do_play(const std::string& spec) {
        Voice* nv = nullptr; std::string err;
        if (!spec.empty()) {
            if (!init_device()) { log_("play: audio device failed"); return; }
            nv = new Voice();
            for (auto& line : lines(spec)) {
                size_t a = line.find('|'), b = a == std::string::npos ? a : line.find('|', a + 1);
                std::string path = line.substr(0, a);
                ma_uint64 ls = 0, le = 0;
                if (a != std::string::npos) ls = std::strtoull(line.c_str() + a + 1, nullptr, 10);
                if (b != std::string::npos) le = std::strtoull(line.c_str() + b + 1, nullptr, 10);
                auto* var = new Variant();
                var->data = get_bytes(path);
                ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 2, 44100);
                // decode from memory: miniaudio's wide-path open falls back to stb_vorbis "push" mode (length 0, caused the old buzz)
                if (!var->data || ma_decoder_init_memory(var->data->data(), var->data->size(), &cfg, &var->dec) != MA_SUCCESS) { err += "cannot open " + path + "; "; delete var; continue; }
                var->ok = true;
                ma_uint64 total = 0; ma_decoder_get_length_in_pcm_frames(&var->dec, &total);
                if (total == 0) { err += "unknown length " + path + "; "; delete var; continue; }
                var->le = (le > 0 && le <= total) ? le : total;
                var->ls = ls < var->le ? ls : 0;
                if (var->le - var->ls < 4410) { err += "loop too short " + path + "; "; delete var; continue; }
                ma_decoder_seek_to_pcm_frame(&var->dec, 0);
                nv->v.push_back(var);
            }
            if (nv->v.empty()) { delete nv; nv = nullptr; }
            else if (nv->v.size() > 1) nv->cur = (int)(rng() % nv->v.size());
        }
        int fadeFrames = (int)((long long)transMs_.load() * 44100 / 1000);
        {
            std::lock_guard<std::mutex> g(m_);
            if (fading_) { retired_.push_back(fading_); fading_ = nullptr; }
            if (cur_) {
                if (fadeFrames > 0) { fading_ = cur_; fadeLen_ = fadeFrames; fadePos_ = 0; }
                else retired_.push_back(cur_);
            }
            cur_ = nv;
            hasRetired_.store(!retired_.empty());
        }
        playing_.store(nv != nullptr);
        if (!err.empty()) log_("play: " + err);
    }

    // ---- audio thread ----
    static void cb_s(ma_device* d, void* out, const void*, ma_uint32 n) { static_cast<Player*>(d->pUserData)->cb(static_cast<float*>(out), n); }
    // renders `frames` frames of voice v into buf (overwrites), looping between ls and le
    void render(Voice* v, float* buf, ma_uint32 frames) {
        ma_uint32 done = 0; int guard = 0;
        while (done < frames && guard++ < 16) {
            Variant* x = v->v[v->cur];
            ma_uint64 pos = 0; ma_decoder_get_cursor_in_pcm_frames(&x->dec, &pos);
            ma_uint64 want = frames - done;
            if (x->le > pos && x->le - pos < want) want = x->le - pos;
            ma_uint64 got = 0;
            if (want > 0 && pos < x->le) ma_decoder_read_pcm_frames(&x->dec, buf + done * 2, want, &got);
            done += (ma_uint32)got;
            ma_decoder_get_cursor_in_pcm_frames(&x->dec, &pos);
            if (got < want || pos >= x->le) {
                int k = v->v.size() > 1 ? (int)(rng() % v->v.size()) : v->cur;
                v->cur = k;
                ma_decoder_seek_to_pcm_frame(&v->v[k]->dec, v->v[k]->ls);
            }
        }
        for (ma_uint32 i = done * 2; i < frames * 2; ++i) buf[i] = 0.f;
    }
    void cb(float* out, ma_uint32 frames) {
        for (ma_uint32 i = 0; i < frames * 2; ++i) out[i] = 0.f;
        {
            std::lock_guard<std::mutex> g(m_);   // other holders only swap pointers, so this never waits long
            ma_uint32 off = 0;
            while (off < frames) {
                ma_uint32 n = frames - off; if (n > kChunk) n = kChunk;
                float* o = out + off * 2;
                if (cur_) render(cur_, o, n);
                if (fading_) {
                    render(fading_, tmp_, n);
                    for (ma_uint32 i = 0; i < n; ++i) {
                        float gain = fadePos_ < fadeLen_ ? 1.f - (float)fadePos_ / (float)fadeLen_ : 0.f;
                        o[i * 2] += tmp_[i * 2] * gain; o[i * 2 + 1] += tmp_[i * 2 + 1] * gain;
                        ++fadePos_;
                    }
                    if (fadePos_ >= fadeLen_) { retired_.push_back(fading_); fading_ = nullptr; hasRetired_.store(true); }
                }
                off += n;
            }
        }
        float vol = vol_.load(); bool bad = false;
        for (ma_uint32 i = 0; i < frames * 2; ++i) { float s = out[i]; if (!std::isfinite(s) || std::fabs(s) > 2.5f) { bad = true; break; } }
        if (bad) { for (ma_uint32 i = 0; i < frames * 2; ++i) out[i] = 0.f; bad_.store(true); return; }
        for (ma_uint32 i = 0; i < frames * 2; ++i) { float s = out[i] * vol; out[i] = s > 1.f ? 1.f : (s < -1.f ? -1.f : s); }
    }
    uint32_t rng() { uint32_t s = seed_.load(); s = s * 1664525u + 1013904223u; seed_.store(s); return s >> 8; }
    static std::wstring widen(const std::string& s);

    static constexpr ma_uint32 kChunk = 4096;
    LogFn log_;
    ma_device dev_{};
    // device thread
    std::mutex tm_; std::condition_variable tcv_; std::thread thread_; bool stop_ = false, ready_ = false, started_ = false;
    // loader thread
    std::mutex lstart_, lm_; std::condition_variable lcv_; std::thread loader_; bool lstop_ = false, hasPlay_ = false, hasPre_ = false;
    std::string playReq_, preReq_;
    std::unordered_map<std::string, Bytes> cache_;
    // shared with the audio thread (guarded by m_)
    std::mutex m_; Voice* cur_ = nullptr; Voice* fading_ = nullptr; int fadeLen_ = 0, fadePos_ = 0; std::vector<Voice*> retired_;
    float tmp_[kChunk * 2] = {};
    std::atomic<float> vol_{0.f}; std::atomic<int> transMs_{2000};
    std::atomic<bool> bad_{false}, hasRetired_{false}, playing_{false};
    std::atomic<uint32_t> seed_{0x1234567u};
};

std::wstring widen_utf8(const std::string& s);
inline std::wstring Player::widen(const std::string& s) { return widen_utf8(s); }
} // namespace jb
