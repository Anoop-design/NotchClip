#!/usr/bin/env bash
# Build, Developer ID sign, notarize, staple, and validate the distributable DMG.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IDENTITY=""
KEYCHAIN_PROFILE=""
OUTPUT_DMG=""
WORK_DIR=""

usage() {
  cat <<'EOF'
Usage: scripts/release-notarized.sh \
  --identity "Developer ID Application: Name (TEAMID)" \
  --keychain-profile PROFILE \
  [--output PATH]

Requires an existing Developer ID Application certificate/private key and an
existing notarytool Keychain profile. Builds and notarizes the app first, then
creates, signs, notarizes, staples, and Gatekeeper-validates the final DMG.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      [[ $# -ge 2 ]] || { echo "error: --identity requires a value" >&2; exit 2; }
      IDENTITY="$2"
      shift 2
      ;;
    --keychain-profile)
      [[ $# -ge 2 ]] || { echo "error: --keychain-profile requires a value" >&2; exit 2; }
      KEYCHAIN_PROFILE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "error: --output requires a path" >&2; exit 2; }
      OUTPUT_DMG="$2"
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

[[ -n "${IDENTITY}" && -n "${KEYCHAIN_PROFILE}" ]] || { usage >&2; exit 2; }
case "${IDENTITY}" in
  "Developer ID Application: "*) ;;
  *) echo "error: --identity must be a Developer ID Application identity" >&2; exit 1 ;;
esac

if ! security find-identity -v -p codesigning | grep -F "${IDENTITY}" >/dev/null; then
  echo "error: Developer ID identity is not available in the current Keychain:" >&2
  echo "  ${IDENTITY}" >&2
  exit 1
fi

for command_name in codesign ditto hdiutil plutil security spctl xcrun; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "error: required command is unavailable: ${command_name}" >&2
    exit 1
  }
done

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${REPO_ROOT}/Packaging/Info.plist")"
ARCH="$(uname -m)"
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

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-release.XXXXXX")"
APP_PATH="${WORK_DIR}/NotchClip.app"
APP_ZIP="${WORK_DIR}/NotchClip.zip"
DMG_PATH="${WORK_DIR}/NotchClip-${VERSION}-${ARCH}.dmg"

cleanup() {
  case "${WORK_DIR}" in
    "${TMPDIR:-/tmp}"/notchclip-release.*|/tmp/notchclip-release.*|/private/tmp/notchclip-release.*)
      [[ -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
      ;;
  esac
}
trap cleanup EXIT

notarize() {
  local artifact="$1"
  local label="$2"
  local result_json="${WORK_DIR}/${label}-notary-result.json"
  local log_json="${WORK_DIR}/${label}-notary-log.json"

  echo "Submitting ${label} for notarization…"
  if ! xcrun notarytool submit "${artifact}" \
    --keychain-profile "${KEYCHAIN_PROFILE}" \
    --wait \
    --timeout 30m \
    --output-format json > "${result_json}"; then
    local failed_id
    failed_id="$(plutil -extract id raw -o - "${result_json}" 2>/dev/null || true)"
    if [[ -n "${failed_id}" ]]; then
      xcrun notarytool log "${failed_id}" \
        --keychain-profile "${KEYCHAIN_PROFILE}" \
        "${log_json}" >/dev/null 2>&1 || true
      echo "Notarization log: ${log_json}" >&2
    fi
    echo "error: notarization submission failed for ${label}" >&2
    exit 1
  fi

  local status
  status="$(plutil -extract status raw -o - "${result_json}" 2>/dev/null || true)"
  if [[ "${status}" != "Accepted" ]]; then
    local submission_id
    submission_id="$(plutil -extract id raw -o - "${result_json}" 2>/dev/null || true)"
    if [[ -n "${submission_id}" ]]; then
      xcrun notarytool log "${submission_id}" \
        --keychain-profile "${KEYCHAIN_PROFILE}" \
        "${log_json}" >/dev/null 2>&1 || true
      echo "Notarization log: ${log_json}" >&2
    fi
    echo "error: Apple notarization status for ${label}: ${status:-unknown}" >&2
    exit 1
  fi
  echo "Apple notarization status for ${label}: Accepted"
}

"${SCRIPT_DIR}/build-app.sh" \
  --output "${APP_PATH}" \
  --scratch "${WORK_DIR}/build" \
  --sign "${IDENTITY}"

"${SCRIPT_DIR}/verify-app.sh" "${APP_PATH}"
CODESIGN_DETAILS="$(codesign --display --verbose=4 "${APP_PATH}" 2>&1)"
grep -q 'flags=.*runtime' <<< "${CODESIGN_DETAILS}" || {
  echo "error: hardened runtime flag is missing from the app signature" >&2
  exit 1
}

ditto -c -k --keepParent "${APP_PATH}" "${APP_ZIP}"
notarize "${APP_ZIP}" "app"
xcrun stapler staple -v "${APP_PATH}"
xcrun stapler validate -v "${APP_PATH}"
spctl -a -vv -t exec "${APP_PATH}"

"${SCRIPT_DIR}/build-dmg.sh" \
  --app "${APP_PATH}" \
  --output "${DMG_PATH}" \
  --sign "${IDENTITY}"

notarize "${DMG_PATH}" "dmg"
xcrun stapler staple -v "${DMG_PATH}"
xcrun stapler validate -v "${DMG_PATH}"
codesign --verify --verbose=4 "${DMG_PATH}"
hdiutil verify "${DMG_PATH}" >/dev/null
spctl -a -vv -t open --context context:primary-signature "${DMG_PATH}"

mkdir -p "$(dirname "${OUTPUT_DMG}")"
mv "${DMG_PATH}" "${OUTPUT_DMG}"

echo "Release accepted, stapled, and Gatekeeper validated:"
echo "  ${OUTPUT_DMG}"
shasum -a 256 "${OUTPUT_DMG}"
