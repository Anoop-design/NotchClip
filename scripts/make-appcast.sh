#!/usr/bin/env bash
# Generate the EdDSA-signed Sparkle appcast for a directory of release DMGs.
# Read-only with respect to the DMGs; only writes appcast.xml (and Sparkle's
# own delta files) into the release directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RELEASES_DIR=""
OUTPUT_APPCAST=""
DOWNLOAD_URL_PREFIX="https://anoop-design.github.io/NotchClip/"
RELEASE_NOTES_LINK="https://github.com/Anoop-design/NotchClip"
ED_KEY_FILE=""

usage() {
  cat <<'EOF'
Usage: scripts/make-appcast.sh --releases DIR [--output PATH]
                               [--download-url-prefix URL] [--link URL]

  --releases DIR            Directory holding the notarized release DMGs.
                            Every DMG in it becomes an appcast entry.
  --output PATH             Where to write appcast.xml
                            (default: <releases dir>/appcast.xml)
  --download-url-prefix URL Base URL the DMG filenames are appended to. Must
                            match where the DMGs are actually published, or
                            the feed will advertise downloads that 404.
                            (default: https://anoop-design.github.io/NotchClip/)
  --link URL                Project link embedded in each appcast entry.
  --ed-key-file PATH        Sign with an exported private key file instead of
                            the login Keychain. Only needed on a machine whose
                            Keychain does not hold the key.

Signs every entry with the EdDSA private key stored in the login Keychain by
Sparkle's generate_keys. The matching public key must already be in
Packaging/Info.plist as SUPublicEDKey, or installed apps will reject the update.

The first Keychain-backed run shows a macOS prompt asking to let
generate_appcast read the signing key; choose "Always Allow" or the run blocks.

Requires the Sparkle binary artifact to be resolved (run 'swift build' once).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --releases)
      [[ $# -ge 2 ]] || { echo "error: --releases requires a path" >&2; exit 2; }
      RELEASES_DIR="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "error: --output requires a path" >&2; exit 2; }
      OUTPUT_APPCAST="$2"
      shift 2
      ;;
    --download-url-prefix)
      [[ $# -ge 2 ]] || { echo "error: --download-url-prefix requires a URL" >&2; exit 2; }
      DOWNLOAD_URL_PREFIX="$2"
      shift 2
      ;;
    --link)
      [[ $# -ge 2 ]] || { echo "error: --link requires a URL" >&2; exit 2; }
      RELEASE_NOTES_LINK="$2"
      shift 2
      ;;
    --ed-key-file)
      [[ $# -ge 2 ]] || { echo "error: --ed-key-file requires a path" >&2; exit 2; }
      ED_KEY_FILE="$2"
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

[[ -n "${RELEASES_DIR}" ]] || { usage >&2; exit 2; }
if [[ "${RELEASES_DIR}" != /* ]]; then
  RELEASES_DIR="$(pwd)/${RELEASES_DIR}"
fi
[[ -d "${RELEASES_DIR}" ]] || { echo "error: not a directory: ${RELEASES_DIR}" >&2; exit 1; }
RELEASES_DIR="$(cd "${RELEASES_DIR}" && pwd)"

# generate_appcast appends the bare filename, so a missing separator silently
# produces URLs like '…/NotchClipNotchClip-1.0.dmg'.
case "${DOWNLOAD_URL_PREFIX}" in
  https://*/) ;;
  https://*) DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX}/" ;;
  *) echo "error: --download-url-prefix must be an https URL" >&2; exit 1 ;;
esac

if [[ -z "${OUTPUT_APPCAST}" ]]; then
  OUTPUT_APPCAST="${RELEASES_DIR}/appcast.xml"
elif [[ "${OUTPUT_APPCAST}" != /* ]]; then
  OUTPUT_APPCAST="$(pwd)/${OUTPUT_APPCAST}"
fi

DMG_COUNT=0
while IFS= read -r -d '' _dmg; do
  DMG_COUNT=$((DMG_COUNT + 1))
done < <(find "${RELEASES_DIR}" -maxdepth 1 -type f -name '*.dmg' -print0 2>/dev/null)
if [[ "${DMG_COUNT}" -eq 0 ]]; then
  echo "error: no .dmg files in ${RELEASES_DIR}" >&2
  exit 1
fi

# Sparkle ships generate_appcast prebuilt inside its binary artifact.
GENERATE_APPCAST=""
for search_root in "${REPO_ROOT}/.build/artifacts" "${SPARKLE_ARTIFACTS_DIR:-}"; do
  [[ -n "${search_root}" && -d "${search_root}" ]] || continue
  while IFS= read -r candidate; do
    if [[ -x "${candidate}" ]]; then
      GENERATE_APPCAST="${candidate}"
      break
    fi
  done < <(find "${search_root}" -type f -name generate_appcast 2>/dev/null | sort)
  [[ -n "${GENERATE_APPCAST}" ]] && break
done
if [[ -z "${GENERATE_APPCAST}" ]]; then
  echo "error: generate_appcast not found under ${REPO_ROOT}/.build/artifacts" >&2
  echo "Run 'swift build' once so SwiftPM resolves the Sparkle binary artifact." >&2
  exit 1
fi

EXPECTED_ED_KEY="$(plutil -extract SUPublicEDKey raw -o - "${REPO_ROOT}/Packaging/Info.plist" 2>/dev/null || true)"
if [[ -z "${EXPECTED_ED_KEY}" ]]; then
  echo "error: Packaging/Info.plist has no SUPublicEDKey" >&2
  exit 1
fi

SIGNING_ARGS=()
if [[ -n "${ED_KEY_FILE}" ]]; then
  [[ -f "${ED_KEY_FILE}" ]] || { echo "error: no such key file: ${ED_KEY_FILE}" >&2; exit 1; }
  SIGNING_ARGS=(--ed-key-file "${ED_KEY_FILE}")
else
  # The Keychain key must be the one shipped apps trust; a mismatch produces a
  # feed every installed copy silently rejects.
  GENERATE_KEYS="$(dirname "${GENERATE_APPCAST}")/generate_keys"
  if [[ -x "${GENERATE_KEYS}" ]]; then
    KEYCHAIN_ED_KEY="$("${GENERATE_KEYS}" -p 2>/dev/null || true)"
    if [[ -z "${KEYCHAIN_ED_KEY}" ]]; then
      echo "error: no Sparkle EdDSA private key in the login Keychain" >&2
      echo "Restore the backed-up key with: ${GENERATE_KEYS} -f <private-key-file>" >&2
      exit 1
    fi
    if [[ "${KEYCHAIN_ED_KEY}" != "${EXPECTED_ED_KEY}" ]]; then
      echo "error: Keychain signing key does not match SUPublicEDKey in Info.plist" >&2
      echo "  Info.plist: ${EXPECTED_ED_KEY}" >&2
      echo "  Keychain:   ${KEYCHAIN_ED_KEY}" >&2
      exit 1
    fi
  fi
fi

echo "Generating appcast…"
echo "  releases: ${RELEASES_DIR} (${DMG_COUNT} dmg)"
echo "  output:   ${OUTPUT_APPCAST}"
echo "  prefix:   ${DOWNLOAD_URL_PREFIX}"

"${GENERATE_APPCAST}" \
  ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"} \
  --download-url-prefix "${DOWNLOAD_URL_PREFIX}" \
  --link "${RELEASE_NOTES_LINK}" \
  -o "${OUTPUT_APPCAST}" \
  "${RELEASES_DIR}"

[[ -f "${OUTPUT_APPCAST}" ]] || { echo "error: generate_appcast produced no appcast" >&2; exit 1; }
if ! grep -q 'sparkle:edSignature' "${OUTPUT_APPCAST}"; then
  echo "error: appcast has no EdDSA signatures; installed apps would reject it" >&2
  exit 1
fi

echo
echo "Wrote signed appcast:"
echo "  ${OUTPUT_APPCAST}"
echo "Publish it at the SUFeedURL in Packaging/Info.plist, and publish every"
echo "referenced DMG under ${DOWNLOAD_URL_PREFIX}"
