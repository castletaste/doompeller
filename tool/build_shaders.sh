#!/usr/bin/env bash
# Compiles shaders/*.vert + shaders/*.frag into
# assets/shaders/<name>.shaderbundle using flame_3d's build_shaders entrypoint,
# which drives the Impeller offline compiler shipped with the pinned SDK.
#
# The bundle is a build artifact and is gitignored. It must be reproducible, so
# this script pins the SDK path rather than relying on whatever flutter is on
# PATH: the system flutter is older and fails.
#
# Usage:
#   tool/build_shaders.sh            # build once
#   tool/build_shaders.sh --watch    # rebuild on change
#   tool/build_shaders.sh --verify   # build, then print the artifact hash
set -euo pipefail

DOOMPELLER_FLUTTER="${DOOMPELLER_FLUTTER:-/Users/savva/fvm/versions/stable/bin/flutter}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$PROJECT_ROOT/assets/shaders/doom_palette.shaderbundle"

if [[ ! -x "$DOOMPELLER_FLUTTER" ]]; then
  echo "error: flutter not found or not executable at $DOOMPELLER_FLUTTER" >&2
  echo "       set DOOMPELLER_FLUTTER to the pinned 3.44.4 SDK" >&2
  exit 1
fi

MODE="build"
case "${1:-}" in
  --watch) MODE="watch" ;;
  --verify) MODE="verify" ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--watch|--verify]" >&2; exit 2 ;;
esac

cd "$PROJECT_ROOT"
mkdir -p assets/shaders

SDK_VERSION="$("$DOOMPELLER_FLUTTER" --version --machine 2>/dev/null | sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' || true)"
if [[ -n "$SDK_VERSION" && "$SDK_VERSION" != "3.44.4" ]]; then
  echo "warning: expected Flutter 3.44.4, found $SDK_VERSION" >&2
  echo "         the shader bundle format is tied to the pinned engine" >&2
fi

if [[ "$MODE" == "watch" ]]; then
  exec "$DOOMPELLER_FLUTTER" pub run flame_3d:build_shaders watch
fi

"$DOOMPELLER_FLUTTER" pub run flame_3d:build_shaders

if [[ ! -s "$BUNDLE" ]]; then
  echo "error: $BUNDLE was not produced" >&2
  exit 1
fi

BYTES="$(wc -c < "$BUNDLE" | tr -d ' ')"
echo "built assets/shaders/doom_palette.shaderbundle ($BYTES bytes)"

if [[ "$MODE" == "verify" ]]; then
  echo "sha256: $(shasum -a 256 "$BUNDLE" | cut -d' ' -f1)"
fi
