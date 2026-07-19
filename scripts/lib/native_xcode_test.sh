#!/bin/sh

run_native_xcode_tests() {
    test_root="$1"
    test_scheme="$2"
    cache_namespace="$3"
    derived_data="$4"
    source_packages="$5"
    shift 5

    . "$test_root/scripts/lib/native_macho.sh"
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    export DEVELOPER_DIR
    export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$test_root/Build/CI/${cache_namespace}ClangModuleCache}"
    export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$test_root/Build/CI/${cache_namespace}SwiftModuleCache}"

    mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
    require_native_runtime
    xcodebuild \
        -project "$test_root/OrpheusNative.xcodeproj" \
        -scheme "$test_scheme" \
        -destination "platform=macOS,arch=$NATIVE_RUNTIME_ARCHITECTURE" \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$source_packages" \
        "$@" \
        test
}
