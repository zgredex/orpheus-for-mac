#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/Build"
STAGE_DIR="${BUILD_DIR}/stage"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
DIST_DIR="${PROJECT_DIR}/dist"
SOURCE_APP_NAME="OrpheusUI"
APP_NAME="Orpheus for Mac"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
LEGACY_APP_BUNDLE="${DIST_DIR}/${SOURCE_APP_NAME}.app"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"
TEMPLATE_DIR="${STAGE_DIR}/OrpheusDLTemplate"
HELPER_DIST="${BUILD_DIR}/helper-dist"
ORPHEUSDL_SOURCE="${WORKSPACE_ROOT}/OrpheusDL"
QOBUZ_MODULE_DIR="${ORPHEUSDL_SOURCE}/modules/qobuz"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ -n "${ORPHEUS_BUILD_PYTHON:-}" ]]; then
  BUILD_PYTHON="${ORPHEUS_BUILD_PYTHON}"
elif [[ -x "${BUILD_DIR}/pyinstaller-venv/bin/python" ]]; then
  BUILD_PYTHON="${BUILD_DIR}/pyinstaller-venv/bin/python"
else
  BUILD_PYTHON="python3"
fi

mkdir -p "${BUILD_DIR}" "${DIST_DIR}" "${STAGE_DIR}"
export PYINSTALLER_CONFIG_DIR="${BUILD_DIR}/pyinstaller-config"

if [[ ! -f "${ORPHEUSDL_SOURCE}/orpheus.py" ]]; then
  echo "Missing OrpheusDL checkout at ${ORPHEUSDL_SOURCE}." >&2
  echo "Clone OrpheusDL next to this repository before packaging." >&2
  exit 2
fi

if [[ ! -f "${QOBUZ_MODULE_DIR}/interface.py" || ! -f "${QOBUZ_MODULE_DIR}/qobuz_api.py" ]]; then
  echo "Missing Qobuz module at ${QOBUZ_MODULE_DIR}." >&2
  echo "Install it with: git clone https://github.com/TheKVT/orpheusdl-qobuz '${QOBUZ_MODULE_DIR}'" >&2
  exit 2
fi

is_portable_ffmpeg() {
  local candidate="$1"
  [[ -x "${candidate}" ]] || return 1

  local file_info
  file_info="$(file "${candidate}" 2>/dev/null || true)"
  [[ "${file_info}" == *"Mach-O"* && "${file_info}" == *"arm64"* ]] || return 1

  if otool -L "${candidate}" 2>/dev/null | grep -Eq '(/opt/homebrew|/usr/local|@rpath|@loader_path|@executable_path)'; then
    return 1
  fi

  return 0
}

