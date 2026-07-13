# NativeQobuzCore

An isolated, Python-free Qobuz download engine for Orpheus for Mac.

This package intentionally does not import or invoke the existing OrpheusDL runtime. During the migration, the Python-backed app remains on `main`, while this package is developed on the `native-qobuz` branch and validated against sanitized parity fixtures.

## Boundary

- Qobuz only: track, album, playlist, and artist requests.
- Native URLSession API and media transfers.
- Native structured progress and cancellation.
- Crash-safe partial files with validated HTTP Range resume.
- Native ID3v2.3 and FLAC Vorbis metadata with Qobuz/OrpheusDL tag parity.
- Embedded original Qobuz artwork, album covers, booklets, and extended M3U files.
- Mandatory decode validation and SHA-256 manifests for final music files.
- No plugin loading, Python configuration, helper process, or CLI parsing.

The existing Python implementation is a behavioral reference only. It is not a package dependency.

## Audio integrity

The core never re-encodes or converts downloaded audio. MP3 MPEG frames and
FLAC audio frames remain byte-for-byte unchanged while metadata blocks are
written atomically. Before a staged file receives its final name, the bundled
minimal FFmpeg validator decodes every audio frame. The engine records both the
SHA-256 of the final tagged file in `checksums.sha256` and a private provenance
sidecar containing its Qobuz track, album, format, bit depth, and sample rate.

Existing files are skipped only when provenance, requested quality, decode
validation, and SHA-256 all match. Unknown files are preserved under their
original names; a verified Qobuz download receives a deterministic ID suffix.

Interrupted transfers retain their hidden `.partial` file. A resumed run gets
a new signed media URL, appends only after Qobuz confirms the exact byte range,
and safely restarts from zero when the server ignores or rejects that range.

The 1.3 MB arm64 validator build contains local-file input plus MP3/FLAC
demuxers, parsers, and decoders only. See [FFMPEG.md](FFMPEG.md) for its exact
LGPL build recipe and source information.
