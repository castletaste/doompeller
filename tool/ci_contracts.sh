#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_ROOT"

# Static layering, content, pin and ABI policy.
sh tool/audit_project_contracts.sh

# Focused executable tripwires. The full package and app suites run in their
# normal CI steps; this command keeps only the high-value architectural
# contracts that are not otherwise a separate CI step visible as one gate.
flutter test --no-pub \
  test/adapter/vertex_abi_test.dart \
  test/integration/geometry_adapter_abi_test.dart \
  test/replay_corpus_test.dart
