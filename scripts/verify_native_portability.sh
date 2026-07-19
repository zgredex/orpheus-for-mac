#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/native_macho.sh"
. "$ROOT/scripts/lib/media_validator_bundle.sh"
APP="${1:-$ROOT/dist-native/Orpheus for Mac.app}"
REPORT="${2:-$ROOT/Build/Acceptance/portability-report.json}"
STAGING_ROOT="$(mktemp -d '/private/tmp/orpheus moved app.XXXXXX')"
MOVED_APP="$STAGING_ROOT/Movable Release/Orpheus for Mac.app"
trap 'rm -rf "$STAGING_ROOT"' EXIT INT TERM

require_native_runtime

mkdir -p "$(dirname "$MOVED_APP")" "$(dirname "$REPORT")"
ditto "$APP" "$MOVED_APP"

codesign --verify --deep --strict --verbose=2 "$MOVED_APP"
IDENTIFIER="$(defaults read "$MOVED_APP/Contents/Info" CFBundleIdentifier)"
VERSION="$(defaults read "$MOVED_APP/Contents/Info" CFBundleShortVersionString)"
[ "$IDENTIFIER" = "com.orpheus.formac" ]
[ -n "$VERSION" ]

VALIDATOR_ROOT="$(find "$MOVED_APP/Contents/Resources" -type d -path '*/MediaValidator' -print -quit)"
[ -n "$VALIDATOR_ROOT" ]
verify_media_validator_bundle "$VALIDATOR_ROOT"
verify_universal_portable_machos_in "$MOVED_APP"

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
    '  "architectures": ["arm64", "x86_64"],' \
    "  \"runtimeArchitecture\": \"$NATIVE_RUNTIME_ARCHITECTURE\"," \
    '  "movedBundle": {' \
    '    "status": "passed",' \
    '    "detail": "Codesign, universal architecture, portable dependencies, resources, and native headless launch passed from a moved path."' \
    '  },' \
    '  "cleanAccount": {' \
    "    \"status\": \"$CLEAN_STATUS\"," \
    "    \"detail\": \"$CLEAN_DETAIL\"" \
    '  }' \
    '}' > "$REPORT"

printf 'Portability report: %s\n' "$REPORT"
