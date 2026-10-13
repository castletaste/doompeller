#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_ROOT"

fail() {
  echo "CONTENT AUDIT FAIL: $1" >&2
  exit 1
}

command -v rg >/dev/null 2>&1 || fail "ripgrep (rg) is required"

need_line() {
  pattern=$1
  file=$2
  rg -q "$pattern" "$file" || fail "missing expected release setting in $file: $pattern"
}

# Commercial content must never enter the index or any commit. The generated
# fixture is source code and has no WAD file on disk.
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

echo "CONTENT AUDIT PASS: content hygiene, release headers, and generated web policy"
