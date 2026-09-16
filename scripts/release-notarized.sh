#!/usr/bin/env bash
# Build, Developer ID sign, notarize, staple, and validate the distributable DMG.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IDENTITY=""
KEYCHAIN_PROFILE=""
OUTPUT_DMG=""
WORK_DIR=""
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-24h}"
PRESERVE_WORK_DIR=0
RELEASE_SUCCEEDED=0

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
  if [[ "${PRESERVE_WORK_DIR}" -eq 1 && "${RELEASE_SUCCEEDED}" -ne 1 ]]; then
    echo "Release workspace preserved for notarization recovery:" >&2
    echo "  ${WORK_DIR}" >&2
    echo "Submission IDs:" >&2
    if [[ -s "${WORK_DIR}/notary-submissions.txt" ]]; then
      sed 's/^/  /' "${WORK_DIR}/notary-submissions.txt" >&2
    else
      echo "  (no submission ID was recorded)" >&2
    fi
    return
  fi
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
  local submit_json="${WORK_DIR}/${label}-notary-submit.json"
  local result_json="${WORK_DIR}/${label}-notary-result.json"
  local log_json="${WORK_DIR}/${label}-notary-log.json"
  local history_json="${WORK_DIR}/${label}-notary-history.json"
  local upload_artifact="${WORK_DIR}/notary-upload-${label}-$(basename "${artifact}")"
  local attempt=1
  local max_attempts=3
  local submission_id=""

  echo "Submitting ${label} for notarization…"
  # notarytool has been observed to leave the file it is reading with an invalid
  # outer DMG signature when its connection is interrupted. Always upload a
  # disposable copy so the signed deliverable remains immutable and verifiable.
  cp -X "${artifact}" "${upload_artifact}"
  while ! xcrun notarytool submit "${upload_artifact}" \
      --keychain-profile "${KEYCHAIN_PROFILE}" \
      --no-progress \
      --output-format json > "${submit_json}"; do
    # notarytool can time out after the upload was accepted but before it
    # returns the submission ID. Recover that ID instead of uploading again.
    if xcrun notarytool history \
        --keychain-profile "${KEYCHAIN_PROFILE}" \
        --output-format json > "${history_json}"; then
      local newest_name
      newest_name="$(plutil -extract history.0.name raw -o - "${history_json}" 2>/dev/null || true)"
      if [[ "${newest_name}" == "$(basename "${upload_artifact}")" ]]; then
        submission_id="$(plutil -extract history.0.id raw -o - "${history_json}" 2>/dev/null || true)"
      fi
    fi
    if [[ -n "${submission_id}" ]]; then
      echo "Recovered Apple submission ID after connection timeout: ${submission_id}" >&2
      break
    fi
    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "error: notarization submission failed for ${label} after ${max_attempts} attempts" >&2
      exit 1
    fi
    attempt=$((attempt + 1))
    echo "Notarization connection failed; retrying ${label} (${attempt}/${max_attempts})…" >&2
    sleep 3
  done

  if [[ -z "${submission_id}" ]]; then
    submission_id="$(plutil -extract id raw -o - "${submit_json}" 2>/dev/null || true)"
  fi
  if [[ -z "${submission_id}" ]]; then
    echo "error: Apple did not return a submission ID for ${label}" >&2
    exit 1
  fi
  echo "Apple notarization submission ID for ${label}: ${submission_id}"
  printf '%s=%s\n' "${label}" "${submission_id}" >> "${WORK_DIR}/notary-submissions.txt"
  PRESERVE_WORK_DIR=1

  if ! xcrun notarytool wait "${submission_id}" \
      --keychain-profile "${KEYCHAIN_PROFILE}" \
      --timeout "${NOTARY_TIMEOUT}" \
      --output-format json > "${result_json}"; then
    xcrun notarytool log "${submission_id}" \
      --keychain-profile "${KEYCHAIN_PROFILE}" \
      "${log_json}" >/dev/null 2>&1 || true
    echo "Notarization log: ${log_json}" >&2
    echo "error: notarization wait failed for ${label} (${submission_id})" >&2
    exit 1
  fi

  local status
  status="$(plutil -extract status raw -o - "${result_json}" 2>/dev/null || true)"
  if [[ "${status}" != "Accepted" ]]; then
    xcrun notarytool log "${submission_id}" \
      --keychain-profile "${KEYCHAIN_PROFILE}" \
      "${log_json}" >/dev/null 2>&1 || true
    echo "Notarization log: ${log_json}" >&2
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
RELEASE_SUCCEEDED=1

echo "Release accepted, stapled, and Gatekeeper validated:"
echo "  ${OUTPUT_DMG}"
shasum -a 256 "${OUTPUT_DMG}"
