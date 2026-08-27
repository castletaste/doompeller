#!/usr/bin/env bash
# Reproducible Flutter Wasm + flame_3d WebGPU release build.
set -euo pipefail

DOOMPELLER_FLUTTER="${DOOMPELLER_FLUTTER:-/Users/savva/fvm/versions/stable/bin/flutter}"
DOOMPELLER_DART="${DOOMPELLER_DART:-$(dirname "$DOOMPELLER_FLUTTER")/dart}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IWAD_SOURCE="$PROJECT_ROOT/.local/doom/DOOM1.WAD"
IWAD_DESTINATION="$PROJECT_ROOT/build/web/assets/.local/doom/DOOM1.WAD"
EXPECTED_IWAD_BYTES=4196020
EXPECTED_IWAD_SHA256="1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771"
cd "$PROJECT_ROOT"

if [[ ! -x "$DOOMPELLER_FLUTTER" ]]; then
  echo "error: pinned Flutter executable not found: $DOOMPELLER_FLUTTER" >&2
  exit 1
fi
if ! command -v naga >/dev/null 2>&1; then
  echo "error: naga-cli is required for the WebGPU shader bundle" >&2
  exit 1
fi
if [[ "$(naga --version)" != "30.0.1" ]]; then
  echo "error: expected naga 30.0.1, found $(naga --version)" >&2
  exit 1
fi

if [[ ! -f "$IWAD_SOURCE" ]]; then
  echo "error: default web IWAD not found: $IWAD_SOURCE" >&2
  exit 1
fi
source_iwad_bytes="$(wc -c < "$IWAD_SOURCE" | tr -d ' ')"
if [[ "$source_iwad_bytes" != "$EXPECTED_IWAD_BYTES" ]]; then
  echo "error: expected $EXPECTED_IWAD_BYTES IWAD bytes, found $source_iwad_bytes" >&2
  exit 1
fi
source_iwad_sha256="$(shasum -a 256 "$IWAD_SOURCE" | awk '{print $1}')"
if [[ "$source_iwad_sha256" != "$EXPECTED_IWAD_SHA256" ]]; then
  echo "error: unexpected IWAD SHA-256: $source_iwad_sha256" >&2
  exit 1
fi

"$DOOMPELLER_FLUTTER" pub run flame_3d:build_shaders --with-web-gpu

native_bundle="assets/shaders/doom_palette.shaderbundle"
web_bundle="assets/shaders/doom_palette.wgslbundle"
for bundle in "$native_bundle" "$web_bundle"; do
  if [[ ! -s "$bundle" ]]; then
    echo "error: missing generated shader bundle: $bundle" >&2
    exit 1
  fi
done
"$DOOMPELLER_DART" run tool/verify_web_shader_bundle.dart "$web_bundle"

"$DOOMPELLER_FLUTTER" build web --wasm --release --no-web-resources-cdn
"$DOOMPELLER_DART" run tool/finalize_wasm_web_build.dart build/web

# Flutter does not guarantee that web dotfiles are copied into build/web.
cp web/_headers build/web/_headers

required=(
  build/web/index.html
  build/web/flutter_bootstrap.js
  build/web/main.dart.wasm
  build/web/main.dart.mjs
  build/web/assets/assets/shaders/doom_palette.wgslbundle
  build/web/_headers
  build/web/assets/.local/doom/DOOM1.WAD
)
for file in "${required[@]}"; do
  if [[ ! -s "$file" ]]; then
    echo "error: missing or empty Wasm release artifact: $file" >&2
    exit 1
  fi
done

if ! grep -Fq '"compileTarget":"dart2wasm"' build/web/flutter_bootstrap.js; then
  echo "error: Flutter bootstrap does not contain the Wasm build" >&2
  exit 1
fi
if grep -Fq '"compileTarget":"dart2js"' build/web/flutter_bootstrap.js ||
  [[ -e build/web/main.dart.js ]]; then
  echo "error: dart2js fallback remains in the Wasm-only release" >&2
  exit 1
fi
if ! grep -Fq '"useLocalCanvasKit":true' build/web/flutter_bootstrap.js; then
  echo "error: Flutter bootstrap still depends on the resources CDN" >&2
  exit 1
fi
destination_iwad_bytes="$(wc -c < "$IWAD_DESTINATION" | tr -d ' ')"
destination_iwad_sha256="$(shasum -a 256 "$IWAD_DESTINATION" | awk '{print $1}')"
if [[ "$destination_iwad_bytes" != "$EXPECTED_IWAD_BYTES" ]] ||
  [[ "$destination_iwad_sha256" != "$EXPECTED_IWAD_SHA256" ]]; then
  echo "error: bundled IWAD failed post-copy validation" >&2
  exit 1
fi
unexpected_wads="$(find "$PROJECT_ROOT/build/web" -type f \( -iname '*.wad' -o -iname '*.iwad' -o -iname '*.pwad' \) ! -path "$IWAD_DESTINATION" -print)"
if [[ -n "$unexpected_wads" ]]; then
  echo "error: unexpected WAD files in the web release:" >&2
  echo "$unexpected_wads" >&2
  exit 1
fi

echo "Wasm/WebGPU release verified: $(wc -c < build/web/main.dart.wasm | tr -d ' ') bytes main.dart.wasm; $destination_iwad_bytes bytes bundled DOOM1.WAD"
