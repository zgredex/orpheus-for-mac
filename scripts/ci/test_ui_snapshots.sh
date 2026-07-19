#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/lib/native_macho.sh"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED_DATA="${ORPHEUS_UI_SNAPSHOT_DERIVED_DATA:-$ROOT/Build/CI/UISnapshotDerivedData}"
export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/Build/CI/UISnapshotClangModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/Build/CI/UISnapshotSwiftModuleCache}"

mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$ROOT/Build/CI/UISnapshots"
require_native_runtime
xcodebuild \
    -project "$ROOT/OrpheusNative.xcodeproj" \
    -scheme OrpheusNative \
    -destination "platform=macOS,arch=$NATIVE_RUNTIME_ARCHITECTURE" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$ROOT/Build/CI/UISnapshotSourcePackages" \
    -only-testing:OrpheusNativeTests/RenderedUISnapshotTests \
    test
