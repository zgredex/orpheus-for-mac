#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null 2>&1 || {
    printf 'xcodegen is required for project-drift verification.\n' >&2
    exit 1
}

xcodegen generate --spec orpheus-native.yml --project .
drift="$(git status --porcelain --untracked-files=all -- OrpheusNative.xcodeproj)"
if [ -n "$drift" ]; then
    printf 'OrpheusNative.xcodeproj is out of sync with orpheus-native.yml:\n%s\n' "$drift" >&2
    git diff -- OrpheusNative.xcodeproj >&2 || true
    exit 1
fi
printf 'Generated Xcode project is in sync.\n'
