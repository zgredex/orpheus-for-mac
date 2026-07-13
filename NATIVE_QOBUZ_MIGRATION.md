# Native Qobuz Migration

## Isolation

The Python-free implementation lives on the `native-qobuz` branch and in the sibling `OrpheusUI-Native` worktree. The current release app remains on `main` in `OrpheusUI`.

`NativeQobuzCore` is a standalone Swift package. It must not import, invoke, or write to:

- `OrpheusRunner`
- the frozen Python helper
- the mutable OrpheusDL runtime
- Python settings under Application Support
- the existing production download directory during tests

Live integration tests accept credentials only through environment variables and use disposable output directories. Credentials and signed media URLs must never be recorded in fixtures or logs.

## Replacement Sequence

1. Native Qobuz API, request signing, catalog resolution, and direct transfer.
2. Native FLAC and ID3 metadata writers with Python parity fixtures. Complete.
3. Artwork, booklet, playlist, duplicate, and partial-file behavior. Complete.
4. Minimal mandatory FFmpeg media validator built from pinned source. Complete.
5. Native app adapter and a separate preview bundle identifier/Application Support root. Complete.
6. Native acceptance matrix and release packaging pipeline. Complete.
7. Developer ID signing, notarization, and clean-account release evidence. Pending release credentials and external verification.

## Current Milestone

The native core currently provides:

- signed account and file URL requests
- track, album, playlist, and artist expansion
- stable ordering and artist album deduplication
- direct URLSession downloads with validated HTTP Range resume
- persistent `.partial` files and safe full-transfer fallback
- byte progress, speed, cancellation, and aggregate track progress
- deterministic Qobuz output paths
- atomic ID3v2.3 and FLAC Vorbis/Picture metadata writing
- OrpheusDL-compatible artist, credit, numbering, date, ISRC, UPC, label,
  copyright, genre, and explicit-rating tags
- original-resolution embedded/external artwork, PDF booklets, and relative
  extended M3U playlists
- a mandatory 1.3 MB arm64 LGPL FFmpeg validator containing only MP3/FLAC
  local-file decoding components
- full final-form decode validation without audio conversion or re-encoding
- SHA-256 manifests and verification of existing downloads before skip
- synthetic unit tests and credential-gated French-account integration tests

Live French-account checks confirm direct MP3/FLAC transfer, metadata and
1400x1400 cover embedding, complete decode validation, and final SHA-256
generation. Native album search has also been verified against the FR account.

`OrpheusNative.xcodeproj` now builds the 1.0 release app as `com.orpheus.formac`.
It uses an owner-only credential file, release Application Support root, and
release download directory. On first launch it safely copies native Preview
state without overwriting release data or deleting the rollback source. It
supports multi-link queueing, text import, native account-region search,
metadata previews, sequential downloads, persistent queue/activity recovery,
resumable partial transfers, progress/speed, cancellation, integrity state, and
Finder reveal.

Release qualification runs app and core tests, a redacted live French-account
matrix, app and DMG packaging, moved-bundle portability checks, clean-account
evidence, Developer ID verification, and notarization validation. A report may
only mark the release qualified when every required gate passes.
