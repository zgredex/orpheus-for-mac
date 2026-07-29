#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
LIMITS="$ROOT/scripts/ci/architecture-line-limits.txt"
FILEMANAGER_ALLOWLIST="$ROOT/scripts/ci/core-filemanager-allowlist.txt"
DEFAULT_MAX_LINES=350
failed=0

relative_path() {
    case "$1" in
        "$ROOT"/*) printf '%s\n' "${1#"$ROOT"/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

configured_limit() {
    awk -F '|' -v path="$1" '
        $0 !~ /^#/ && $1 == path { print $2; found = 1; exit }
        END { if (!found) print "" }
    ' "$LIMITS"
}

while IFS= read -r file; do
    relative="$(relative_path "$file")"
    lines="$(wc -l < "$file" | tr -d ' ')"
    limit="$(configured_limit "$relative")"
    if [ -z "$limit" ]; then limit="$DEFAULT_MAX_LINES"; fi
    if [ "$lines" -gt "$limit" ]; then
        printf 'Architecture limit exceeded: %s has %s lines (maximum %s)\n' "$relative" "$lines" "$limit" >&2
        failed=1
    fi
done <<EOF
$(find "$ROOT/NativeQobuzCore/Sources/NativeQobuzCore" "$ROOT/OrpheusNative" -type f -name '*.swift' | sort)
EOF

actual_filemanager="$(mktemp -t orpheus-filemanager-actual.XXXXXX)"
allowed_filemanager="$(mktemp -t orpheus-filemanager-allowed.XXXXXX)"
trap 'rm -f "$actual_filemanager" "$allowed_filemanager"' EXIT INT TERM

rg -l 'FileManager' "$ROOT/NativeQobuzCore/Sources/NativeQobuzCore" --glob '*.swift' \
    | while IFS= read -r file; do relative_path "$file"; done \
    | sort -u > "$actual_filemanager"
awk '$0 !~ /^#/ && NF { print }' "$FILEMANAGER_ALLOWLIST" | sort -u > "$allowed_filemanager"

new_filemanager_users="$(comm -13 "$allowed_filemanager" "$actual_filemanager")"
if [ -n "$new_filemanager_users" ]; then
    printf 'New NativeQobuzCore FileManager bypasses are forbidden:\n%s\n' "$new_filemanager_users" >&2
    failed=1
fi

definition_count() {
    pattern="$1"
    count="$(rg -n "$pattern" "$ROOT/NativeQobuzCore/Sources/NativeQobuzCore" "$ROOT/OrpheusNative" --glob '*.swift' | wc -l | tr -d ' ')"
    if [ "$count" -ne 1 ]; then
        printf 'Expected one authoritative definition matching %s; found %s\n' "$pattern" "$count" >&2
        failed=1
    fi
}

definition_count '^(public )?enum QobuzQuality[ :{]'
definition_count '^(public )?enum QobuzAudioFormat[ :{]'
definition_count '^enum NativeDownloadStatus[ :{]'
definition_count '^struct NativeDownloadOperation[ :{]'

if rg -n '^[[:space:]]+(var|let) status:' \
    "$ROOT/OrpheusNative/Support/Queue/NativeQueueModels.swift" \
    "$ROOT/OrpheusNative/Support/Download/NativeDownloadActivity.swift"; then
    printf 'Queue and Activity payloads must not own download status.\n' >&2
    failed=1
fi

unexpected_renderers="$(
    rg -n 'ImageRenderer[[:space:]]*\(' "$ROOT/OrpheusNativeTests" \
        --glob '*.swift' \
        --glob '!Rendered*.swift' \
        || true
)"
if [ -n "$unexpected_renderers" ]; then
    printf 'ImageRenderer belongs only in the dedicated rendered UI suite:\n%s\n' "$unexpected_renderers" >&2
    failed=1
fi

forbidden_keychain="$(
    rg -n -i 'SecItem|kSec[A-Z]|keychain' \
        "$ROOT/NativeQobuzCore/Sources" \
        "$ROOT/OrpheusNative" \
        "$ROOT/scripts" \
        "$ROOT/README.md" \
        --glob '*.swift' \
        --glob '*.sh' \
        --glob '*.md' \
        --glob '!verify_architecture.sh' \
        || true
)"
if [ -n "$forbidden_keychain" ]; then
    printf 'Apple Keychain use is forbidden by project policy:\n%s\n' "$forbidden_keychain" >&2
    failed=1
fi

crash_primitives="$(
    rg -n 'try!|fatalError[[:space:]]*\(|preconditionFailure[[:space:]]*\(|as!' \
        "$ROOT/NativeQobuzCore/Sources/NativeQobuzCore" \
        "$ROOT/OrpheusNative" \
        --glob '*.swift' \
        || true
)"
if [ -n "$crash_primitives" ]; then
    printf 'Production crash primitives are forbidden:\n%s\n' "$crash_primitives" >&2
    failed=1
fi

if [ "$failed" -ne 0 ]; then exit 1; fi
"$ROOT/scripts/ci/verify_duplication.py"
printf 'Architecture guardrails passed.\n'
