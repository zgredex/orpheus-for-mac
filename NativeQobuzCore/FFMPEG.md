# Minimal FFmpeg validator

The native Qobuz core bundles a deliberately narrow FFmpeg 7.1.1 validator. It
opens local MP3 or FLAC files and decodes every audio frame. It contains no
conversion, encoding, video, network, filter, device, GPL, or nonfree features.

Build it on Apple Silicon with:

```sh
Scripts/build_media_validator.sh
```

The script downloads the unmodified FFmpeg source from ffmpeg.org, verifies its
pinned SHA-256 (`733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1`),
and records the complete configure invocation in the generated libraries. FFmpeg is
licensed under LGPL 2.1 or later in this configuration. The corresponding
source is available from <https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz>.
The application must ship this notice and sign the validator executable and
all dylibs nested under `Resources/MediaValidator`.
