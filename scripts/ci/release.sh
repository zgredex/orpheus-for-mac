#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
REPORT="$ROOT/Build/CI/portability-report.json"

env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    "$ROOT/scripts/build_native_release.sh"
"$ROOT/scripts/verify_native_portability.sh" \
    "$ROOT/dist-native/Orpheus for Mac.app" \
    "$REPORT"
