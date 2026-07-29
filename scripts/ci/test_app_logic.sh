#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/lib/native_xcode_test.sh"
DERIVED_DATA="${ORPHEUS_LOGIC_TEST_DERIVED_DATA:-$ROOT/Build/CI/AppLogicDerivedData}"

run_native_xcode_tests \
    "$ROOT" \
    OrpheusNativeLogicTests \
    AppLogic \
    "$DERIVED_DATA" \
    "$ROOT/Build/CI/AppLogicSourcePackages" \
    "$@"
