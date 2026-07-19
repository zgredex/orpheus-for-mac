#!/bin/sh

require_native_runtime() {
    if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')" = "1" ]; then
        echo "Native qualification cannot run through Rosetta." >&2
        return 1
    fi
    NATIVE_RUNTIME_ARCHITECTURE="$(uname -m)"
    case "$NATIVE_RUNTIME_ARCHITECTURE" in
        arm64|x86_64) ;;
        *)
            printf 'Unsupported native runtime architecture: %s\n' "$NATIVE_RUNTIME_ARCHITECTURE" >&2
            return 1
            ;;
    esac
}

require_universal_macho() {
    binary="$1"
    architectures="$(lipo -archs "$binary")"
    case "$architectures" in
        "arm64 x86_64"|"x86_64 arm64") ;;
        *)
        printf 'Expected exactly arm64 and x86_64 in %s (found: %s)\n' "$binary" "$architectures" >&2
        return 1
        ;;
    esac
}

require_portable_macho_dependencies() {
    binary="$1"
    if otool -L "$binary" | grep -E '^[[:space:]]+/(opt/homebrew|usr/local|Users)/' >/dev/null; then
        printf 'Found a non-portable dependency in %s\n' "$binary" >&2
        otool -L "$binary" >&2
        return 1
    fi
}

verify_universal_portable_macho() {
    require_universal_macho "$1"
    require_portable_macho_dependencies "$1"
}

verify_universal_portable_machos_in() {
    root="$1"
    find "$root" -type f -print | while IFS= read -r candidate; do
        if file -b "$candidate" | grep 'Mach-O' >/dev/null; then
            verify_universal_portable_macho "$candidate"
        fi
    done
}
