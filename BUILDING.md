# Building the native DLL (`main.dll`)

The Lua part (`mod/PD2MusicSystem/Scripts/main.lua`) is plain text and needs no build. These steps build the native audio part, a UE4SS C++ mod.

## Requirements
- **Windows 10/11 x64**
- **Visual Studio 2026** with the *Desktop development with C++* workload. The build uses the CMake that comes with Visual Studio (generator `Visual Studio 18 2026`).
- **Git** for Windows
- **Rust** (`cargo`), needed by UE4SS's patternsleuth dependency
- **A GitHub account linked to an Epic Games account**, with the Epic invite to the `EpicGames` GitHub organisation accepted. UE4SS pulls Unreal Engine headers from a private repository.

## Build with the script
1. Clone this repository.
2. Run `src\build.bat`. It does the following:
   1. Checks for Git, Rust and Visual Studio.
   2. Clones **RE-UE4SS** into `src\RE-UE4SS` and checks out commit `0290bedac01f4acfdcbaa13c5a5a2fa14585a549`. That is the version the PAYDAY 3 UE4SS build (UE5.5.4) is made from.
   3. Fetches its submodules. It asks for your GitHub username once (saved in `src\github_user.txt`), and a GitHub sign-in window may open.
   4. Applies three small source fixes that the `CasePreserving__Shipping__Win64` configuration needs at that commit:
      - `deps/first/Unreal/include/Unreal/NameTypes.hpp`: `FNameEntryId::FromUnstableInt(...)` in the two `FName` constructors
      - `UE4SS/src/GUI/Dumpers.cpp`: `.ToUnstableInt()` on `GetDisplayIndex()`
      - `UE4SS/src/GUI/LiveView.cpp`: `.ToUnstableInt()` on `GetDisplayIndex()`
   5. Configures with `cmake -B out -G "Visual Studio 18 2026" -A x64`.
   6. Builds `--config CasePreserving__Shipping__Win64 --target PD2Jukebox`.
   7. Copies the result to `src\dist\main.dll`.
3. Copy `src\dist\main.dll` to `PD2MusicSystem\dlls\main.dll`.

The first build takes 10-30 minutes. Progress and errors go to `src\build_log.txt`.

## Build by hand
```
cd src
git clone https://github.com/UE4SS-RE/RE-UE4SS.git
cd RE-UE4SS
git checkout 0290bedac01f4acfdcbaa13c5a5a2fa14585a549
git submodule update --init --recursive
:: apply the three fixes listed above
cd ..
cmake -B out -G "Visual Studio 18 2026" -A x64
cmake --build out --config CasePreserving__Shipping__Win64 --target PD2Jukebox
```
The DLL is at `out\PD2Jukebox\CasePreserving__Shipping__Win64\PD2Jukebox.dll`. Rename it to `main.dll`.

## Source overview (`src/PD2Jukebox`)
| File | What |
|---|---|
| `dllmain.cpp` | UE4SS C++ mod entry. Registers the Lua functions `JB_Play(spec)`, `JB_Preload(spec)`, `JB_Volume(0..1)`, `JB_Transition(ms)` and `JB_Playing()`. |
| `jb_audio.hpp` | The player (see below) |
| `jb_audio_impl.cpp` | miniaudio and stb_vorbis implementation units, plus UTF-8 to UTF-16 path conversion |
| `miniaudio.h` | [miniaudio](https://github.com/mackron/miniaudio), single-file audio library (public domain / MIT-0) |
| `stb_vorbis.c` | [stb_vorbis](https://github.com/nothings/stb), Ogg Vorbis decoder (public domain / MIT) |

The player in `jb_audio.hpp` runs on three threads, and the game thread never blocks on audio:
- **Audio device thread:** started on first use, never at mod load.
- **Loader thread:** reads files and creates decoders off the game thread, and keeps the preload cache.
- **Device callback:** loops between the loop points, picks a random variant at each loop end, and mixes in the old phase's 2-second tail on transitions. Non-finite or out-of-range samples mute the block as a safety measure.

`JB_Play` / `JB_Preload` spec format: one line per file, `path|loop_start|loop_end`, with UTF-8 paths and loop points in 44100 Hz frames. An empty spec stops playback.
