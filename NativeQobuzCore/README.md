# NativeQobuzCore

An isolated, Python-free Qobuz download engine for Orpheus for Mac.

This package intentionally does not import or invoke the existing OrpheusDL runtime. During the migration, the Python-backed app remains on `main`, while this package is developed on the `native-qobuz` branch and validated against sanitized parity fixtures.

## Boundary

- Qobuz only: track, album, playlist, and artist requests.
- Native URLSession API and media transfers.
- Native structured progress and cancellation.
- No plugin loading, Python configuration, helper process, or CLI parsing.
- Metadata writers and the minimal FFmpeg media validator will be added behind package-local protocols.

The existing Python implementation is a behavioral reference only. It is not a package dependency.
