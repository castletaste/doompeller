#!/usr/bin/env bash
# Reproducible Flutter Wasm + flame_3d WebGPU release build.
set -euo pipefail

if [[ -n "${DOOMPELLER_FLUTTER:-}" ]]; then
  : # Keep the explicit CI/developer override.
elif command -v flutter >/dev/null 2>&1; then
  DOOMPELLER_FLUTTER="$(command -v flutter)"
else
  echo "error: Flutter 3.44.4 is required; set DOOMPELLER_FLUTTER or add flutter to PATH" >&2
  exit 1
fi
if [[ -n "${DOOMPELLER_DART:-}" ]]; then
  : # Keep the explicit CI/developer override.
elif [[ -x "$(dirname "$DOOMPELLER_FLUTTER")/dart" ]]; then
  DOOMPELLER_DART="$(dirname "$DOOMPELLER_FLUTTER")/dart"
elif command -v dart >/dev/null 2>&1; then
  DOOMPELLER_DART="$(command -v dart)"
else
  echo "error: the Dart executable for Flutter 3.44.4 is required" >&2
  exit 1
fi
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
if [[ ! -x "$DOOMPELLER_DART" ]]; then
  echo "error: Dart executable not found: $DOOMPELLER_DART" >&2
  exit 1
fi
flutter_version="$("$DOOMPELLER_FLUTTER" --version --machine | sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' | head -n 1)"
if [[ "$flutter_version" != "3.44.4" ]]; then
  echo "error: expected Flutter 3.44.4, found ${flutter_version:-unknown}" >&2
  exit 1
fi
if ! command -v naga >/dev/null 2>&1; then
  echo "error: naga-cli is required for the WebGPU shader bundle" >&2
  exit 1
fi

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "error: shasum or sha256sum is required" >&2
    return 1
  fi
}
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
source_iwad_sha256="$(sha256_file "$IWAD_SOURCE")"
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
# Keep compiler support probes and debug output outside the deployable bundle.
# The module worker loads only the generated module and its Wasm binary.
mkdir -p build/web_music
"$DOOMPELLER_DART" compile wasm --no-source-maps lib/web/doom_music_worker.dart \
  -o build/web_music/doom_music_worker.wasm
cp build/web_music/doom_music_worker.wasm build/web/doom_music_worker.wasm
cp build/web_music/doom_music_worker.mjs build/web/doom_music_worker.mjs
# Flutter may retain these files from an earlier in-place worker compilation.
for compiler_auxiliary in doom_music_worker.support.js doom_music_worker.wasm.map; do
  if [[ -f "build/web/$compiler_auxiliary" ]]; then
    mv "build/web/$compiler_auxiliary" "build/web_music/$compiler_auxiliary"
  fi
done

# Flutter does not guarantee that web dotfiles are copied into build/web.
cp web/_headers build/web/_headers

required=(
  build/web/index.html
  build/web/flutter_bootstrap.js
  build/web/main.dart.wasm
  build/web/main.dart.mjs
  build/web/doom_music_worker.wasm
  build/web/doom_music_worker.mjs
  build/web/doom_music_worker_loader.mjs
  build/web/doom_music_worklet.js
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
if ! grep -Fq '"renderer":"skwasm"' build/web/flutter_bootstrap.js; then
  echo "error: Flutter bootstrap does not select the skwasm renderer" >&2
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
destination_iwad_sha256="$(sha256_file "$IWAD_DESTINATION")"
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

require_route_header() {
  local route="$1"
  local header="$2"
  if ! awk -v route="$route" -v header="  $header" '
    $0 == route { active = 1; next }
    active && /^[^[:space:]]/ { exit }
    active && $0 == header { found = 1 }
    END { exit(found ? 0 : 1) }
  ' build/web/_headers; then
    echo "error: copied _headers is missing '$header' for '$route'" >&2
    exit 1
  fi
}

require_route_header '/*' 'Cross-Origin-Embedder-Policy: credentialless'
require_route_header '/*' 'Cross-Origin-Opener-Policy: same-origin'
require_route_header '/*' "Content-Security-Policy: frame-ancestors 'none'"
require_route_header '/*' 'Permissions-Policy: camera=(), geolocation=(), microphone=(), payment=(), usb=()'
require_route_header '/*' 'Strict-Transport-Security: max-age=31536000'
require_route_header '/*' 'X-Frame-Options: DENY'
require_route_header '/*' 'X-Content-Type-Options: nosniff'
require_route_header '/*' 'Referrer-Policy: strict-origin-when-cross-origin'
require_route_header '/index.html' 'Cache-Control: public, max-age=0, must-revalidate'
require_route_header '/flutter_bootstrap.js' 'Cache-Control: public, max-age=0, must-revalidate'
require_route_header '/flutter_service_worker.js' 'Cache-Control: public, max-age=0, must-revalidate'
require_route_header '/version.json' 'Cache-Control: public, max-age=0, must-revalidate'
require_route_header '/main.dart.wasm' 'Cache-Control: public, max-age=0, must-revalidate'
require_route_header '/main.dart.mjs' 'Cache-Control: public, max-age=0, must-revalidate'
for audio_asset in doom_music_worker.wasm doom_music_worker.mjs doom_music_worker_loader.mjs doom_music_worklet.js; do
  require_route_header "/$audio_asset" 'Cache-Control: public, max-age=0, must-revalidate'
done
require_route_header '/assets/.local/doom/DOOM1.WAD' 'Cache-Control: public, max-age=31536000, immutable'

sh tool/audit_project_contracts.sh

echo "Wasm/WebGPU release verified: $(wc -c < build/web/main.dart.wasm | tr -d ' ') bytes main.dart.wasm; $destination_iwad_bytes bytes bundled DOOM1.WAD"
