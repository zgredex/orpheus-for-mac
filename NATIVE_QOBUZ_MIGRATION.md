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
2. Native FLAC and ID3 metadata writers with Python parity fixtures.
3. Artwork, booklet, playlist, duplicate, and partial-file behavior.
4. Minimal mandatory FFmpeg media validator built from pinned source.
5. Native app adapter and a separate preview bundle identifier/Application Support root.
6. Differential testing against the frozen Python behavior.
7. Remove Python packaging only after the native backend passes the parity matrix.

## Current Milestone

The first vertical slice provides:

- signed account and file URL requests
- track, album, playlist, and artist expansion
- stable ordering and artist album deduplication
- direct URLSession downloads
- atomic `.partial` file installation
- byte progress, speed, cancellation, and aggregate track progress
- deterministic Qobuz output paths
- synthetic unit tests and credential-gated French-account integration tests

The package is not connected to the production app and cannot replace its download engine yet.
