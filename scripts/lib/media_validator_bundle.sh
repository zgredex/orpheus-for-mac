#!/bin/sh

verify_media_validator_bundle() {
    validator_bundle_root="$1"
    for validator_component in \
        "$validator_bundle_root/bin/orpheus-media-validator" \
        "$validator_bundle_root/lib/libavcodec.61.dylib" \
        "$validator_bundle_root/lib/libavformat.61.dylib" \
        "$validator_bundle_root/lib/libavutil.59.dylib"; do
        if [ ! -f "$validator_component" ]; then
            printf 'Mandatory media validator component is missing: %s\n' "$validator_component" >&2
            return 1
        fi
        verify_universal_portable_macho "$validator_component"
    done
}
