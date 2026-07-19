# Orpheus for Mac

Orpheus for Mac is a universal native macOS client for browsing and downloading Qobuz. Apple Silicon runs the arm64 slice and Intel runs the x86_64 slice directly; Rosetta is not required. The application, Qobuz client, download engine, metadata writers, integrity checks, and mandatory media validator are bundled in one portable `.app`. Python, Homebrew, OrpheusDL, and a helper daemon are not required at runtime.

## Highlights

- Account-region-aware Qobuz search and direct-link browsing.
- Albums, tracks, playlists, artist catalogs, and label catalogs.
- Mixed-availability albums with unavailable tracks clearly excluded.
- MP3 320, lossless FLAC, and Hi-Res FLAC without lossy re-encoding.
- Crash-safe `.partial` transfers, fresh signed URLs, validated HTTP Range resume, and clean restart fallback.
- Native FLAC and ID3 metadata, embedded and external artwork, booklets, relative M3U playlists, and SHA-256 manifests.
- One canonical physical audio file with explicit Library membership for albums, standalone tracks, and playlists.
- Structured, rotating diagnostics with exact timestamps, source file/function/line, error details, and correlated request, queue, activity, transfer, validation, and Library scan identifiers.
- A mandatory universal FFmpeg-derived validator containing only the components used for MP3 and FLAC decode checks.

## Portability

The app bundle is immutable. Mutable state is stored in:

- Application Support: `~/Library/Application Support/Orpheus for Mac`
- Default downloads: `~/Music/Orpheus for Mac`

Credentials are stored in an owner-only `credentials.json` file. It contains the Qobuz App ID, App Secret, and auth token. A Qobuz account user ID is neither stored nor sent as an App ID.

## Diagnostics

Open the in-app diagnostics viewer with `Command-Shift-L` or the Diagnostics toolbar button. Events can be searched and filtered by severity and subsystem; selecting one shows its exact timestamp, source location, function, thread, native error domain and code, chained underlying errors, correlation metadata, and a captured call stack for failures.

Persistent JSONL logs are stored in `~/Library/Application Support/Orpheus for Mac/Logs`. The active file rotates at 5 MiB and retains eight archives. Warnings and errors are flushed immediately. Diagnostic export creates a self-contained folder with the logs, a sanitized system/queue/activity/Library report, this process's available Unified Log entries, and up to ten recent matching macOS `.ips` or `.crash` reports. `collection-status.json` records which optional artifacts were collected or why they were unavailable. The export never requests the privileged system-wide log, so it adds no administrator or special-entitlement requirement. Qobuz tokens, secrets, signatures, and authorization values are redacted before OSLog, disk persistence, display, or export; crash reports can still contain local paths and system details and should be reviewed before public sharing.

## Build

Requirements:

- macOS 14 or newer on Apple Silicon or Intel.
- Full Xcode installation.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).

Build the release app and DMG:

```sh
scripts/build_native_release.sh
```

Development output is ad-hoc signed. For a distributable release, install a Developer ID Application certificate and a `notarytool` Keychain profile, then run:

```sh
CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
NOTARYTOOL_PROFILE='orpheus-notary' \
REQUIRE_NOTARIZATION=1 \
scripts/build_native_release.sh
```

Artifacts:

```text
dist-native/Orpheus for Mac.app
dist-native/Orpheus-for-Mac-1.0.0.dmg
dist-native/Orpheus-for-Mac-1.0.0.dmg.sha256
```

The build fails if any bundled Mach-O does not contain exactly the native arm64 and x86_64 slices, or links to Homebrew, `/usr/local`, or a user-specific path. `REQUIRE_NOTARIZATION=1` fails closed when signing or notarization credentials are unavailable.

## Qualification

The release harness runs app and core tests, the live French-account matrix, packaging, a moved-bundle launch, clean-account evidence, and notarization validation. It writes redacted logs and JSON reports under `Build/Acceptance`.

```sh
QOBUZ_CREDENTIALS_FILE="$HOME/Library/Application Support/Orpheus for Mac/credentials.json" \
scripts/run_native_release_qualification.sh
```

The live matrix covers album, track, playlist, artist, label, all search categories, mixed availability, all three qualities, cancellation, persisted resume state, fresh signed URLs, decode validation, metadata, artwork, checksums, duplicate reuse, and Library segregation. Release qualification remains false until a separate clean macOS login has been tested and the DMG has a valid notarization ticket.

## Repository Layout

```text
NativeQobuzCore/                 Qobuz API, download, media, integrity, and Library core
OrpheusNative/                   SwiftUI application
OrpheusNativeTests/              App adapter, persistence, and workflow tests
orpheus-native.yml               XcodeGen project and release identity
scripts/build_native_release.sh  App/DMG signing and notarization pipeline
scripts/run_native_release_qualification.sh
```

## Browser Handoff

The release registers `orpheus-for-mac://open?url=...` and retains `orpheus-native://` as an equivalent deep-link alias. Both routes open account-verified Browse detail and never bypass availability checks or add directly to the queue.

## Attribution

The native implementation was independently written in Swift, using Qobuz API responses and the established Orpheus projects as behavioral references:

- [OrfiTeam/OrpheusDL](https://github.com/OrfiTeam/OrpheusDL)
- [OrfiDev/orpheusdl-qobuz](https://github.com/OrfiDev/orpheusdl-qobuz)
- [TheKVT/orpheusdl-qobuz](https://github.com/TheKVT/orpheusdl-qobuz)

Those projects and their contributors deserve credit for documenting and refining the Qobuz/Orpheus workflows that informed compatibility. Their code is not required by the native app at runtime.
