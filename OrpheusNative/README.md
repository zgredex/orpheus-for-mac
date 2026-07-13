# Orpheus Native Preview

This is the isolated SwiftUI adapter for `NativeQobuzCore`. It is intentionally
separate from the Python-backed production application.

## Isolation

- Project: `OrpheusNative.xcodeproj`
- Bundle identifier: `com.orpheus.native.preview`
- Settings: `~/Library/Application Support/OrpheusNativePreview/settings.json`
- Credentials: owner-only `credentials.json` in Application Support
- Queue and activity recovery: `download-session.json` in Application Support
- Default downloads: `~/Music/Orpheus Native Preview`

It does not read or write the production OrpheusDL runtime, settings, helper,
credentials, or Application Support folder.

Active transfers retain hidden partial files and reopen as paused after an app
restart. Resume preserves the original quality and destination while obtaining
a fresh signed Qobuz media URL.

## Build

```sh
scripts/build_native_preview.sh
```

The script regenerates the Xcode project from `orpheus-native.yml`, builds an
arm64 Release app, signs the nested minimal FFmpeg validator, verifies the full
bundle, and stages `dist-native/Orpheus Native Preview.app`.

## Current workflow

- Paste one or many Qobuz links into the compact input field.
- Import links from plain text or M3U files.
- Search albums, artists, and tracks against the configured account region.
- Review metadata and collection tracks in the right workspace.
- Download selected or all ready queue items sequentially.
- Inspect aggregate track/file progress, speed, tagging, validation, and
  SHA-256 state in Activity.
- Cancel active work, clear completed activity, or reveal output in Finder.
- Resume interrupted work after a network failure or app restart.
