#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
ARTIFACT_ROOT="${1:-$ROOT/Build/CI/IntelRelease}"
REPORT="${2:-$ROOT/Build/CI/intel-portability-report.json}"
DMG="$(find "$ARTIFACT_ROOT" -type f -name 'Orpheus-for-Mac-*.dmg' -print -quit)"
MOUNT_POINT="$(mktemp -d '/private/tmp/orpheus intel release.XXXXXX')"

if [ -z "$DMG" ]; then
    echo "Universal release DMG was not found in $ARTIFACT_ROOT" >&2
    exit 1
fi
trap 'hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true; rmdir "$MOUNT_POINT" 2>/dev/null || true' EXIT INT TERM
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_POINT" -quiet
"$ROOT/scripts/verify_native_portability.sh" "$MOUNT_POINT/Orpheus for Mac.app" "$REPORT"
