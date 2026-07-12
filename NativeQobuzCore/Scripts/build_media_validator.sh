#!/bin/sh
set -eu

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

FFMPEG_VERSION="7.1.1"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/orpheus-ffmpeg-${FFMPEG_VERSION}"
PREFIX="$WORK/install"
DESTINATION="$ROOT/Sources/NativeQobuzCore/Resources/MediaValidator"
ARCHIVE="$WORK/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SOURCE="$WORK/ffmpeg-${FFMPEG_VERSION}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$WORK"
if [ ! -f "$ARCHIVE" ]; then
    curl -L "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o "$ARCHIVE"
fi
if [ ! -d "$SOURCE" ]; then
    tar -xf "$ARCHIVE" -C "$WORK"
fi

cd "$SOURCE"
./configure \
    --prefix="$PREFIX" \
    --arch=arm64 \
    --target-os=darwin \
    --cc="$(xcrun --find clang)" \
    --host-cc="$(xcrun --find clang)" \
    --host-cflags="-isysroot $SDKROOT -mmacosx-version-min=14.0" \
    --host-ldflags="-isysroot $SDKROOT -mmacosx-version-min=14.0" \
    --extra-cflags="-isysroot $SDKROOT -mmacosx-version-min=14.0" \
    --extra-ldflags="-isysroot $SDKROOT -mmacosx-version-min=14.0" \
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
    --install-name-dir=@rpath

make -j"$(sysctl -n hw.logicalcpu)"
make install

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION/bin" "$DESTINATION/lib" "$DESTINATION/Licenses"
cp "$PREFIX/lib/libavcodec.61.dylib" "$DESTINATION/lib/libavcodec.61.dylib"
cp "$PREFIX/lib/libavformat.61.dylib" "$DESTINATION/lib/libavformat.61.dylib"
cp "$PREFIX/lib/libavutil.59.dylib" "$DESTINATION/lib/libavutil.59.dylib"
cp "$SOURCE/COPYING.LGPLv2.1" "$DESTINATION/Licenses/FFmpeg-COPYING.LGPLv2.1"
cp "$ROOT/Tools/FFMPEG_NOTICE.txt" "$DESTINATION/NOTICE.txt"

"$(xcrun --find clang)" \
    -Os \
    -isysroot "$SDKROOT" \
    -mmacosx-version-min=14.0 \
    -I"$PREFIX/include" \
    "$ROOT/Tools/orpheus_media_validator.c" \
    -L"$PREFIX/lib" \
    -lavformat -lavcodec -lavutil \
    -Wl,-rpath,@loader_path/../lib \
    -o "$DESTINATION/bin/orpheus-media-validator"

strip -x "$DESTINATION/bin/orpheus-media-validator" "$DESTINATION"/lib/*.dylib
printf 'Built minimal FFmpeg %s validator at %s\n' "$FFMPEG_VERSION" "$DESTINATION"
