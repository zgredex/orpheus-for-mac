# Orpheus for Mac

Native macOS companion app for [OrpheusDL](https://github.com/OrfiTeam/OrpheusDL), focused on Qobuz browsing, queueing, and downloads in a portable `.app` bundle.

Orpheus for Mac keeps the familiar power of the OrpheusDL command line, but wraps the common flow in a compact SwiftUI interface: paste links, browse Qobuz, preview albums/tracks/artists, queue several items, and monitor downloads with track counts, byte progress, speed, and Finder reveal actions.

## Highlights

- Native SwiftUI macOS app for Apple Silicon.
- Qobuz link queue for albums, tracks, playlists, and artists.
- Multi-link paste and text-file import.
- Qobuz browse/search with dense album, artist, and track lists.
- Account-region-aware browsing and preview.
- Sequential downloads through bundled OrpheusDL runtime.
- Live activity rows with phase, track/album count, byte progress, speed, cancel, and reveal.
- Self-contained portable `.app` packaging with bundled helper, OrpheusDL template, and optional `ffmpeg`.

## Portability Model

The app bundle is treated as immutable. Mutable data lives outside the bundle:

- Runtime copy: `~/Library/Application Support/OrpheusUI/OrpheusDL`
- Settings: `~/Library/Application Support/OrpheusUI/OrpheusDL/config/settings.json`
- Logs: `~/Library/Application Support/OrpheusUI/orpheus-ui.log`
- Default downloads: `~/Music/OrpheusUI`

The packaged app does not include local Qobuz credentials. First launch installs a sanitized OrpheusDL runtime template into Application Support; later launches refresh runtime code while preserving user settings, credentials, logs, downloads, and temp files.

## Repository Layout

```text
OrpheusUI/
  OrpheusUI/                 SwiftUI app source
  OrpheusUITests/            Unit tests for parsing, queueing, runtime, runner behavior
  Packaging/                 Frozen helper entrypoint and OrpheusDL staging patches
  scripts/build_portable.sh  Portable .app build script
```

The build script expects an upstream OrpheusDL checkout next to this repository, with the Qobuz module installed from [TheKVT/orpheusdl-qobuz](https://github.com/TheKVT/orpheusdl-qobuz):

```text
workspace/
  OrpheusUI/
  OrpheusDL/
    modules/
      qobuz/
```

During packaging, `scripts/build_portable.sh` copies `../OrpheusDL` into a staged template, strips local credentials, applies app-specific packaging patches, freezes the Python helper, and embeds the result in `dist/Orpheus for Mac.app`.

## Build

Requirements:

- macOS 14 or newer.
- Apple Silicon Mac.
- Full Xcode installation.
- Python 3 with `venv`.
- Adjacent OrpheusDL checkout at `../OrpheusDL`.
- Qobuz module from `TheKVT/orpheusdl-qobuz` installed at `../OrpheusDL/modules/qobuz`.

Prepare OrpheusDL and the Qobuz module:

```bash
git clone https://github.com/OrfiTeam/OrpheusDL.git OrpheusDL
git clone https://github.com/TheKVT/orpheusdl-qobuz OrpheusDL/modules/qobuz
```

Then prepare the helper build environment:

```bash
cd OrpheusUI
python3 -m venv Build/pyinstaller-venv
Build/pyinstaller-venv/bin/pip install pyinstaller -r ../OrpheusDL/requirements.txt
```

Build the portable app:

```bash
scripts/build_portable.sh
```

The output is:

```text
dist/Orpheus for Mac.app
```

`ffmpeg` is bundled when the script can find a portable arm64 binary. If none is found, packaged default settings disable codec conversions.

## Test

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project OrpheusUI.xcodeproj \
  -scheme OrpheusUI \
  -destination 'platform=macOS' \
  -derivedDataPath Build/DerivedData \
  test
```

Useful release checks after packaging:

```bash
codesign --verify --deep --strict --verbose=2 'dist/Orpheus for Mac.app'
file 'dist/Orpheus for Mac.app/Contents/MacOS/OrpheusUI'
file 'dist/Orpheus for Mac.app/Contents/Resources/orpheus-helper/orpheus-helper'
file 'dist/Orpheus for Mac.app/Contents/Resources/ffmpeg'
```

## Credentials

Open Settings in the app and enter Qobuz credentials. The app stores them only in the mutable Application Support runtime copy. Build output and committed source should never contain personal Qobuz auth tokens or user IDs.

## Notes

- Downloads are sequential by design to avoid shared OrpheusDL settings conflicts and reduce rate-limit risk.
- The app disables App Sandbox for this first portable release so it can run the bundled helper, write downloads, and reveal files in Finder.
- Multi-region credential fallback is intentionally out of scope; the app reports the account region and lets the user replace credentials when needed.
