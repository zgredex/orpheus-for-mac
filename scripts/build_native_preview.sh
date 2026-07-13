#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED_DATA="$ROOT/Build/NativeReleaseDerivedData"
OUTPUT_DIR="$ROOT/dist-native"
OUTPUT_APP="$OUTPUT_DIR/Orpheus Native Preview.app"

export DEVELOPER_DIR
cd "$ROOT"
xcodegen generate --spec orpheus-native.yml --project .
xcodebuild \
    -project OrpheusNative.xcodeproj \
    -scheme OrpheusNative \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    build

rm -rf "$OUTPUT_APP"
mkdir -p "$OUTPUT_DIR"
ditto "$DERIVED_DATA/Build/Products/Release/OrpheusNative.app" "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

VALIDATOR_ROOT="$(find "$OUTPUT_APP/Contents/Resources" -type d -path '*/MediaValidator' -print -quit)"
if [ -z "$VALIDATOR_ROOT" ]; then
    echo "Mandatory native media validator is missing from the app bundle" >&2
    exit 1
fi
for binary in \
    "$OUTPUT_APP/Contents/MacOS/OrpheusNative" \
    "$VALIDATOR_ROOT/bin/orpheus-media-validator" \
    "$VALIDATOR_ROOT"/lib/*.dylib; do
    if [ "$(lipo -archs "$binary")" != "arm64" ]; then
        printf 'Expected an arm64 binary: %s\n' "$binary" >&2
        exit 1
    fi
    codesign --verify --strict --verbose=2 "$binary"
    if otool -L "$binary" | tail -n +2 | grep -E '/(opt/homebrew|usr/local|Users)/' >/dev/null; then
        printf 'Found a non-portable dependency in %s\n' "$binary" >&2
        otool -L "$binary" >&2
        exit 1
    fi
done

printf 'Built %s\n' "$OUTPUT_APP"
