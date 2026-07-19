#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/lib/native_macho.sh"
. "$ROOT/scripts/lib/media_validator_bundle.sh"
VALIDATOR_ROOT="$ROOT/NativeQobuzCore/Sources/NativeQobuzCore/Resources/MediaValidator"

verify_media_validator_bundle "$VALIDATOR_ROOT"

printf 'Bundled native binaries contain native arm64 and x86_64 slices.\n'
