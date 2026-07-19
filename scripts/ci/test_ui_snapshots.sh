#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/lib/native_xcode_test.sh"
DERIVED_DATA="${ORPHEUS_UI_SNAPSHOT_DERIVED_DATA:-$ROOT/Build/CI/UISnapshotDerivedData}"

mkdir -p "$ROOT/Build/CI/UISnapshots"
run_native_xcode_tests \
    "$ROOT" \
    OrpheusNative \
    UISnapshot \
    "$DERIVED_DATA" \
    "$ROOT/Build/CI/UISnapshotSourcePackages" \
    -only-testing:OrpheusNativeTests/RenderedUISnapshotTests
