#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"

"$ROOT/scripts/ci/test_core.sh" \
    --filter PerformanceBudgetTests
"$ROOT/scripts/ci/test_app_logic.sh" \
    -only-testing:OrpheusNativeLogicTests/NativePerformanceBudgetTests

printf 'Performance budgets passed.\n'
