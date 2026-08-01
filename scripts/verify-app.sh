#!/usr/bin/env bash
# Read-only verification of a NotchClip.app bundle.
# Does not launch, mutate, sign, or delete the bundle.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-app.sh PATH/To/NotchClip.app

Read-only checks for a well-formed, validly signed NotchClip app bundle.
Does not launch, mutate, sign, or delete the bundle.
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

APP="$1"
if [[ "${APP}" != /* ]]; then
  APP="$(pwd)/${APP}"
fi
# Normalize when the app directory exists (handles paths with spaces).
if [[ -d "${APP}" ]]; then
  APP="$(cd "${APP}" && pwd)"
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "OK: $*"
}

[[ -d "${APP}" ]] || fail "not a directory: ${APP}"
case "${APP}" in
  *.app) ;;
  *) fail "path must end in .app: ${APP}" ;;
esac

PLIST="${APP}/Contents/Info.plist"
EXE="${APP}/Contents/MacOS/NotchClip"
ICON="${APP}/Contents/Resources/AppIcon.icns"

[[ -f "${PLIST}" ]] || fail "missing Contents/Info.plist"
[[ -f "${EXE}" ]] || fail "missing Contents/MacOS/NotchClip"
[[ -x "${EXE}" ]] || fail "Contents/MacOS/NotchClip is not executable"
[[ -f "${ICON}" ]] || fail "missing Contents/Resources/AppIcon.icns"

if ! plutil -lint "${PLIST}" >/dev/null; then
  fail "Info.plist failed plutil -lint"
fi
pass "Info.plist lints"

read_key() {
  local key="$1"
  plutil -extract "${key}" raw -o - "${PLIST}" 2>/dev/null || true
}

BUNDLE_ID="$(read_key CFBundleIdentifier)"
[[ "${BUNDLE_ID}" == "com.anoop.notchclip" ]] || fail "CFBundleIdentifier is '${BUNDLE_ID}', expected com.anoop.notchclip"
pass "CFBundleIdentifier=${BUNDLE_ID}"

EXEC_NAME="$(read_key CFBundleExecutable)"
[[ "${EXEC_NAME}" == "NotchClip" ]] || fail "CFBundleExecutable is '${EXEC_NAME}', expected NotchClip"
pass "CFBundleExecutable=${EXEC_NAME}"

MIN_OS="$(read_key LSMinimumSystemVersion)"
[[ "${MIN_OS}" == "14.0" ]] || fail "LSMinimumSystemVersion is '${MIN_OS}', expected 14.0"
pass "LSMinimumSystemVersion=${MIN_OS}"

# LSUIElement must be Boolean true (not string "true").
UI_TYPE="$(plutil -type LSUIElement "${PLIST}" 2>/dev/null || true)"
[[ "${UI_TYPE}" == "bool" || "${UI_TYPE}" == "boolean" ]] || fail "LSUIElement type is '${UI_TYPE}', expected bool"
UI_VAL="$(read_key LSUIElement)"
[[ "${UI_VAL}" == "true" ]] || fail "LSUIElement is '${UI_VAL}', expected true"
pass "LSUIElement=true (boolean)"

ICON_NAME="$(read_key CFBundleIconFile)"
[[ "${ICON_NAME}" == "AppIcon" || "${ICON_NAME}" == "AppIcon.icns" ]] || fail "CFBundleIconFile is '${ICON_NAME}', expected AppIcon"
pass "custom AppIcon.icns is configured"

# A shipped build that cannot update itself can never be fixed in place, so the
# updater's framework and all three Sparkle keys are hard requirements.
SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework"
[[ -d "${SPARKLE}" ]] || fail "missing Contents/Frameworks/Sparkle.framework"
[[ -e "${SPARKLE}/Versions/Current/Sparkle" ]] || fail "Sparkle.framework has no Versions/Current/Sparkle"
pass "Sparkle.framework is embedded"

FEED_URL="$(read_key SUFeedURL)"
case "${FEED_URL}" in
  https://*) ;;
  *) fail "SUFeedURL is '${FEED_URL}', expected an https URL" ;;
esac
pass "SUFeedURL=${FEED_URL}"

PUBLIC_ED_KEY="$(read_key SUPublicEDKey)"
[[ -n "${PUBLIC_ED_KEY}" ]] || fail "missing SUPublicEDKey; updates could not be verified"
pass "SUPublicEDKey is present"

AUTOMATIC_CHECKS_TYPE="$(plutil -type SUEnableAutomaticChecks "${PLIST}" 2>/dev/null || true)"
[[ "${AUTOMATIC_CHECKS_TYPE}" == "bool" || "${AUTOMATIC_CHECKS_TYPE}" == "boolean" ]] \
  || fail "SUEnableAutomaticChecks type is '${AUTOMATIC_CHECKS_TYPE}', expected bool"
pass "SUEnableAutomaticChecks is a boolean"

FILE_OUT="$(file -b "${EXE}" 2>/dev/null || true)"
case "${FILE_OUT}" in
  *Mach-O*) ;;
  *) fail "executable is not Mach-O: ${FILE_OUT}" ;;
esac
pass "executable is Mach-O"

ARCHS=""
if command -v lipo >/dev/null 2>&1; then
  ARCHS="$(lipo -archs "${EXE}" 2>/dev/null || true)"
fi
if [[ -z "${ARCHS}" ]]; then
  ARCHS="$(printf '%s\n' "${FILE_OUT}" | sed -n 's/.*Mach-O 64-bit executable \([^ ]*\).*/\1/p')"
fi
[[ -n "${ARCHS}" ]] || fail "could not determine architecture(s)"
pass "architecture(s): ${ARCHS}"

if ! command -v otool >/dev/null 2>&1; then
  fail "otool not available; cannot inspect linked libraries"
fi

# Signature state (read-only). Apple Silicon will not launch a completely
# unsigned binary, and a linker-only signature does not cover the bundle plist.
command -v codesign >/dev/null 2>&1 || fail "codesign not available; cannot verify signature state"
if ! CODESIGN_VERIFY_OUT="$(codesign --verify --deep --strict "${APP}" 2>&1)"; then
  fail "bundle does not have a valid completed-bundle signature (${CODESIGN_VERIFY_OUT//$'\n'/; })"
fi

SIGNATURE_INFO="$(codesign -d --verbose=4 "${APP}" 2>&1 || true)"
if printf '%s\n' "${SIGNATURE_INFO}" | grep -q 'Signature=adhoc'; then
  pass "bundle has a valid local ad-hoc signature"
  echo "signature_state=valid_ad_hoc"
else
  pass "bundle has a valid code signature"
  echo "signature_state=valid_signed"
fi

# Inspect only absolute path tokens from dylib loads and rpath commands.
LINK_PATHS="$(
  {
    otool -L "${EXE}" 2>/dev/null || true
    otool -l "${EXE}" 2>/dev/null || true
  } | awk '
    # otool -L lines: "\t/path (compatibility ...)"
    /^\t\// {
      path = $1
      sub(/^\t/, "", path)
      print path
      next
    }
    # LC_LOAD_DYLIB / LC_RPATH path lines: "         name /path" or "         path /path"
    /^([[:space:]]+)(name|path)[[:space:]]+\// {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^\//) {
          print $i
          break
        }
      }
    }
  '
)"

SUSPECT=""
while IFS= read -r path; do
  [[ -n "${path}" ]] || continue
  case "${path}" in
    */.build/*|*/.build)
      SUSPECT+="${path}"$'\n'
      ;;
    /tmp/*|/private/tmp/*)
      SUSPECT+="${path}"$'\n'
      ;;
    /var/folders/*|/private/var/folders/*)
      SUSPECT+="${path}"$'\n'
      ;;
    *"/Notch clip"*|*"/Documents/Notch"*)
      SUSPECT+="${path}"$'\n'
      ;;
  esac
done <<< "${LINK_PATHS}"

if [[ -n "${SUSPECT//[[:space:]]/}" ]]; then
  echo "FAIL: binary appears to depend on repo, .build, or temporary paths:" >&2
  printf '%s' "${SUSPECT}" >&2
  exit 1
fi
pass "no linked repo/.build/tmp path dependencies detected"

echo
echo "Verification passed: ${APP}"
