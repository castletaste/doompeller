# Doompeller

Doompeller is a native Dart + Flutter + Flame 3D reimplementation with a pure
Dart WAD parser, geometry compiler, and deterministic 35 Hz gameplay core. It
does not embed, wrap, download, or extract another Doom engine.

## Run the safe synthetic map

The app starts the generated `MAP01` fixture automatically when no IWAD path is
configured. The fixture is generated in Dart, contains no commercial content,
and is visibly marked `SYNTHETIC TEST MAP`.

```sh
/Users/savva/fvm/versions/stable/bin/flutter run -d macos --release
```

## Run original E1M1 with your own IWAD

Point `DOOM_WAD_PATH` at your legally obtained Doom IWAD. The app reads it only
from that explicit path and never copies or extracts its contents.

```sh
DOOM_WAD_PATH=.local/doom/DOOM.WAD \
  /Users/savva/fvm/versions/stable/bin/flutter run -d macos --release
```

If a configured path is unreadable, invalid, not an IWAD, or lacks E1M1, the
app shows an error. It will not silently switch content; the synthetic fallback
requires an explicit button press.

## Headless WAD report

Before opening the app, inspect a WAD and compile its map geometry without a
GUI or a macOS build. The command reads the selected WAD into memory only; it
does not extract or write any Doom content. With no path it reports the clean
synthetic fixture, so it is safe to use in CI.

```sh
/Users/savva/fvm/versions/stable/bin/dart run tool/wad_report.dart \
  --map E1M1 .local/doom/DOOM.WAD

# Or use DOOM_WAD_PATH; --json is suitable for CI artifact parsing.
DOOM_WAD_PATH=.local/doom/DOOM.WAD \
  /Users/savva/fvm/versions/stable/bin/dart run tool/wad_report.dart \
  --json
```

The report includes container and map counts, resolved and missing texture/
flat names, geometry gaps and fallbacks, atlas/surface vertex budgets, and
parse/compile timings. `READY`, `READY WITH FALLBACKS`, and `PROBLEMS` are the
final verdicts; `PROBLEMS` exits non-zero.

## Controls

- `W`/`S` or up/down: move forward/back
- `A`/`D`: strafe
- hold either `Shift`: run
- left/right: turn
- `Ctrl` or primary click: attack
- `Space` or `E`: use
- `1`–`4`: fist, pistol, shotgun, chaingun
- `Esc`: pause/resume
- primary-button drag: mouse yaw

All simulation input is sampled into `TicCmd`. Rendering interpolates the
camera between completed 35 Hz tics and never advances game state.

## Verify

Use the pinned Flutter 3.44.4 toolchain:

```sh
/Users/savva/fvm/versions/stable/bin/flutter analyze
/Users/savva/fvm/versions/stable/bin/flutter test
/Users/savva/fvm/versions/stable/bin/flutter build macos --release
```

Automated tests use only the generated fixture. A successful fixture run does
not claim that original E1M1 was exercised; that requires a developer-provided
`DOOM_WAD_PATH` and a separately reported live run.
