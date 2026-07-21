#!/usr/bin/env bash

# Verifies an existing ThruRNDIS distribution DMG without signing or modifying
# its contents. The image is mounted read-only while the embedded app, Network
# System Extension, volume icon, and Applications symlink are validated.
#
# Run this from a normal macOS terminal session. Restricted sandboxes can block
# the system trust services used by codesign, stapler, spctl, and
# syspolicy_check and can therefore report false signature or Gatekeeper
# failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/distribution_common.sh
source "$SCRIPT_DIR/distribution_common.sh"

APP_NAME="ThruRNDIS"
APP_VERIFICATION_SCRIPT="$SCRIPT_DIR/verify_notarized_app.sh"
INPUT_DMG=""
MOUNT_DEVICE=""
MOUNT_DIR=""
WORK_DIR=""

usage() {
  echo "usage: $0 NOTARIZED_DMG" >&2
}

detach_image() {
  local device="$1"
  local attempt

  for attempt in 1 2 3; do
    if /usr/bin/hdiutil detach "$device" >/dev/null; then
      return 0
    fi
    /bin/sleep 1
  done
  return 1
}

cleanup() {
  if [[ -n "$MOUNT_DEVICE" ]]; then
    detach_image "$MOUNT_DEVICE" >/dev/null 2>&1 || true
    MOUNT_DEVICE=""
  elif [[ -n "$MOUNT_DIR" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi

  if [[ -n "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      /tmp/ThruRNDIS-dmg-verification.*|/private/tmp/ThruRNDIS-dmg-verification.*)
        /bin/rm -rf "$WORK_DIR"
        ;;
    esac
  fi
}

trap cleanup EXIT

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

INPUT_DMG="$1"
[[ -f "$INPUT_DMG" ]] || distribution_fail "DMG not found at $INPUT_DMG"
[[ -x "$APP_VERIFICATION_SCRIPT" ]] || distribution_fail \
  "app verification script is missing or not executable: $APP_VERIFICATION_SCRIPT"
DMG_PARENT="$(/usr/bin/dirname "$INPUT_DMG")"
DMG_NAME="$(/usr/bin/basename "$INPUT_DMG")"
DMG_PARENT="$(cd "$DMG_PARENT" && /bin/pwd -P)"
INPUT_DMG="$DMG_PARENT/$DMG_NAME"
[[ "$DMG_NAME" == "$APP_NAME-"*.dmg ]] || distribution_fail \
  "expected a $APP_NAME-<version>-<build>.dmg file"

WORK_DIR="$(/usr/bin/mktemp -d /tmp/ThruRNDIS-dmg-verification.XXXXXX)"
MOUNT_DIR="$WORK_DIR/mount"
/bin/mkdir "$MOUNT_DIR"

echo "Validating disk image checksum for $INPUT_DMG..."
/usr/bin/hdiutil verify "$INPUT_DMG"

DMG_TEAM="$(distribution_team_identifier "$INPUT_DMG")"
[[ -n "$DMG_TEAM" && "$DMG_TEAM" != "not set" ]] || distribution_fail \
  "the DMG has no signing team"

echo "Validating DMG Developer ID signature and secure timestamp..."
distribution_validate_dmg_signature "$INPUT_DMG" "$DMG_TEAM"

echo "Validating the stapled DMG notarization ticket..."
/usr/bin/xcrun stapler validate -v "$INPUT_DMG"

echo "Requesting the Gatekeeper open assessment..."
/usr/sbin/spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$INPUT_DMG"

echo "Mounting the DMG read-only and validating its contents..."
ATTACH_OUTPUT="$(/usr/bin/hdiutil attach \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "$MOUNT_DIR" \
  "$INPUT_DMG")"
MOUNT_DEVICE="$(/usr/bin/printf '%s\n' "$ATTACH_OUTPUT" | /usr/bin/awk '
  /^\/dev\// && !device { device = $1 }
  END { print device }
')"
[[ "$MOUNT_DEVICE" == /dev/disk* ]] || distribution_fail \
  "could not determine the mounted device for $INPUT_DMG"

shopt -s nullglob
MOUNTED_APPS=("$MOUNT_DIR"/*.app)
shopt -u nullglob
[[ "${#MOUNTED_APPS[@]}" -eq 1 ]] || distribution_fail \
  "expected exactly one top-level app in the DMG"
MOUNTED_APP="${MOUNTED_APPS[0]}"
[[ "$(/usr/bin/basename "$MOUNTED_APP")" == "$APP_NAME.app" ]] || distribution_fail \
  "expected the mounted app to be named $APP_NAME.app"
[[ -L "$MOUNT_DIR/Applications" ]] || distribution_fail \
  "the DMG does not contain the Applications symlink"
[[ "$(/usr/bin/readlink "$MOUNT_DIR/Applications")" == "/Applications" ]] || distribution_fail \
  "the DMG Applications link does not target /Applications"
[[ -f "$MOUNT_DIR/.DS_Store" ]] || distribution_fail \
  "the DMG does not contain its Finder layout"
[[ -f "$MOUNT_DIR/.VolumeIcon.icns" ]] || distribution_fail \
  "the DMG does not contain its custom volume icon"

APP_ICON="$(distribution_resolve_app_icon "$MOUNTED_APP")"
[[ "$(distribution_sha256 "$MOUNT_DIR/.VolumeIcon.icns")" == \
   "$(distribution_sha256 "$APP_ICON")" ]] || distribution_fail \
  "the DMG volume icon does not match the embedded app icon"

GETFILEINFO_BIN="$(/usr/bin/xcrun --find GetFileInfo)"
[[ -x "$GETFILEINFO_BIN" ]] || distribution_fail \
  "Xcode resource tool GetFileInfo is required"
[[ "$("$GETFILEINFO_BIN" -a "$MOUNT_DIR")" == *C* ]] || distribution_fail \
  "the DMG custom volume-icon flag is missing"

"$APP_VERIFICATION_SCRIPT" "$MOUNTED_APP"
MOUNTED_APP_TEAM="$(distribution_team_identifier "$MOUNTED_APP")"
[[ "$MOUNTED_APP_TEAM" == "$DMG_TEAM" ]] || distribution_fail \
  "the DMG and embedded app use different signing teams"

detach_image "$MOUNT_DEVICE" || distribution_fail \
  "could not detach mounted DMG device $MOUNT_DEVICE"
MOUNT_DEVICE=""
MOUNT_DIR=""

DMG_SHA256="$(distribution_sha256 "$INPUT_DMG")"
echo "Verified notarized DMG: $INPUT_DMG"
echo "Developer ID team: $DMG_TEAM"
echo "SHA-256: $DMG_SHA256"
