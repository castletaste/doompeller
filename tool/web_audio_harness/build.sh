#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="${1:-/private/tmp/doompeller-web-audio-harness}"
flutter_bin="${DOOMPELLER_FLUTTER:-$(command -v flutter || true)}"
if [[ -z "$flutter_bin" || ! -x "$flutter_bin" ]]; then
  echo "error: set DOOMPELLER_FLUTTER or add Flutter 3.44.4 to PATH" >&2
  exit 1
fi
dart_bin="${DOOMPELLER_DART:-$(dirname "$flutter_bin")/dart}"
if [[ ! -x "$dart_bin" ]]; then
  echo "error: set DOOMPELLER_DART to the Dart executable for Flutter 3.44.4" >&2
  exit 1
fi

cd "$project_root"
"$flutter_bin" build web \
  --wasm \
  --release \
  --no-web-resources-cdn \
  --target tool/web_audio_harness/main.dart \
  --dart-define=DOOMPELLER_AUDIO_HARNESS=true \
  --output "$output"
"$dart_bin" compile wasm \
  -DDOOMPELLER_AUDIO_HARNESS=true \
  lib/web/doom_music_worker.dart \
  -o "$output/doom_music_worker.wasm"
cp web/doom_music_worker_loader.mjs "$output/doom_music_worker_loader.mjs"
cp web/doom_music_worklet.js "$output/doom_music_worklet.js"

echo "$output"
