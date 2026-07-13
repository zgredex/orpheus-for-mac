#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist-native/Orpheus for Mac.app}"
REPORT="${2:-$ROOT/Build/Acceptance/portability-report.json}"
STAGING_ROOT="$(mktemp -d '/private/tmp/orpheus moved app.XXXXXX')"
MOVED_APP="$STAGING_ROOT/Movable Release/Orpheus for Mac.app"
trap 'rm -rf "$STAGING_ROOT"' EXIT INT TERM

mkdir -p "$(dirname "$MOVED_APP")" "$(dirname "$REPORT")"
ditto "$APP" "$MOVED_APP"

codesign --verify --deep --strict --verbose=2 "$MOVED_APP"
IDENTIFIER="$(defaults read "$MOVED_APP/Contents/Info" CFBundleIdentifier)"
VERSION="$(defaults read "$MOVED_APP/Contents/Info" CFBundleShortVersionString)"
[ "$IDENTIFIER" = "com.orpheus.formac" ]
[ -n "$VERSION" ]

VALIDATOR_ROOT="$(find "$MOVED_APP/Contents/Resources" -type d -path '*/MediaValidator' -print -quit)"
[ -n "$VALIDATOR_ROOT" ]
for binary in \
    "$MOVED_APP/Contents/MacOS/OrpheusNative" \
    "$VALIDATOR_ROOT/bin/orpheus-media-validator" \
    "$VALIDATOR_ROOT"/lib/*.dylib; do
    [ "$(lipo -archs "$binary")" = "arm64" ]
    if otool -L "$binary" | tail -n +2 | grep -E '/(opt/homebrew|usr/local|Users)/' >/dev/null; then
        printf 'Non-portable dependency in %s\n' "$binary" >&2
        exit 1
    fi
done

"$MOVED_APP/Contents/MacOS/OrpheusNative" --portability-smoke-test

if [ "${CLEAN_ACCOUNT_VERIFIED:-0}" = "1" ]; then
    CLEAN_STATUS="passed"
    CLEAN_DETAIL="Confirmed externally from a separate clean macOS login."
else
    CLEAN_STATUS="pending"
    CLEAN_DETAIL="Requires launch and download verification from a separate clean macOS login."
fi

printf '%s\n' \
    '{' \
    '  "schemaVersion": 1,' \
    '  "product": "Orpheus for Mac",' \
    "  \"version\": \"$VERSION\"," \
    "  \"bundleIdentifier\": \"$IDENTIFIER\"," \
    '  "movedBundle": {' \
    '    "status": "passed",' \
    '    "detail": "Codesign, arm64 architecture, portable dependencies, resources, and headless launch passed from a moved path."' \
    '  },' \
    '  "cleanAccount": {' \
    "    \"status\": \"$CLEAN_STATUS\"," \
    "    \"detail\": \"$CLEAN_DETAIL\"" \
    '  }' \
    '}' > "$REPORT"

printf 'Portability report: %s\n' "$REPORT"
