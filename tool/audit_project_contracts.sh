#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_ROOT"

fail() {
  echo "AUDIT FAIL: $1" >&2
  exit 1
}

command -v rg >/dev/null 2>&1 || fail "ripgrep (rg) is required"

need_line() {
  pattern=$1
  file=$2
  rg -q "$pattern" "$file" || fail "missing expected pin/config in $file: $pattern"
}

# Pure-Dart packages are deliberately usable without Flutter or a GPU runtime.
if rg -n -g '*.dart' "^(import|export) ['\"](dart:(ui|ffi|js|js_interop|js_interop_unsafe|html)|package:(flutter|flame|flame_3d|web)(/|['\"]))" packages/doom_wad packages/doom_geometry packages/doom_core packages/doom_music
then
  fail "pure-Dart package imports a forbidden platform library"
fi

# All direct flame_3d usage is quarantined in the adapter. Adapter tests may
# import it to pin the real ABI, but product/game/WAD/geometry code may not.
flame_hits=$(rg -l -g '*.dart' "package:flame_3d/" lib packages tool 2>/dev/null || true)
outside_adapter=$(printf '%s\n' "$flame_hits" | rg -v "^lib/adapter/" || true)
if [ -n "$outside_adapter" ]; then
  printf '%s\n' "$outside_adapter" >&2
  fail "flame_3d import exists outside lib/adapter"
fi

# These are the prohibited ways to smuggle another engine or renderer into the
# app. Documentation may mention the words; executable imports/APIs may not.
if rg -n -g '*.dart' \
  "^(import|export) ['\"](dart:ffi|package:(ffi|webview_flutter)/)|DynamicLibrary\.|WebViewController\(" \
  lib packages tool
then
  fail "FFI, WebView, or native dynamic loading found"
fi

# Browser APIs are confined to content input, pointer capture, and the audio session/worker.
# Music synthesis itself stays pure Dart in doom_music.
js_hits=$(rg -l -g '*.dart' "^(import|export) ['\"]dart:js(_interop(_unsafe)?)?['\"]" lib packages tool 2>/dev/null || true)
outside_web_bridges=$(printf '%s\n' "$js_hits" |
  rg -v "^lib/(game/(browser_wad_picker_web|content_source_platform_web|browser_pointer_web|web_audio_session)|web/doom_music_worker)\.dart$" || true)
if [ -n "$outside_web_bridges" ]; then
  printf '%s\n' "$outside_web_bridges" >&2
  fail "JS interop exists outside the approved browser boundaries"
fi
if rg -n -g '*.dart' "WebAssembly\." lib packages tool; then
  fail "direct WebAssembly API usage found"
fi

# The experimental rendering stack is exact-pinned.
need_line "^  flutter: 3\.44\.4$" pubspec.yaml
need_line "^  flame: 1\.38\.0$" pubspec.yaml
need_line "^  flame_3d: 0\.3\.0$" pubspec.yaml
need_line "^  vector_math: 2\.2\.0$" pubspec.yaml
need_line "^  web: 1\.1\.1$" pubspec.yaml
need_line "^    - \.local/doom/DOOM1\.WAD$" pubspec.yaml
need_line "<key>FLTEnableImpeller</key>" macos/Runner/Info.plist
need_line "<key>FLTEnableFlutterGPU</key>" macos/Runner/Info.plist

# Commercial content must never enter the index or any commit. This checks
# names; the generated fixture is source code and has no WAD file on disk.
tracked_wads=$(git ls-files | rg -i "\.(wad|iwad|pwad|deh)$" || true)
if [ -n "$tracked_wads" ]; then
  printf '%s\n' "$tracked_wads" >&2
  fail "commercial-content extension is tracked"
fi
history_wads=$(git log --all --name-only --format= | rg -i "\.(wad|iwad|pwad|deh)$" || true)
if [ -n "$history_wads" ]; then
  printf '%s\n' "$history_wads" >&2
  fail "commercial-content extension appears in Git history"
fi

git check-ignore -q .local/doom/DOOM.WAD ||
  fail ".local/doom/DOOM.WAD is not ignored"
git check-ignore -q sample.wad || fail "lowercase WAD extension is not ignored"
git check-ignore -q sample.WAD || fail "uppercase WAD extension is not ignored"

if git ls-files --error-unmatch assets/shaders/doom_palette.shaderbundle >/dev/null 2>&1
then
  fail "compiled shader bundle is tracked instead of reproducibly built"
fi
git check-ignore -q assets/shaders/doom_palette.shaderbundle ||
  fail "compiled shader bundle is not ignored"
if git ls-files --error-unmatch assets/shaders/doom_palette.wgslbundle >/dev/null 2>&1
then
  fail "compiled WebGPU shader bundle is tracked instead of reproducibly built"
fi
git check-ignore -q assets/shaders/doom_palette.wgslbundle ||
  fail "compiled WebGPU shader bundle is not ignored"
need_line "Cross-Origin-Opener-Policy: same-origin" web/_headers
need_line "Cross-Origin-Embedder-Policy: credentialless" web/_headers
need_line "^/assets/\.local/doom/DOOM1\.WAD$" web/_headers
need_line "finalize_wasm_web_build\.dart build/web" tool/build_web_release.sh

if [ -f build/web/flutter_bootstrap.js ]; then
  need_line '"compileTarget":"dart2wasm"' build/web/flutter_bootstrap.js
  if rg -q '"compileTarget":"dart2js"' build/web/flutter_bootstrap.js ||
    [ -e build/web/main.dart.js ]
  then
    fail "generated web release still contains a dart2js fallback"
  fi
fi

# When a release executable exists, reject characteristic symbols of a linked
# Doom engine. Absence of symbols is only a smoke check; source rules above are
# the stronger proof.
APP_BINARY=build/macos/Build/Products/Release/doompeller.app/Contents/MacOS/doompeller
if [ -x "$APP_BINARY" ] && command -v nm >/dev/null 2>&1; then
  if nm -gj "$APP_BINARY" 2>/dev/null |
    rg -i "(_D_DoomMain|_I_InitGraphics|_R_RenderPlayerView|_W_InitMultipleFiles)"
  then
    fail "linked executable exposes symbols from an existing Doom engine"
  fi
fi

echo "AUDIT PASS: layering, native-stack, pins, and content hygiene"
