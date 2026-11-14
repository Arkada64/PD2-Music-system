// PD2 Jukebox - native part. Owns audio playback; the Lua part (Scripts/main.lua in the same mod folder)
// decides what to play and calls these functions:
//   JB_Play(spec)   spec = "path|loop_start|loop_end\n..." (variants), "" = stop. Returns "" or an error string.
//   JB_Volume(v)    0..1, applied instantly
//   JB_Playing()    true while something is loaded
//   JB_Preload(spec) read these files into memory ahead of time (background)
//   JB_Transition(ms) how long the old phase rings out under the new one (PD2: 2000; 0 = hard cut)
#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <memory>
#include <string>
#include "jb_audio.hpp"

using namespace RC;

static std::unique_ptr<jb::Player> g_player;

static void jb_log(const std::string& s)
{
    std::wstring w(s.begin(), s.end());
    Output::send<LogLevel::Verbose>(STR("[PD2Jukebox] {}\n"), w);
}

static int lua_play(const LuaMadeSimple::Lua& lua)
{
    std::string spec;
    if (lua.is_string()) spec = std::string(lua.get_string());
    // queued: the loader thread reads/decodes and swaps it in; errors go to the UE4SS log
    if (g_player) g_player->play(spec);
    lua.set_string(g_player ? "" : "audio not ready");
    return 1;
}
static int lua_preload(const LuaMadeSimple::Lua& lua)
{
    std::string spec;
    if (lua.is_string()) spec = std::string(lua.get_string());
    if (g_player) g_player->preload(spec);
    return 0;
}
static int lua_transition(const LuaMadeSimple::Lua& lua)
{
    int ms = 2000;
    if (lua.is_number()) ms = static_cast<int>(lua.get_number());
    if (g_player) g_player->set_transition_ms(ms);
    return 0;
}
static int lua_volume(const LuaMadeSimple::Lua& lua)
{
    float v = 0.f;
    if (lua.is_number()) v = static_cast<float>(lua.get_number());
    if (g_player) g_player->set_volume(v);
    return 0;
}
static int lua_playing(const LuaMadeSimple::Lua& lua)
{
    lua.set_bool(g_player && g_player->playing());
    return 1;
}

class PD2Jukebox : public RC::CppUserModBase
{
public:
    PD2Jukebox() : CppUserModBase()
    {
        ModName = STR("PD2JukeboxNative");
        ModVersion = STR("0.4");
        ModDescription = STR("PAYDAY 2 music in PAYDAY 3");
        ModAuthors = STR("Ark");
        g_player = std::make_unique<jb::Player>(&jb_log);
        jb_log("native part loaded (0.4) - async loading, PD2-style transitions");
    }
    ~PD2Jukebox() override { if (g_player) g_player->shutdown(); g_player.reset(); }

    auto on_lua_start(LuaMadeSimple::Lua& lua, LuaMadeSimple::Lua& main_lua, LuaMadeSimple::Lua& async_lua, LuaMadeSimple::Lua* hook_lua) -> void override
    {
        // Only the main state (main_lua shares its globals) and the game-thread hook state.
        // The async state runs on another thread already - touching it here races and can crash.
        (void)main_lua; (void)async_lua;
        for (LuaMadeSimple::Lua* l : {&lua, hook_lua})
        {
            if (!l) continue;
            l->register_function("JB_Play", &lua_play);
            l->register_function("JB_Volume", &lua_volume);
            l->register_function("JB_Playing", &lua_playing);
            l->register_function("JB_Preload", &lua_preload);
            l->register_function("JB_Transition", &lua_transition);
        }
        jb_log("Lua functions registered");
    }
    auto on_update() -> void override { if (g_player) g_player->collect(); }
};

#define PD2JB_API __declspec(dllexport)
extern "C"
{
    PD2JB_API RC::CppUserModBase* start_mod() { return new PD2Jukebox(); }
    PD2JB_API void uninstall_mod(RC::CppUserModBase* mod) { delete mod; }
}
