#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_ROOT"

fail() {
  echo "PROJECT AUDIT FAIL: $1" >&2
  exit 1
}

command -v rg >/dev/null 2>&1 || fail "ripgrep (rg) is required"

need_line() {
  pattern=$1
  file=$2
  rg -q "$pattern" "$file" || fail "missing expected project pin in $file: $pattern"
}

# Pure-Dart packages are deliberately usable without Flutter or a GPU runtime.
if rg -n -g '*.dart' \
  "^(import|export) ['\"](dart:(ui|ffi|js|js_interop|js_interop_unsafe|html)|package:(flutter|flame|flame_3d|web)(/|['\"]))" \
  packages/doom_wad packages/doom_geometry packages/doom_core packages/doom_music
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
  "^(import|export) ['\"](dart:ffi|package:(ffi|webview_flutter)/)|DynamicLibrary\\.|WebViewController\\(" \
  lib packages tool
then
  fail "FFI, WebView, or native dynamic loading found"
fi

# Browser APIs are confined to content input, pointer capture, and audio.
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

# Experimental rendering dependencies and ABI/replay pins are intentionally
# exact. A change requires updating the corresponding tripwire corpus.
need_line "^  flutter: 3\.47\.7$" pubspec.yaml
need_line "^  flame: 1\.38\.0$" pubspec.yaml
need_line "^  flame_3d: 0\.3\.2$" pubspec.yaml
need_line "^  vector_math: 2\.4\.0$" pubspec.yaml
need_line "^  web: 1\.1\.1$" pubspec.yaml
need_line "^    - \.local/doom/DOOM1\.WAD$" pubspec.yaml
need_line "<key>FLTEnableImpeller</key>" macos/Runner/Info.plist
need_line "<key>FLTEnableFlutterGPU</key>" macos/Runner/Info.plist
need_line "static const int floatsPerVertex = 20;" lib/adapter/vertex_abi.dart
need_line "static const int floatsPerVertex = 20;" packages/doom_geometry/lib/src/packed_mesh.dart
need_line "var hash = 0x811C9DC5;" packages/doom_geometry/lib/src/compiler_packing.dart
need_line "int h = 0x811c9dc5;" packages/doom_core/lib/src/game_state.dart
test -f test/adapter/vertex_abi_test.dart ||
  fail "vertex ABI tripwire test is missing"
test -f test/integration/geometry_adapter_abi_test.dart ||
  fail "geometry/adapter ABI tripwire test is missing"
test -f test/replay_corpus_test.dart || fail "replay corpus test is missing"

# If a release executable exists, reject characteristic symbols of a linked
# Doom engine. Source rules above remain the stronger proof.
APP_BINARY=build/macos/Build/Products/Release/doompeller.app/Contents/MacOS/doompeller
if [ -x "$APP_BINARY" ] && command -v nm >/dev/null 2>&1; then
  if nm -gj "$APP_BINARY" 2>/dev/null |
    rg -i "(_D_DoomMain|_I_InitGraphics|_R_RenderPlayerView|_W_InitMultipleFiles)"
  then
    fail "linked executable exposes symbols from an existing Doom engine"
  fi
fi

echo "PROJECT AUDIT PASS: layering, native-stack, dependency pins, and ABI contracts"
