#!/bin/sh
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/native_macho.sh"
OUTPUT="${QOBUZ_ACCEPTANCE_OUTPUT:-$ROOT/Build/Acceptance}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CREDENTIALS="${QOBUZ_CREDENTIALS_FILE:-$HOME/Library/Application Support/Orpheus for Mac/configuration.json}"
PREVIEW_CREDENTIALS="$HOME/Library/Application Support/OrpheusNativePreview/configuration.json"
VERSION="${MARKETING_VERSION:-1.0.0}"
APP="$ROOT/dist-native/Orpheus for Mac.app"
DMG="$ROOT/dist-native/Orpheus-for-Mac-$VERSION.dmg"

if ! require_native_runtime; then
    exit 1
fi

if [ ! -f "$CREDENTIALS" ] && [ -f "$PREVIEW_CREDENTIALS" ]; then
    CREDENTIALS="$PREVIEW_CREDENTIALS"
fi

mkdir -p "$OUTPUT"

redact_log() {
    raw="$1"
    destination="$2"
    sed -E \
        -e "s#$HOME#~#g" \
        -e 's#https?://[^[:space:]]+#[REDACTED URL]#g' \
        -e 's#(token|secret|authorization)[=: ][^[:space:],;]+#\1=[REDACTED]#Ig' \
        "$raw" > "$destination"
    rm -f "$raw"
}

run_step() {
    name="$1"
    shift
    raw="$OUTPUT/.$name.raw.log"
    "$@" > "$raw" 2>&1
    status=$?
    redact_log "$raw" "$OUTPUT/$name.log"
    return "$status"
}

cd "$ROOT"
run_step xcodegen xcodegen generate --spec orpheus-native.yml --project .
xcodegen_status=$?

if [ "$xcodegen_status" -eq 0 ]; then
    run_step app-tests env DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
        -project OrpheusNative.xcodeproj \
        -scheme OrpheusNative \
        -destination "platform=macOS,arch=$NATIVE_RUNTIME_ARCHITECTURE" \
        -derivedDataPath "$ROOT/Build/NativeQualificationDerivedData" \
        test
    app_tests_status=$?
else
    app_tests_status=1
fi

run_step core-tests env \
    DEVELOPER_DIR="$DEVELOPER_DIR" \
    CLANG_MODULE_CACHE_PATH=/private/tmp/orpheus-native-clang-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/orpheus-native-swiftpm-cache \
    xcrun swift test --disable-sandbox --package-path "$ROOT/NativeQobuzCore"
core_tests_status=$?

run_step live-acceptance env \
    DEVELOPER_DIR="$DEVELOPER_DIR" \
    CLANG_MODULE_CACHE_PATH=/private/tmp/orpheus-native-clang-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/orpheus-native-swiftpm-cache \
    QOBUZ_CREDENTIALS_FILE="$CREDENTIALS" \
    QOBUZ_ACCEPTANCE_OUTPUT="$OUTPUT" \
    QOBUZ_ACCEPTANCE_DOWNLOADS=1 \
    xcrun swift run --disable-sandbox --package-path "$ROOT/NativeQobuzCore" native-qobuz-acceptance
live_status=$?

run_step package env \
    DEVELOPER_DIR="$DEVELOPER_DIR" \
    MARKETING_VERSION="$VERSION" \
    CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}" \
    NOTARYTOOL_KEY="${NOTARYTOOL_KEY:-}" \
    NOTARYTOOL_KEY_ID="${NOTARYTOOL_KEY_ID:-}" \
    NOTARYTOOL_ISSUER="${NOTARYTOOL_ISSUER:-}" \
    REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}" \
    "$ROOT/scripts/build_native_release.sh"
package_status=$?

if [ "$package_status" -eq 0 ]; then
    run_step portability env \
        CLEAN_ACCOUNT_VERIFIED="${CLEAN_ACCOUNT_VERIFIED:-0}" \
        "$ROOT/scripts/verify_native_portability.sh" "$APP" "$OUTPUT/portability-report.json"
    portability_status=$?
else
    portability_status=1
fi

if [ "${CLEAN_ACCOUNT_VERIFIED:-0}" = "1" ]; then clean_status=0; else clean_status=1; fi
if [ -d "$APP" ] && codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'Authority=Developer ID Application'; then
    signing_status=0
else
    signing_status=1
fi
if [ -f "$DMG" ] && xcrun stapler validate "$DMG" >/dev/null 2>&1; then notary_status=0; else notary_status=1; fi

status_name() {
    if [ "$1" -eq 0 ]; then printf passed; else printf failed; fi
}

release_qualified=false
if [ "$app_tests_status" -eq 0 ] \
    && [ "$core_tests_status" -eq 0 ] \
    && [ "$live_status" -eq 0 ] \
    && [ "$package_status" -eq 0 ] \
    && [ "$portability_status" -eq 0 ] \
    && [ "$clean_status" -eq 0 ] \
    && [ "$signing_status" -eq 0 ] \
    && [ "$notary_status" -eq 0 ]; then
    release_qualified=true
fi

printf '%s\n' \
    '{' \
    '  "schemaVersion": 1,' \
    '  "product": "Orpheus for Mac",' \
    "  \"version\": \"$VERSION\"," \
    '  "checks": {' \
    "    \"appTests\": \"$(status_name "$app_tests_status")\"," \
    "    \"coreTests\": \"$(status_name "$core_tests_status")\"," \
    "    \"liveFrenchAccountMatrix\": \"$(status_name "$live_status")\"," \
    "    \"packaging\": \"$(status_name "$package_status")\"," \
    "    \"movedBundle\": \"$(status_name "$portability_status")\"," \
    "    \"cleanMacOSAccount\": \"$([ "$clean_status" -eq 0 ] && printf passed || printf pending)\"," \
    "    \"developerIDSigning\": \"$([ "$signing_status" -eq 0 ] && printf passed || printf pending)\"," \
    "    \"notarization\": \"$([ "$notary_status" -eq 0 ] && printf passed || printf pending)\"" \
    '  },' \
    "  \"releaseQualified\": $release_qualified" \
    '}' > "$OUTPUT/release-qualification.json"

printf 'Release qualification report: %s\n' "$OUTPUT/release-qualification.json"
[ "$release_qualified" = true ]
