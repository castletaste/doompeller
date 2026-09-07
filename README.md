# Doompeller

Doompeller is a native Dart + Flutter + Flame 3D reimplementation with a pure
Dart WAD parser, geometry compiler, and deterministic 35 Hz gameplay core. It
does not embed, wrap, download, or extract another Doom engine.

Production: [doompeller.castletaste.dev](https://doompeller.castletaste.dev).
CI and PR previews: [publishing guide](docs/PUBLISHING.md).

## Run original E1M1

Use Flutter 3.44.4 and fetch the pinned shareware E1 content before resolving
the app's assets, or provide the same verified `DOOM1.WAD` yourself:

```sh
python3 tool/fetch_shareware.py
flutter pub get --enforce-lockfile
```

The file stays ignored at `.local/doom/DOOM1.WAD`; it is bundled into the app
and public site. The app starts E1M1 without a chooser. `DOOM_WAD_PATH` can
override the desktop source when the process has permission to read the file.

The intermission continues through episode 1 with health, armor, ammo and
weapons retained. The E1M3 secret exit leads to E1M9, which returns to E1M4;
E1M8 is the episode finale. See [verification](docs/VERIFICATION.md) for the
distinction between implemented mechanics, scene checks and completed replays.

```sh
flutter run -d macos --release
```

Leave `DOOM_WAD_PATH` unset for the normal macOS release: it uses the bundled
local original WAD. The macOS app sandbox may reject an external path override,
including a relative path into the source checkout. An explicit override is
never silently replaced with the bundled copy if reading it fails.

If a configured path is unreadable, invalid, not an IWAD, or lacks E1M1, the
app shows an error. It will not silently switch content; the synthetic fallback
requires an explicit button press.

## Run in a WebGPU browser

The browser target is Flutter Wasm plus flame_3d's WebGPU backend. The release
build packages `.local/doom/DOOM1.WAD` at
`build/web/assets/.local/doom/DOOM1.WAD`, and startup loads E1M1 automatically.
**SELECT LOCAL IWAD** remains available only from the pause menu for switching
content at runtime.

Build the reproducible release with Flutter 3.44.4 and naga-cli 30.0.1 on PATH:

```sh
DOOMPELLER_FLUTTER="$(command -v flutter)" bash tool/build_web_release.sh
```

The build removes Flutter's generated dart2js fallback and verifies the
dart2wasm entrypoint, local CanvasKit assets, generated WGSL shader bundle,
deployment headers, and the exact bundled `DOOM1.WAD` size and checksum.
Deployment must preserve `web/_headers` so Wasm/worker resources run under
COOP/COEP. The supported and tested runtime target is Wasm/WebGPU.

## Headless WAD report

Before opening the app, inspect a WAD and compile its map geometry without a
GUI or a macOS build. The command reads the selected WAD into memory only; it
does not extract or write any Doom content. With no path it reports the clean
unit-test fixture; CI acceptance uses the original shareware WAD.

```sh
dart run tool/wad_report.dart \
  --map E1M1 .local/doom/DOOM1.WAD

# Or use DOOM_WAD_PATH; --json is suitable for CI artifact parsing.
DOOM_WAD_PATH=.local/doom/DOOM1.WAD \
  dart run tool/wad_report.dart \
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
- `1`–`6`: fist, pistol, shotgun, chaingun, rocket launcher, chainsaw
- `Esc`: pause/resume
- primary-button drag: mouse yaw

All simulation input is sampled into `TicCmd`. Rendering interpolates the
camera between completed 35 Hz tics and never advances game state.

## Verify

Use the pinned Flutter 3.44.4 toolchain:

```sh
flutter analyze
flutter test
flutter build macos --release
```

Root acceptance loads the bundled original E1M1 by default and includes its
report, collision challenges, effect lifetimes, and deterministic traversal.
Focused package tests retain generated fixtures where a minimal oracle is
useful.
