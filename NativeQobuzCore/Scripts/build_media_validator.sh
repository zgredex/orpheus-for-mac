#!/bin/sh
set -eu

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

FFMPEG_VERSION="7.1.1"
FFMPEG_SHA256="733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
REPOSITORY_ROOT="$(CDPATH= cd -- "$ROOT/.." && pwd)"
. "$REPOSITORY_ROOT/scripts/lib/native_macho.sh"
. "$REPOSITORY_ROOT/scripts/lib/media_validator_bundle.sh"
WORK="${TMPDIR:-/tmp}/orpheus-ffmpeg-${FFMPEG_VERSION}"
DESTINATION="$ROOT/Sources/NativeQobuzCore/Resources/MediaValidator"
ARCHIVE="$WORK/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --find clang)"

mkdir -p "$WORK"
if [ ! -f "$ARCHIVE" ]; then
    DOWNLOAD="$ARCHIVE.download"
    rm -f "$DOWNLOAD"
    curl --fail --location --proto '=https' --tlsv1.2 \
        "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
        -o "$DOWNLOAD"
    printf '%s  %s\n' "$FFMPEG_SHA256" "$DOWNLOAD" | shasum -a 256 -c -
    mv "$DOWNLOAD" "$ARCHIVE"
fi
printf '%s  %s\n' "$FFMPEG_SHA256" "$ARCHIVE" | shasum -a 256 -c -

build_architecture() {
    architecture="$1"
    build_root="$WORK/build-$architecture"
    source="$build_root/ffmpeg-${FFMPEG_VERSION}"
    prefix="$WORK/install-$architecture"
    validator="$WORK/orpheus-media-validator-$architecture"
    cross_compile=""
    architecture_options=""
    if [ "$(uname -m)" != "$architecture" ]; then
        cross_compile="--enable-cross-compile"
    fi
    if [ "$architecture" = "x86_64" ]; then
        architecture_options="--disable-x86asm"
    fi

    rm -rf "$build_root" "$prefix" "$validator"
    mkdir -p "$build_root"
    tar -xf "$ARCHIVE" -C "$build_root"
    cd "$source"
    ./configure \
        --prefix="$prefix" \
        --arch="$architecture" \
        --target-os=darwin \
        --cc="$CLANG -arch $architecture" \
        --host-cc="$CLANG" \
        --host-cflags="-isysroot $SDKROOT -mmacosx-version-min=14.0" \
        --host-ldflags="-isysroot $SDKROOT -mmacosx-version-min=14.0" \
        --extra-cflags="-arch $architecture -isysroot $SDKROOT -mmacosx-version-min=14.0" \
        --extra-ldflags="-arch $architecture -isysroot $SDKROOT -mmacosx-version-min=14.0" \
        --disable-static \
        --enable-shared \
        --disable-programs \
        --disable-avdevice \
        --disable-avfilter \
        --disable-swscale \
        --disable-swresample \
        --disable-doc \
        --disable-debug \
        --disable-autodetect \
        --disable-network \
        --disable-everything \
        --enable-avcodec \
        --enable-avformat \
        --enable-avutil \
        --enable-protocol=file \
        --enable-demuxer=flac,mp3 \
        --enable-decoder=flac,mp3 \
        --enable-parser=flac,mpegaudio \
        --install-name-dir=@rpath \
        $cross_compile \
        $architecture_options

    make -j"$(sysctl -n hw.logicalcpu)"
    make install
    "$CLANG" \
        -arch "$architecture" \
        -Os \
        -isysroot "$SDKROOT" \
        -mmacosx-version-min=14.0 \
        -I"$prefix/include" \
        "$ROOT/Tools/orpheus_media_validator.c" \
        -L"$prefix/lib" \
        -lavformat -lavcodec -lavutil \
        -Wl,-rpath,@loader_path/../lib \
        -o "$validator"
    strip -x "$validator" "$prefix"/lib/libavcodec.61.dylib \
        "$prefix"/lib/libavformat.61.dylib "$prefix"/lib/libavutil.59.dylib
}

build_architecture arm64
build_architecture x86_64

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION/bin" "$DESTINATION/lib" "$DESTINATION/Licenses"
for library in libavcodec.61.dylib libavformat.61.dylib libavutil.59.dylib; do
    lipo -create \
        "$WORK/install-arm64/lib/$library" \
        "$WORK/install-x86_64/lib/$library" \
        -output "$DESTINATION/lib/$library"
done
lipo -create \
    "$WORK/orpheus-media-validator-arm64" \
    "$WORK/orpheus-media-validator-x86_64" \
    -output "$DESTINATION/bin/orpheus-media-validator"
cp "$WORK/build-arm64/ffmpeg-${FFMPEG_VERSION}/COPYING.LGPLv2.1" \
    "$DESTINATION/Licenses/FFmpeg-COPYING.LGPLv2.1"
cp "$ROOT/Tools/FFMPEG_NOTICE.txt" "$DESTINATION/NOTICE.txt"

verify_media_validator_bundle "$DESTINATION"
printf 'Built universal minimal FFmpeg %s validator at %s\n' "$FFMPEG_VERSION" "$DESTINATION"
