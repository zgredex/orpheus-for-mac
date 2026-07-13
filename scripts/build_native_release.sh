#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED_DATA="$ROOT/Build/NativeReleaseDerivedData"
OUTPUT_DIR="$ROOT/dist-native"
VERSION="${MARKETING_VERSION:-1.0.0}"
OUTPUT_APP="$OUTPUT_DIR/Orpheus for Mac.app"
OUTPUT_DMG="$OUTPUT_DIR/Orpheus-for-Mac-$VERSION.dmg"
DMG_STAGE="$ROOT/Build/NativeDMGStage"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"

if [ "$REQUIRE_NOTARIZATION" = "1" ] && { [ -z "$CODESIGN_IDENTITY" ] || [ -z "$NOTARYTOOL_PROFILE" ]; }; then
    echo "Release notarization requires CODESIGN_IDENTITY and NOTARYTOOL_PROFILE" >&2
    exit 1
fi

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

if [ -n "$CODESIGN_IDENTITY" ]; then
    for binary in "$VALIDATOR_ROOT"/lib/*.dylib "$VALIDATOR_ROOT"/bin/orpheus-media-validator; do
        codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$binary"
    done
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$OUTPUT_APP"
fi

codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
if [ -z "$CODESIGN_IDENTITY" ]; then
    spctl --assess --type execute --verbose=2 "$OUTPUT_APP" || {
    echo "Gatekeeper assessment is expected to reject an ad-hoc development build." >&2
    }
fi

rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$OUTPUT_APP" "$DMG_STAGE/Orpheus for Mac.app"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$OUTPUT_DMG" "$OUTPUT_DMG.sha256"
hdiutil create \
    -volname "Orpheus for Mac" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$OUTPUT_DMG"

if [ -n "$CODESIGN_IDENTITY" ]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$OUTPUT_DMG"
    codesign --verify --strict --verbose=2 "$OUTPUT_DMG"
fi
hdiutil verify "$OUTPUT_DMG"
DMG_NAME="$(basename "$OUTPUT_DMG")"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)

if [ -n "$NOTARYTOOL_PROFILE" ]; then
    if [ -z "$CODESIGN_IDENTITY" ]; then
        echo "NOTARYTOOL_PROFILE was provided without CODESIGN_IDENTITY" >&2
        exit 1
    fi
    xcrun notarytool submit "$OUTPUT_DMG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple "$OUTPUT_DMG"
    xcrun stapler validate "$OUTPUT_DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$OUTPUT_DMG"
    RELEASE_STATUS="Developer ID signed and notarized"
elif [ -n "$CODESIGN_IDENTITY" ]; then
    RELEASE_STATUS="Developer ID signed, not notarized"
else
    RELEASE_STATUS="Ad-hoc signed development artifact, not notarized"
fi

printf 'Built %s\n' "$OUTPUT_APP"
printf 'Built %s\n' "$OUTPUT_DMG"
printf 'Status: %s\n' "$RELEASE_STATUS"
