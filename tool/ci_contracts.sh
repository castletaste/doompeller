#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_ROOT"

# Static source, dependency, ABI and native-stack policy.
sh tool/audit_project_contracts.sh
# Content and release policy has a separate failure domain so a missing header
# or generated artifact does not look like a package-boundary failure.
sh tool/audit_content_contracts.sh

# Focused executable tripwires. The full package and app suites run in their
# normal CI steps; this command keeps only the high-value architectural
# contracts that are not otherwise a separate CI step visible as one gate.
flutter test --no-pub \
  test/adapter/vertex_abi_test.dart \
  test/integration/geometry_adapter_abi_test.dart \
  test/replay_corpus_test.dart
