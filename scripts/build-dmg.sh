#!/usr/bin/env bash
# Build a polished drag-to-Applications DMG around an already signed NotchClip.app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_PATH=""
OUTPUT_DMG=""
SIGNING_IDENTITY="-"
VOLUME_NAME="NotchClip Installer"
WORK_DIR=""
MOUNT_DIR=""
DEVICE=""

usage() {
  cat <<'EOF'
Usage: scripts/build-dmg.sh --app PATH [--output PATH] [--sign IDENTITY]

  --app PATH       Signed NotchClip.app to package (required)
  --output PATH    Destination DMG (default: dist/NotchClip-<version>-<arch>.dmg)
  --sign IDENTITY  Sign the finished DMG with this Developer ID identity
                   (default '-' leaves the DMG itself unsigned)

Creates a branded Finder window with NotchClip on the left, an Applications
shortcut on the right, and a saved drag-to-install layout. Refuses to overwrite.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "error: --app requires a path" >&2; exit 2; }
      APP_PATH="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "error: --output requires a path" >&2; exit 2; }
      OUTPUT_DMG="$2"
      shift 2
      ;;
    --sign)
      [[ $# -ge 2 ]] || { echo "error: --sign requires an identity" >&2; exit 2; }
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "${APP_PATH}" ]] || { usage >&2; exit 2; }
if [[ "${APP_PATH}" != /* ]]; then
  APP_PATH="$(pwd)/${APP_PATH}"
fi
[[ -d "${APP_PATH}" ]] || { echo "error: app not found: ${APP_PATH}" >&2; exit 1; }

PLIST="${APP_PATH}/Contents/Info.plist"
[[ -f "${PLIST}" ]] || { echo "error: app Info.plist missing" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${PLIST}")"
EXE="${APP_PATH}/Contents/MacOS/NotchClip"
ARCH="$(lipo -archs "${EXE}" | tr ' ' '-')"
if [[ -z "${OUTPUT_DMG}" ]]; then
  OUTPUT_DMG="${REPO_ROOT}/dist/NotchClip-${VERSION}-${ARCH}.dmg"
elif [[ "${OUTPUT_DMG}" != /* ]]; then
  OUTPUT_DMG="$(pwd)/${OUTPUT_DMG}"
fi

[[ ! -e "${OUTPUT_DMG}" ]] || {
  echo "error: output already exists: ${OUTPUT_DMG}" >&2
  echo "Choose another --output path; refusing to overwrite." >&2
  exit 1
}

BACKGROUND="${REPO_ROOT}/Packaging/DMG/installer-background.png"
[[ -f "${BACKGROUND}" ]] || { echo "error: missing DMG background: ${BACKGROUND}" >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-dmg.XXXXXX")"
STAGE_DIR="${WORK_DIR}/stage"
RW_DMG="${WORK_DIR}/NotchClip-rw.dmg"
FINAL_TMP="${WORK_DIR}/NotchClip-final.dmg"

cleanup() {
  if [[ -n "${DEVICE}" ]]; then
    hdiutil detach "${DEVICE}" -force >/dev/null 2>&1 || true
    DEVICE=""
  fi
  case "${WORK_DIR}" in
    "${TMPDIR:-/tmp}"/notchclip-dmg.*|/tmp/notchclip-dmg.*|/private/tmp/notchclip-dmg.*)
      [[ -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
      ;;
  esac
}
trap cleanup EXIT

mkdir -p "${STAGE_DIR}/.background"
ditto --noqtn "${APP_PATH}" "${STAGE_DIR}/NotchClip.app"
ln -s /Applications "${STAGE_DIR}/Applications"
cp "${BACKGROUND}" "${STAGE_DIR}/.background/installer-background.png"
if [[ -f "${APP_PATH}/Contents/Resources/AppIcon.icns" ]]; then
  cp "${APP_PATH}/Contents/Resources/AppIcon.icns" "${STAGE_DIR}/.VolumeIcon.icns"
fi

hdiutil create \
  -srcfolder "${STAGE_DIR}" \
  -volname "${VOLUME_NAME}" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "${RW_DMG}" >/dev/null

ATTACH_PLIST="${WORK_DIR}/attach.plist"
hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -plist \
  "${RW_DMG}" > "${ATTACH_PLIST}"
DEVICE="$(plutil -extract system-entities.0.dev-entry raw -o - "${ATTACH_PLIST}" 2>/dev/null || true)"
if [[ -z "${DEVICE}" ]]; then
  DEVICE="$(plutil -convert json -o - "${ATTACH_PLIST}" | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((e.get("dev-entry", "") for e in d.get("system-entities", []) if e.get("mount-point")), ""))')"
fi
[[ -n "${DEVICE}" ]] || { echo "error: could not determine mounted DMG device" >&2; exit 1; }
MOUNT_DIR="$(plutil -convert json -o - "${ATTACH_PLIST}" | \
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((e.get("mount-point", "") for e in d.get("system-entities", []) if e.get("mount-point")), ""))')"
[[ -n "${MOUNT_DIR}" && -d "${MOUNT_DIR}" ]] || {
  echo "error: could not determine mounted DMG path" >&2
  exit 1
}

# Finder writes the window geometry and icon placement into the volume's .DS_Store.
osascript - "${MOUNT_DIR}" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set mountedFolder to POSIX file mountPath as alias
    set backgroundFile to POSIX file (mountPath & "/.background/installer-background.png") as alias
    tell application "Finder"
        open mountedFolder
        set installerWindow to container window of mountedFolder
        set current view of installerWindow to icon view
        try
            set toolbar visible of installerWindow to false
        end try
        try
            set statusbar visible of installerWindow to false
        end try
        try
            set pathbar visible of installerWindow to false
        end try
        try
            set sidebar width of installerWindow to 0
        end try
        set bounds of installerWindow to {120, 120, 800, 560}
        set iconOptions to icon view options of installerWindow
        set arrangement of iconOptions to not arranged
        set icon size of iconOptions to 112
        set text size of iconOptions to 13
        set background picture of iconOptions to backgroundFile
        set position of item "NotchClip.app" of mountedFolder to {170, 235}
        set position of item "Applications" of mountedFolder to {510, 235}
        update mountedFolder without registering applications
        delay 1
        try
            close installerWindow
        end try
    end tell
end run
APPLESCRIPT

[[ -f "${MOUNT_DIR}/.DS_Store" ]] || { echo "error: Finder did not save the DMG layout" >&2; exit 1; }
if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.FinderInfo "${MOUNT_DIR}/NotchClip.app" 2>/dev/null || true
  xattr -dr com.apple.ResourceFork "${MOUNT_DIR}/NotchClip.app" 2>/dev/null || true
fi
codesign --verify --deep --strict --verbose=2 "${MOUNT_DIR}/NotchClip.app"
sync
hdiutil detach "${DEVICE}" >/dev/null
DEVICE=""

hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -o "${FINAL_TMP}" >/dev/null

if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${FINAL_TMP}"
  codesign --verify --verbose=2 "${FINAL_TMP}"
fi
hdiutil verify "${FINAL_TMP}" >/dev/null

mkdir -p "$(dirname "${OUTPUT_DMG}")"
mv "${FINAL_TMP}" "${OUTPUT_DMG}"

echo "Built polished drag-to-Applications DMG:"
echo "  ${OUTPUT_DMG}"
echo "Finder layout: 680×440, app left, Applications right, branded background."
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  echo "The DMG itself is not Developer ID signed or notarized."
fi
