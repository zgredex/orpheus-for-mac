# Orpheus Native Preview

This is the isolated SwiftUI adapter for `NativeQobuzCore`. It is intentionally
separate from the Python-backed production application.

## Isolation

- Project: `OrpheusNative.xcodeproj`
- Bundle identifier: `com.orpheus.native.preview`
- Settings: `~/Library/Application Support/OrpheusNativePreview/settings.json`
- Credentials: owner-only `credentials.json` containing the Qobuz App ID,
  App Secret, and auth token only. Account User IDs are neither stored nor sent.
- Queue and activity recovery: `download-session.json` in Application Support
- Default downloads: `~/Music/Orpheus Native Preview`

It does not read or write the production OrpheusDL runtime, settings, helper,
credentials, or Application Support folder.

Active transfers retain hidden partial files and reopen as paused after an app
restart. Resume preserves the original quality and destination while obtaining
a fresh signed Qobuz media URL.

The app is fully portable and self-contained. It does not require Python,
Homebrew, OrpheusDL, or a helper daemon at runtime. Its mandatory arm64 media
validator contains only the FFmpeg components used to decode-check MP3 and FLAC.

## Build

```sh
scripts/build_native_preview.sh
```

The script regenerates the Xcode project from `orpheus-native.yml`, builds an
arm64 Release app, signs the nested minimal FFmpeg validator, verifies the full
bundle, and stages `dist-native/Orpheus Native Preview.app`.

## Current workflow

- Paste one Qobuz link to open its account-verified Browse detail without
  changing the queue. Paste or import several links to stage them in the Link
  Inbox, where up to three are verified concurrently before review.
- Add albums, tracks, playlists, artist catalogs, or label catalogs only after the
  Qobuz response confirms availability for the current account region.
- Open an album's label to browse its available catalog, select releases, or
  queue the full label catalog.
- Search albums, artists, playlists, and tracks against the configured account
  region.
- Review metadata, artwork, source quality, and collection tracks in the right
  workspace. Mixed albums remain usable while unavailable tracks are labeled
  and skipped.
- Download selected or all ready queue items sequentially.
- Inspect aggregate track/file progress, speed, tagging, validation, and
  SHA-256 state in Activity, with the requested output quality always visible.
- Browse verified downloads in a Library that keeps albums, standalone tracks,
  and playlists in separate sections while storing one canonical physical copy
  of each matching audio file. Portable relative M3U files and
  `.orpheus-library.json` preserve logical collection membership without
  duplicating audio bytes.
- Cancel active work, clear completed activity, or reveal output in Finder.
- Resume interrupted work after a network failure or app restart.

Quality colors are consistent throughout the app: orange is Hi-Res, teal is
lossless FLAC, blue is MP3 320, and indigo marks mixed-quality collections.

## Browser handoff

The app registers `orpheus-native://open?url=...`. A browser integration can
percent-encode any supported Qobuz URL into that query parameter; macOS opens
the app and routes it through the same account-region verification used by the
paste field. The scheme never bypasses Browse or adds directly to the queue.

## Library ownership

- `.orpheus-provenance.json` and `checksums.sha256` identify and verify physical
  audio files.
- The root `.orpheus-library.json` is the single source of truth for logical
  album, track, and playlist membership.
- Playlist M3U entries are relative to the download root, so moving the whole
  library preserves them.
- Older downloads without a library manifest remain visible through a
  provenance-based compatibility projection.

## State ownership

- `NativeViewModel` is the sole published owner of app state. Views render it
  and route commands back through it; they do not maintain shadow queue,
  download, browse, or library models.
- `NativeBrowseResults` owns all search categories as one value. Loading and
  errors remain category-scoped, while changing tabs never starts a request or
  rewrites another category's results.
- `download-session.json` is the crash-recovery snapshot for the queue and
  activity timeline. It does not own downloaded-library membership.
- `.orpheus-library.json` owns logical library membership; provenance and
  checksum sidecars own physical file identity and integrity. The archive index
  is a rebuildable cache/projection of those files, not a second authority.

## Attribution

The native implementation was independently written against Qobuz responses
and uses the established Orpheus projects as behavioral references:
[OrfiTeam/OrpheusDL](https://github.com/OrfiTeam/OrpheusDL),
[OrfiDev/orpheusdl-qobuz](https://github.com/OrfiDev/orpheusdl-qobuz), and
[TheKVT/orpheusdl-qobuz](https://github.com/TheKVT/orpheusdl-qobuz).
