# Orpheus for Mac App

This directory contains the SwiftUI adapter for `NativeQobuzCore`.

## Identity and State

- Bundle identifier: `com.orpheus.formac`
- Version: `1.0.0` (`1`)
- Application Support: `~/Library/Application Support/Orpheus for Mac`
- Default downloads: `~/Music/Orpheus for Mac`
- URL schemes: `orpheus-for-mac` and `orpheus-native`

## Architecture

- `NativeViewModel` is the sole published state owner.
- `download-session.json` owns crash recovery for queue and Activity state.
- `.partial` owns resumable audio bytes until a validated transfer completes.
- `.orpheus-library.json` owns logical album, track, and playlist membership.
- `.orpheus-provenance.json` and `checksums.sha256` own physical identity and integrity.
- The archive index is a rebuildable projection, not another authority.

The app is fully self-contained and does not use Python, Homebrew, OrpheusDL, or a runtime helper. The bundled arm64 media validator is mandatory.

## Build and Qualification

```sh
scripts/build_native_release.sh
scripts/run_native_release_qualification.sh
```

The release build stages `dist-native/Orpheus for Mac.app` and a versioned DMG. The qualification harness produces redacted reports under `Build/Acceptance` and only marks a release qualified after automated tests, the live French-account matrix, moved and clean-account portability, and notarization all pass.

## Attribution

The native implementation uses Qobuz responses and these projects as behavioral references:
[OrfiTeam/OrpheusDL](https://github.com/OrfiTeam/OrpheusDL),
[OrfiDev/orpheusdl-qobuz](https://github.com/OrfiDev/orpheusdl-qobuz), and
[TheKVT/orpheusdl-qobuz](https://github.com/TheKVT/orpheusdl-qobuz).
