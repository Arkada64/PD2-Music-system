# PD2 Music System for PAYDAY 3

PAYDAY 2's heist music system, in PAYDAY 3. Pick a PAYDAY 2 track from a **JUKEBOX** button in the pre-heist lobby, and it plays phase by phase through the heist the way it did in PAYDAY 2.

| PAYDAY 3 heist state | Music phase |
|---|---|
| Stealth, Search | Setup |
| Alarm, First Response, Negotiation, Control | Control |
| Anticipation | Anticipation |
| Assault | Assault |
| Point of No Return | Final assault |

This repository holds the full source of the mod: the native audio DLL (C++) and the Lua script. It also has the build instructions needed to verify the release DLL. **No game audio is included.**

## Features
- **PD2 loops:** PD2's original loop points. Tracks with several variants pick one at random each loop.
- **PD2-style transitions:** the new phase starts at once at full volume, and the old one rings out underneath for 2 s, taken from PD2's own sound bank. No fade-ins.
- **Break the Rules:** assault v1 plays on normal assaults, and v2 (the lyrics version) on the final assault.
- **Volume:** follows PAYDAY 3's Master × Music sliders on a game-style curve, including mid-heist changes, with per-song loudness trims. PD3's own heist music is muted while a track plays, and your setting is restored afterwards, even after a crash.
- **Menus untouched:** nothing plays outside heists, or with the jukebox set to OFF.
- **Performance:** audio runs on its own threads, and files are loaded in the background. The chosen song is preloaded into memory, so phase changes never stall the game.
- **Local only:** host or client, everyone can use their own song.
- **Custom songs:** add Ogg files plus a line in `jukebox_index.txt`. No rebuild needed.

## Repository layout
| Path | What |
|---|---|
| `mod/PD2MusicSystem/` | The mod folder as installed: `Scripts/main.lua`, `enabled.txt`, and the music folder layout. `dlls/main.dll` comes from a build or a release. |
| `src/` | Native part: `PD2Jukebox/` (C++ source, miniaudio, stb_vorbis), CMake files and the build scripts |
| `BUILDING.md` | How to build `main.dll` yourself |
| `THIRD_PARTY_NOTICES.txt` | Licenses of the bundled libraries |

## Install (players)
1. Install **UE4SS for PAYDAY 3**, the UE5.5.4 build. The DLL is built against UE4SS commit `0290beda`.
2. Copy `PD2MusicSystem` into `PAYDAY3\PAYDAY3\Binaries\Win64\ue4ss\Mods\`. Get the DLL from the release download, or build it (see `BUILDING.md`).
3. Put the music into `PD2MusicSystem\music\`. See `music/PUT_MUSIC_HERE.txt` for the layout and index format.
4. In the pre-heist lobby, click **JUKEBOX** (top right) and pick a track.

Settings live in `PD2MusicSystem\config.txt`, which is created on first launch. They cover the button and list layout, the transition length, the volume curve and an overall volume trim.

## How it works (short)
- **Lua script** (`Scripts/main.lua`):
  - Reads the heist state from `PD3HeistGameState.CurrentHeistState` and maps it to a phase.
  - Builds the lobby button inside the pre-planning screen's own widget tree.
  - Handles the volume and muting PD3's music.
- **Native DLL:** a UE4SS C++ mod built on miniaudio and stb_vorbis.
  - Gives the Lua script `JB_Play`, `JB_Preload`, `JB_Volume`, `JB_Transition` and `JB_Playing`.
  - Plays the Ogg files with sample-accurate loop points, on its own audio and loader threads.

## Credits
- Mod by Ark ([Arkada64](https://github.com/Arkada64)).
- PAYDAY 2 music © OVERKILL / Starbreeze and the respective rights holders. It isn't included here.
- Third-party code: see `THIRD_PARTY_NOTICES.txt`.
