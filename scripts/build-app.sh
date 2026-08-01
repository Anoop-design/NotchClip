#!/usr/bin/env bash
# Assemble a signed native-architecture NotchClip.app from SwiftPM.
# Defaults to a local ad-hoc signature; pass --sign for Developer ID release signing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_APP="${REPO_ROOT}/dist/NotchClip.app"
SCRATCH=""
OWNED_SCRATCH=0
STAGE_DIR=""
INSTALL_TMP=""
SIGNING_IDENTITY="-"
CONFIGURATION="release"

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [--output PATH] [--scratch PATH] [--sign IDENTITY]
                            [--configuration debug|release]

  --output PATH   Destination .app bundle path (default: <repo>/dist/NotchClip.app)
  --scratch PATH  Optional build directory (default: mktemp -d). Staging always
                  uses a unique mktemp directory inside this path.
  --sign IDENTITY Code-sign with this identity, hardened runtime, and timestamp.
                  Default '-' creates a local ad-hoc signature.
  --configuration Build configuration (default: release). Use 'debug' for a
                  local build you intend to test and iterate on.

Builds a signed native-architecture app bundle (not universal).
Does not notarize, open, or launch the app.

Honors a pre-set DEVELOPER_DIR and SDKROOT. Setting SDKROOT selects that exact
SDK instead of the newest one; this is required when the toolchain that ships
the newest SDK cannot supply every macro plugin the sources need.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { echo "error: --output requires a path" >&2; exit 2; }
      OUTPUT_APP="$2"
      shift 2
      ;;
    --scratch)
      [[ $# -ge 2 ]] || { echo "error: --scratch requires a path" >&2; exit 2; }
      SCRATCH="$2"
      shift 2
      ;;
    --sign)
      [[ $# -ge 2 ]] || { echo "error: --sign requires an identity" >&2; exit 2; }
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --configuration)
      [[ $# -ge 2 ]] || { echo "error: --configuration requires debug or release" >&2; exit 2; }
      case "$2" in
        debug|release) CONFIGURATION="$2" ;;
        *) echo "error: --configuration must be 'debug' or 'release', got: $2" >&2; exit 2 ;;
      esac
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

if [[ "${OUTPUT_APP}" != /* ]]; then
  OUTPUT_APP="$(pwd)/${OUTPUT_APP}"
fi
OUTPUT_PARENT="$(dirname "${OUTPUT_APP}")"
OUTPUT_BASE="$(basename "${OUTPUT_APP}")"
if [[ -d "${OUTPUT_PARENT}" ]]; then
  OUTPUT_APP="$(cd "${OUTPUT_PARENT}" && pwd)/${OUTPUT_BASE}"
fi

if [[ -e "${OUTPUT_APP}" ]]; then
  echo "error: output already exists: ${OUTPUT_APP}" >&2
  echo "Choose another --output path; refusing to overwrite." >&2
  exit 1
fi

if [[ -z "${SCRATCH}" ]]; then
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-build.XXXXXX")"
  # TMPDIR normally ends in '/', so mktemp yields a doubled separator. The
  # linker records normalized paths, so leaving it unnormalized breaks any
  # prefix comparison against recorded rpaths.
  SCRATCH="$(cd "${SCRATCH}" && pwd)"
  OWNED_SCRATCH=1
else
  if [[ "${SCRATCH}" != /* ]]; then
    SCRATCH="$(pwd)/${SCRATCH}"
  fi
  mkdir -p "${SCRATCH}"
  SCRATCH="$(cd "${SCRATCH}" && pwd)"
  OWNED_SCRATCH=0
fi

# True only for directories this invocation created via mktemp with a known prefix.
is_owned_mktemp_dir() {
  local path="$1"
  local prefix="$2"
  [[ -n "${path}" && -d "${path}" ]] || return 1
  local base
  base="$(basename "${path}")"
  case "${base}" in
    ${prefix}*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  # Stage dir: always created with mktemp by this script; safe to remove when prefix matches.
  if is_owned_mktemp_dir "${STAGE_DIR:-}" "notchclip-stage."; then
    rm -rf "${STAGE_DIR}"
  fi
  STAGE_DIR=""

  # Install sibling: only remove if it still exists and matches our prefix.
  if is_owned_mktemp_dir "${INSTALL_TMP:-}" ".notchclip-install."; then
    rm -rf "${INSTALL_TMP}"
  fi
  INSTALL_TMP=""

  # Full scratch: only when we created it with mktemp for this invocation.
  if [[ "${OWNED_SCRATCH}" -eq 1 ]] && is_owned_mktemp_dir "${SCRATCH:-}" "notchclip-build."; then
    rm -rf "${SCRATCH}"
  fi
}
trap cleanup EXIT

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if ACTIVE_DEV="$(xcode-select -p 2>/dev/null)" && [[ -n "${ACTIVE_DEV}" && -d "${ACTIVE_DEV}" ]]; then
    export DEVELOPER_DIR="${ACTIVE_DEV}"
  fi
fi

# A pre-set SDKROOT names an exact SDK and must win. `xcrun --sdk macosx`
# re-resolves to the newest installed SDK and would silently override it.
if [[ -n "${SDKROOT:-}" ]]; then
  if [[ ! -d "${SDKROOT}" ]]; then
    echo "error: SDKROOT is set but not a directory: ${SDKROOT}" >&2
    exit 1
  fi
  SWIFT=(swift)
elif command -v xcrun >/dev/null 2>&1; then
  SWIFT=(xcrun --sdk macosx swift)
else
  SWIFT=(swift)
fi

PLIST_SRC="${REPO_ROOT}/Packaging/Info.plist"
if [[ ! -f "${PLIST_SRC}" ]]; then
  echo "error: missing bundle plist: ${PLIST_SRC}" >&2
  exit 1
fi

BUILD_DIR="${SCRATCH}/spm"
RESOURCES_SRC="${REPO_ROOT}/Packaging/Resources"
ICON_MASTER="${REPO_ROOT}/Packaging/Assets/AppIconMaster.png"

# Unique staging directory inside scratch — never rm -rf a fixed name under caller scratch.
STAGE_DIR="$(mktemp -d "${SCRATCH}/notchclip-stage.XXXXXX")"
STAGE_APP="${STAGE_DIR}/NotchClip.app"

echo "Building NotchClip (${CONFIGURATION}, native architecture)…"
echo "  repo:    ${REPO_ROOT}"
echo "  scratch: ${SCRATCH}"
echo "  stage:   ${STAGE_DIR}"
echo "  output:  ${OUTPUT_APP}"
echo "  signing: ${SIGNING_IDENTITY}"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "  DEVELOPER_DIR=${DEVELOPER_DIR}"
fi

"${SWIFT[@]}" build \
  --package-path "${REPO_ROOT}" \
  --configuration "${CONFIGURATION}" \
  --product NotchClip \
  --scratch-path "${BUILD_DIR}"

BIN=""
if SHOW_BIN="$("${SWIFT[@]}" build \
  --package-path "${REPO_ROOT}" \
  --configuration "${CONFIGURATION}" \
  --product NotchClip \
  --scratch-path "${BUILD_DIR}" \
  --show-bin-path 2>/dev/null)"; then
  if [[ -x "${SHOW_BIN}/NotchClip" ]]; then
    BIN="${SHOW_BIN}/NotchClip"
  fi
fi
if [[ -z "${BIN}" ]]; then
  while IFS= read -r -d '' candidate; do
    if [[ -x "${candidate}" && ! -d "${candidate}" ]]; then
      BIN="${candidate}"
      break
    fi
  done < <(find "${BUILD_DIR}" -type f -name NotchClip -print0 2>/dev/null | sort -z)
fi
if [[ -z "${BIN}" || ! -x "${BIN}" ]]; then
  echo "error: ${CONFIGURATION} executable NotchClip not found under ${BUILD_DIR}" >&2
  exit 1
fi

echo "  binary:  ${BIN}"

mkdir -p "${STAGE_APP}/Contents/MacOS"

cp "${PLIST_SRC}" "${STAGE_APP}/Contents/Info.plist"
cp "${BIN}" "${STAGE_APP}/Contents/MacOS/NotchClip"
chmod a+x "${STAGE_APP}/Contents/MacOS/NotchClip"

# A debug link adds an LC_RPATH into the SwiftPM scratch PackageFrameworks
# directory, which this script deletes on exit. Nothing resolves through it
# (library targets link statically here), but it leaves a dangling absolute
# build path inside a shipped binary and fails verify-app.sh. Release builds
# do not emit it. Strip any rpath pointing into scratch before signing, since
# signing must cover the final bytes.
while IFS= read -r RPATH; do
  [[ -n "${RPATH}" ]] || continue
  case "${RPATH}" in
    "${SCRATCH}"/*|"${BUILD_DIR}"/*)
      echo "  stripping scratch rpath: ${RPATH}"
      install_name_tool -delete_rpath "${RPATH}" "${STAGE_APP}/Contents/MacOS/NotchClip"
      ;;
  esac
done < <(otool -l "${STAGE_APP}/Contents/MacOS/NotchClip" \
  | awk '/LC_RPATH/{f=1} f&&/^ *path /{print $2; f=0}')

# Sparkle is a binary XCFramework dependency, so the app must carry the
# framework itself. The executable loads it as @rpath/Sparkle.framework/…, and
# none of the rpaths the linker recorded survive the strip above, so add the
# bundle-relative one here — before signing, which must cover the final bytes.
SPARKLE_FRAMEWORK=""
while IFS= read -r candidate; do
  SPARKLE_FRAMEWORK="${candidate}"
  break
done < <(find "${BUILD_DIR}/artifacts" -type d -name Sparkle.framework -path '*/Sparkle.xcframework/macos*' 2>/dev/null | sort)
if [[ -z "${SPARKLE_FRAMEWORK}" ]]; then
  echo "error: Sparkle.framework not found under ${BUILD_DIR}/artifacts" >&2
  echo "The Sparkle binary artifact did not resolve; re-run 'swift package resolve'." >&2
  exit 1
fi

mkdir -p "${STAGE_APP}/Contents/Frameworks"
# ditto (not cp -R) so the framework's version symlinks survive; codesign
# rejects a versioned bundle whose Versions/Current link was flattened.
ditto "${SPARKLE_FRAMEWORK}" "${STAGE_APP}/Contents/Frameworks/Sparkle.framework"
echo "  sparkle: ${SPARKLE_FRAMEWORK}"

if ! otool -l "${STAGE_APP}/Contents/MacOS/NotchClip" \
  | awk '/LC_RPATH/{f=1} f&&/^ *path /{print $2; f=0}' \
  | grep -qx '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "${STAGE_APP}/Contents/MacOS/NotchClip"
fi

if [[ -d "${RESOURCES_SRC}" ]] && [[ -n "$(find "${RESOURCES_SRC}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  mkdir -p "${STAGE_APP}/Contents/Resources"
  cp -R "${RESOURCES_SRC}/." "${STAGE_APP}/Contents/Resources/"
fi

if [[ ! -f "${ICON_MASTER}" ]]; then
  echo "error: missing app icon master: ${ICON_MASTER}" >&2
  exit 1
fi
if ! command -v sips >/dev/null 2>&1 || ! command -v iconutil >/dev/null 2>&1; then
  echo "error: sips and iconutil are required to build AppIcon.icns" >&2
  exit 1
fi
ICONSET="${STAGE_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET}" "${STAGE_APP}/Contents/Resources"
sips -z 16 16 "${ICON_MASTER}" --out "${ICONSET}/icon_16x16.png" >/dev/null
sips -z 32 32 "${ICON_MASTER}" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${ICON_MASTER}" --out "${ICONSET}/icon_32x32.png" >/dev/null
sips -z 64 64 "${ICON_MASTER}" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${ICON_MASTER}" --out "${ICONSET}/icon_128x128.png" >/dev/null
sips -z 256 256 "${ICON_MASTER}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${ICON_MASTER}" --out "${ICONSET}/icon_256x256.png" >/dev/null
sips -z 512 512 "${ICON_MASTER}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${ICON_MASTER}" --out "${ICONSET}/icon_512x512.png" >/dev/null
cp "${ICON_MASTER}" "${ICONSET}/icon_512x512@2x.png"
iconutil -c icns "${ICONSET}" -o "${STAGE_APP}/Contents/Resources/AppIcon.icns"

if [[ ! -f "${STAGE_APP}/Contents/Info.plist" ]]; then
  echo "error: staged Info.plist missing" >&2
  exit 1
fi
if [[ ! -x "${STAGE_APP}/Contents/MacOS/NotchClip" ]]; then
  echo "error: staged executable missing or not executable" >&2
  exit 1
fi
if ! plutil -lint "${STAGE_APP}/Contents/Info.plist" >/dev/null; then
  echo "error: staged Info.plist failed plutil -lint" >&2
  exit 1
fi

# Finder/File Provider can attach empty FinderInfo or resource-fork attributes
# to bundles in Documents. Code signing rejects those attributes even though
# they are not app content, so remove only those two known detritus classes.
if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.FinderInfo "${STAGE_APP}" 2>/dev/null || true
  xattr -dr com.apple.ResourceFork "${STAGE_APP}" 2>/dev/null || true
fi

# Sign the completed bundle so Info.plist and all staged contents are covered.
if ! command -v codesign >/dev/null 2>&1; then
  echo "error: codesign is required to create a runnable macOS app" >&2
  exit 1
fi
# Sparkle's nested code (two XPC services, the Autoupdate tool, and Updater.app)
# each carry their own signature and must be re-signed inside-out with this
# app's identity before the outer bundle is sealed. Order and the Downloader's
# preserved entitlements follow Sparkle's official code-signing instructions.
SPARKLE_VERSION_DIR="${STAGE_APP}/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ ! -d "${SPARKLE_VERSION_DIR}" ]]; then
  echo "error: staged Sparkle.framework has no Versions/B; refusing to sign" >&2
  exit 1
fi

sign_sparkle_components() {
  # Every argument is passed through to codesign for each nested component.
  local downloader="${SPARKLE_VERSION_DIR}/XPCServices/Downloader.xpc"
  if [[ -e "${downloader}" ]]; then
    # Ships pre-entitled for sandboxed hosts; re-signing without this would
    # drop the entitlements it needs.
    codesign --force --sign "${SIGNING_IDENTITY}" "$@" \
      --preserve-metadata=entitlements "${downloader}"
  fi
  local component
  for component in \
    "${SPARKLE_VERSION_DIR}/XPCServices/Installer.xpc" \
    "${SPARKLE_VERSION_DIR}/Updater.app" \
    "${SPARKLE_VERSION_DIR}/Autoupdate" \
    "${STAGE_APP}/Contents/Frameworks/Sparkle.framework"
  do
    [[ -e "${component}" ]] || continue
    codesign --force --sign "${SIGNING_IDENTITY}" "$@" "${component}"
  done
}

if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  sign_sparkle_components
  codesign --force --sign - "${STAGE_APP}"
elif [[ "${SIGNING_IDENTITY}" == Developer\ ID* ]]; then
  # Distribution path: hardened runtime + secure timestamp for notarization.
  sign_sparkle_components --options runtime --timestamp
  codesign \
    --force \
    --sign "${SIGNING_IDENTITY}" \
    --options runtime \
    --timestamp \
    "${STAGE_APP}"
else
  # Local named identity (e.g. a self-signed "NotchClip Local Dev" cert).
  # Unlike ad-hoc, this keeps the designated requirement stable across
  # rebuilds, so TCC grants (Accessibility) survive. No hardened runtime or
  # network timestamp needed for a local build.
  sign_sparkle_components
  codesign --force --sign "${SIGNING_IDENTITY}" "${STAGE_APP}"
fi
if ! codesign --verify --deep --strict --verbose=2 "${STAGE_APP}"; then
  echo "error: staged app failed strict code-signature verification" >&2
  exit 1
fi

if [[ -e "${OUTPUT_APP}" ]]; then
  echo "error: output already exists: ${OUTPUT_APP}" >&2
  echo "Choose another --output path; refusing to overwrite." >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_APP}")"

INSTALL_PARENT="$(dirname "${OUTPUT_APP}")"
INSTALL_TMP="$(mktemp -d "${INSTALL_PARENT}/.notchclip-install.XXXXXX")"

cp -R "${STAGE_APP}" "${INSTALL_TMP}/NotchClip.app"

if [[ -e "${OUTPUT_APP}" ]]; then
  echo "error: output already exists: ${OUTPUT_APP}" >&2
  echo "Choose another --output path; refusing to overwrite." >&2
  exit 1
fi

# Rename into place (atomic on the same volume).
mv "${INSTALL_TMP}/NotchClip.app" "${OUTPUT_APP}"
rmdir "${INSTALL_TMP}" 2>/dev/null || true
if [[ -d "${INSTALL_TMP}" ]] && is_owned_mktemp_dir "${INSTALL_TMP}" ".notchclip-install."; then
  rm -rf "${INSTALL_TMP}"
fi
INSTALL_TMP=""

# The destination itself may be File Provider-backed and attach FinderInfo a
# moment after the bundle lands. Give it a short settling window, then strip
# only the two attributes that code signing explicitly rejects.
DELIVERED_SIGNATURE_VALID=0
for _ in 1 2 3 4 5; do
  sleep 0.1
  DELIVERED_SIGNATURE_VALID=0
  if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.FinderInfo "${OUTPUT_APP}" 2>/dev/null || true
    xattr -dr com.apple.ResourceFork "${OUTPUT_APP}" 2>/dev/null || true
  fi
  if codesign --verify --deep --strict --verbose=2 "${OUTPUT_APP}"; then
    DELIVERED_SIGNATURE_VALID=1
  fi
done
if [[ "${DELIVERED_SIGNATURE_VALID}" -ne 1 ]]; then
  echo "error: delivered app failed strict code-signature verification" >&2
  exit 1
fi

echo "Built signed native-architecture app:"
echo "  ${OUTPUT_APP}"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  echo "Signature: local ad-hoc (not Developer ID or notarized)."
else
  echo "Signature: ${SIGNING_IDENTITY} (hardened runtime + secure timestamp)."
  echo "This app is signed but not yet notarized."
fi
echo "This bundle is not universal."
