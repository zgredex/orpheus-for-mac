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

printf 'Built %s\n' "$OUTPUT_APP"
