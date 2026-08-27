# Doompeller

Doompeller is a native Dart + Flutter + Flame 3D reimplementation with a pure
Dart WAD parser, geometry compiler, and deterministic 35 Hz gameplay core. It
does not embed, wrap, download, or extract another Doom engine.

## Run original E1M1

Place `DOOM1.WAD` at `.local/doom/DOOM1.WAD`. It is the default local content
source, so the app starts E1M1 without a chooser. `DOOM_WAD_PATH` can override
that path on desktop.

```sh
/Users/savva/fvm/versions/stable/bin/flutter run -d macos --release
```

```sh
DOOM_WAD_PATH=.local/doom/DOOM1.WAD \
  /Users/savva/fvm/versions/stable/bin/flutter run -d macos --release
```

If a configured path is unreadable, invalid, not an IWAD, or lacks E1M1, the
app shows an error. It will not silently switch content; the synthetic fallback
requires an explicit button press.

## Run in a WebGPU browser

The browser target is Flutter Wasm plus flame_3d's WebGPU backend. The release
build copies `.local/doom/DOOM1.WAD` to `build/web/doom1.wad`, and startup loads
E1M1 automatically. **SELECT LOCAL IWAD** remains available only from the pause
menu for switching content at runtime.

Build the reproducible release with the pinned Flutter SDK and naga:

```sh
tool/build_web_release.sh
```

The build verifies the Wasm entrypoint, local CanvasKit assets, generated WGSL
shader bundle, deployment headers, and the exact bundled `doom1.wad` size and
checksum.
Deployment must preserve `web/_headers` so Wasm/worker resources run under
COOP/COEP. The supported and tested runtime target is Wasm/WebGPU.

## Headless WAD report

Before opening the app, inspect a WAD and compile its map geometry without a
GUI or a macOS build. The command reads the selected WAD into memory only; it
does not extract or write any Doom content. With no path it reports the clean
synthetic fixture, so it is safe to use in CI.

```sh
/Users/savva/fvm/versions/stable/bin/dart run tool/wad_report.dart \
  --map E1M1 .local/doom/DOOM1.WAD

# Or use DOOM_WAD_PATH; --json is suitable for CI artifact parsing.
DOOM_WAD_PATH=.local/doom/DOOM1.WAD \
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

Unit tests retain generated regression fixtures. Root acceptance runs set
`DOOM_WAD_PATH=.local/doom/DOOM1.WAD` and include the original E1M1 report and
deterministic traversal.
