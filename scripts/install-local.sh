#!/usr/bin/env bash
# Transactionally replace the local /Applications copy while preserving a backup.
set -euo pipefail

SOURCE_APP=""
TARGET_APP="/Applications/NotchClip.app"
BACKUP_APP="/Applications/NotchClip.previous.app"
SHOULD_LAUNCH=0
STAGING_APP="/Applications/.NotchClip.installing.app"
MOVED_OLD=0

usage() {
  cat <<'EOF'
Usage: scripts/install-local.sh --app PATH [--target PATH] [--backup PATH] [--launch]

Verifies the source, asks the running NotchClip process to terminate, stages and
verifies the replacement, atomically swaps it into place, and keeps the previous
copy at --backup. Existing target, backup, or staging paths are never overwritten.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "error: --app requires a path" >&2; exit 2; }
      SOURCE_APP="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || { echo "error: --target requires a path" >&2; exit 2; }
      TARGET_APP="$2"
      shift 2
      ;;
    --backup)
      [[ $# -ge 2 ]] || { echo "error: --backup requires a path" >&2; exit 2; }
      BACKUP_APP="$2"
      shift 2
      ;;
    --launch)
      SHOULD_LAUNCH=1
      shift
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

[[ -n "${SOURCE_APP}" && -d "${SOURCE_APP}" ]] || { usage >&2; exit 2; }
[[ "${TARGET_APP}" == *.app && "${BACKUP_APP}" == *.app ]] || {
  echo "error: target and backup must be explicit .app paths" >&2
  exit 2
}
STAGING_APP="$(dirname "${TARGET_APP}")/.NotchClip.installing.app"
[[ ! -e "${STAGING_APP}" ]] || { echo "error: staging path already exists: ${STAGING_APP}" >&2; exit 1; }
if [[ -e "${TARGET_APP}" && -e "${BACKUP_APP}" ]]; then
  echo "error: backup already exists: ${BACKUP_APP}" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "${SOURCE_APP}"

cleanup() {
  if [[ -d "${STAGING_APP}" ]]; then
    rm -rf "${STAGING_APP}"
  fi
  if [[ "${MOVED_OLD}" -eq 1 && ! -e "${TARGET_APP}" && -e "${BACKUP_APP}" ]]; then
    mv "${BACKUP_APP}" "${TARGET_APP}"
    MOVED_OLD=0
  fi
}
trap cleanup EXIT

pkill -TERM -x NotchClip 2>/dev/null || true
for _ in {1..30}; do
  if ! pgrep -x NotchClip >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if pgrep -x NotchClip >/dev/null 2>&1; then
  echo "error: NotchClip did not terminate; leaving the installed app untouched" >&2
  exit 1
fi

ditto --noqtn "${SOURCE_APP}" "${STAGING_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGING_APP}"

if [[ -e "${TARGET_APP}" ]]; then
  mv "${TARGET_APP}" "${BACKUP_APP}"
  MOVED_OLD=1
fi
mv "${STAGING_APP}" "${TARGET_APP}"
codesign --verify --deep --strict --verbose=2 "${TARGET_APP}"
MOVED_OLD=0

echo "Installed: ${TARGET_APP}"
if [[ -e "${BACKUP_APP}" ]]; then
  echo "Previous copy preserved at: ${BACKUP_APP}"
fi

if [[ "${SHOULD_LAUNCH}" -eq 1 ]]; then
  open "${TARGET_APP}"
fi