find_portable_ffmpeg() {
  local candidates=()
  if [[ -n "${FFMPEG_PATH:-}" ]]; then
    candidates+=("${FFMPEG_PATH}")
  fi
  candidates+=(
    "${PROJECT_DIR}/Packaging/ffmpeg"
    "${PROJECT_DIR}/Packaging/bin/ffmpeg"
    "${BUILD_DIR}/vendor/ffmpeg"
  )
  if command -v ffmpeg >/dev/null 2>&1; then
    candidates+=("$(command -v ffmpeg)")
  fi
  while IFS= read -r -d '' candidate; do
    candidates+=("${candidate}")
  done < <(find /Applications -path "*/Contents/MacOS/ffmpeg" -type f -perm +111 -print0 2>/dev/null || true)

  local candidate
  for candidate in "${candidates[@]}"; do
    if is_portable_ffmpeg "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

PORTABLE_FFMPEG_SOURCE="$(find_portable_ffmpeg || true)"
if [[ -n "${FFMPEG_PATH:-}" && -z "${PORTABLE_FFMPEG_SOURCE}" ]]; then
  echo "FFMPEG_PATH was set, but it is not an executable arm64 macOS binary with portable dependencies: ${FFMPEG_PATH}" >&2
  exit 2
fi

echo "==> Staging sanitized OrpheusDL template"
rm -rf "${TEMPLATE_DIR}"
rsync -a \
  --exclude ".git" \
  --exclude ".DS_Store" \
  --exclude "__pycache__" \
  --exclude "downloads" \
  --exclude "temp" \
  --exclude "config/loginstorage.bin" \
  "${ORPHEUSDL_SOURCE}/" \
  "${TEMPLATE_DIR}/"

if ! grep -q "def download_album_extras" "${TEMPLATE_DIR}/orpheus/music_downloader.py"; then
  patch -p1 -d "${TEMPLATE_DIR}" < "${PROJECT_DIR}/Packaging/orpheusdl-defer-album-extras.patch"
fi

DISABLE_CONVERSIONS=$([[ -z "${PORTABLE_FFMPEG_SOURCE}" ]] && printf '1' || printf '0') \
"${BUILD_PYTHON}" - "${TEMPLATE_DIR}/config/settings.json" <<'PY'
import json
import os
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
settings = json.loads(settings_path.read_text())
qobuz = settings.setdefault("modules", {}).setdefault("qobuz", {})
qobuz["auth_token"] = ""
qobuz["user_id"] = ""
settings.setdefault("global", {}).setdefault("general", {})["download_path"] = "~/Music/OrpheusUI"
if os.environ.get("DISABLE_CONVERSIONS") == "1":
    settings.setdefault("global", {}).setdefault("advanced", {})["codec_conversions"] = {}
settings_path.write_text(json.dumps(settings, indent=4, ensure_ascii=False) + "\n")
PY

echo "==> Building frozen Orpheus helper"
rm -rf "${HELPER_DIST}"
mkdir -p "${HELPER_DIST}"
if [[ -n "${ORPHEUS_HELPER_DIR:-}" ]]; then
  cp -R "${ORPHEUS_HELPER_DIR}" "${HELPER_DIST}/orpheus-helper"
elif [[ -n "${ORPHEUS_HELPER_BINARY:-}" ]]; then
  cp "${ORPHEUS_HELPER_BINARY}" "${HELPER_DIST}/orpheus-helper"
elif "${BUILD_PYTHON}" -m PyInstaller --version >/dev/null 2>&1; then
  "${BUILD_PYTHON}" -m PyInstaller \
    --clean \
    --onedir \
    --name orpheus-helper \
    --distpath "${HELPER_DIST}" \
    --workpath "${BUILD_DIR}/helper-work" \
    --specpath "${BUILD_DIR}/helper-spec" \
    --hidden-import requests \
    --hidden-import tqdm \
    --hidden-import mutagen \
    --collect-all PIL \
    --hidden-import Cryptodome \
    --hidden-import ffmpeg \
    --hidden-import m3u8 \
    --hidden-import defusedxml \
    --hidden-import google.protobuf \
    "${PROJECT_DIR}/Packaging/orpheus_helper.py"
else
  echo "PyInstaller is required to build the self-contained helper." >&2
  echo "Install it in the build Python, set ORPHEUS_HELPER_DIR to a prebuilt onedir helper, or set ORPHEUS_HELPER_BINARY to a legacy arm64 helper." >&2
  exit 2
fi
if [[ -d "${HELPER_DIST}/orpheus-helper" ]]; then
  chmod +x "${HELPER_DIST}/orpheus-helper/orpheus-helper"
else
  chmod +x "${HELPER_DIST}/orpheus-helper"
fi

echo "==> Building SwiftUI app with Xcode"
DEVELOPER_DIR="${DEVELOPER_DIR}" xcodebuild \
  -project "${PROJECT_DIR}/OrpheusUI.xcodeproj" \
  -scheme OrpheusUI \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf "${APP_BUNDLE}"
if [[ "${LEGACY_APP_BUNDLE}" != "${APP_BUNDLE}" ]]; then
  rm -rf "${LEGACY_APP_BUNDLE}"
fi
cp -R "${DERIVED_DATA}/Build/Products/Release/${SOURCE_APP_NAME}.app" "${APP_BUNDLE}"
mkdir -p "${RESOURCES_DIR}"

echo "==> Installing portable resources"
rm -rf "${RESOURCES_DIR}/OrpheusDLTemplate"
cp -R "${TEMPLATE_DIR}" "${RESOURCES_DIR}/OrpheusDLTemplate"
rm -rf "${RESOURCES_DIR}/orpheus-helper"
cp -R "${HELPER_DIST}/orpheus-helper" "${RESOURCES_DIR}/orpheus-helper"
if [[ -d "${RESOURCES_DIR}/orpheus-helper" ]]; then
  chmod +x "${RESOURCES_DIR}/orpheus-helper/orpheus-helper"
else
  chmod +x "${RESOURCES_DIR}/orpheus-helper"
fi
xattr -cr "${RESOURCES_DIR}/orpheus-helper" 2>/dev/null || true

if [[ -n "${PORTABLE_FFMPEG_SOURCE}" ]]; then
  echo "==> Bundling ffmpeg from ${PORTABLE_FFMPEG_SOURCE}"
  cp "${PORTABLE_FFMPEG_SOURCE}" "${RESOURCES_DIR}/ffmpeg"
  chmod +x "${RESOURCES_DIR}/ffmpeg"
  xattr -cr "${RESOURCES_DIR}/ffmpeg" 2>/dev/null || true
else
  echo "No ffmpeg found; packaged settings disable codec conversions by default."
fi

echo "==> Signing app"
if [[ -d "${RESOURCES_DIR}/orpheus-helper" ]]; then
  while IFS= read -r -d '' code_file; do
    codesign --force --sign "${CODESIGN_IDENTITY:--}" "${code_file}" 2>/dev/null || true
  done < <(find "${RESOURCES_DIR}/orpheus-helper" -type f \( -perm +111 -o -name "*.dylib" -o -name "*.so" \) -print0)
else
  codesign --force --sign "${CODESIGN_IDENTITY:--}" "${RESOURCES_DIR}/orpheus-helper" 2>/dev/null || true
fi
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "${APP_BUNDLE}"

echo "Built ${APP_BUNDLE}"
