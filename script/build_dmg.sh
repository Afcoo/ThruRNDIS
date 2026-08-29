#!/usr/bin/env bash

# Requirements for ./script/build_dmg.sh:
# - One notarized ThruRNDIS.app produced by notarize_app.sh.
# - macOS hdiutil and the Xcode resource tools SetFile and GetFileInfo.
# - Permission for the invoking terminal to automate Finder. Finder writes and
#   verifies the compact 480x300 DMG window layout, fixed icon positions, and
#   96 px icon size.
# - A Developer ID Application certificate, including its private key, matching
#   the app signing team. Only the DMG is signed; the notarized app is never
#   signed or otherwise modified by this script.
#
# The mounted volume icon is derived from the exact CFBundleIconFile .icns
# inside the input app. The .dmg file itself uses the standard macOS disk-image
# icon so raw GitHub Release downloads do not depend on Finder metadata. This
# script builds and signs the DMG but does not submit or staple it. Pass
# --output to choose the DMG path used by package_app.sh or a manual workflow;
# otherwise it writes the DMG in the current working directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/support/distribution_common.sh
source "$SCRIPT_DIR/support/distribution_common.sh"
# shellcheck source=script/support/distribution_io.sh
source "$SCRIPT_DIR/support/distribution_io.sh"

APP_NAME="ThruRNDIS"
DMG_ICON_SIZE=96
# The extra vertical allowance includes the Finder labels below each icon.
DMG_WINDOW_WIDTH=480
DMG_WINDOW_HEIGHT=300
DMG_APP_ICON_X=120
DMG_APP_ICON_Y=108
DMG_APPLICATIONS_ICON_X=360
DMG_APPLICATIONS_ICON_Y=108
DMG_FREE_SPACE_MIB=32

DMG_LAYOUT_SCRIPT="$SCRIPT_DIR/support/configure_dmg_layout.applescript"

WORK_DIR=""
OUTPUT_STAGING_DIR=""
OUTPUT_PARENT=""
DMG_LAYOUT_DEVICE=""
DMG_VERIFY_DEVICE=""
DMG_LAYOUT_MOUNT_DIR=""
DMG_VERIFY_MOUNT_DIR=""
OUTPUT_DMG=""
INPUT_APP=""

usage() {
  echo "usage: $0 [--output DMG_PATH] NOTARIZED_APP" >&2
}

cleanup() {
  if [[ -n "$DMG_VERIFY_DEVICE" ]]; then
    distribution_detach_disk_image "$DMG_VERIFY_DEVICE" >/dev/null 2>&1 || true
    DMG_VERIFY_DEVICE=""
  fi
  if [[ -n "$DMG_LAYOUT_DEVICE" ]]; then
    distribution_detach_disk_image "$DMG_LAYOUT_DEVICE" >/dev/null 2>&1 || true
    DMG_LAYOUT_DEVICE=""
  fi

  # An error can occur after hdiutil attaches an image but before its device is
  # stored above. Detaching the private mount paths as a fallback prevents the
  # temporary work directory from remaining busy.
  if [[ -n "$DMG_VERIFY_MOUNT_DIR" ]]; then
    /usr/bin/hdiutil detach "$DMG_VERIFY_MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$DMG_LAYOUT_MOUNT_DIR" ]]; then
    /usr/bin/hdiutil detach "$DMG_LAYOUT_MOUNT_DIR" >/dev/null 2>&1 || true
  fi

  if [[ -n "$OUTPUT_STAGING_DIR" && -n "$OUTPUT_PARENT" ]]; then
    case "$OUTPUT_STAGING_DIR" in
      "$OUTPUT_PARENT"/.ThruRNDIS-dmg-build.*)
        /bin/rm -rf "$OUTPUT_STAGING_DIR"
        ;;
    esac
  fi

  if [[ -n "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      /tmp/ThruRNDIS-dmg-build.*|/private/tmp/ThruRNDIS-dmg-build.*)
        /bin/rm -rf "$WORK_DIR"
        ;;
    esac
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || {
        usage
        exit 2
      }
      OUTPUT_DMG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      [[ -z "$INPUT_APP" ]] || {
        usage
        exit 2
      }
      INPUT_APP="$1"
      shift
      ;;
  esac
done
if [[ $# -gt 0 ]]; then
  [[ -z "$INPUT_APP" && $# -eq 1 ]] || {
    usage
    exit 2
  }
  INPUT_APP="$1"
fi
[[ -n "$INPUT_APP" ]] || {
  usage
  exit 2
}

[[ -d "$INPUT_APP" ]] || distribution_fail "notarized app not found at $INPUT_APP"
INPUT_APP="$(cd "$INPUT_APP" && /bin/pwd -P)"
[[ "$(/usr/bin/basename "$INPUT_APP")" == "$APP_NAME.app" ]] || distribution_fail \
  "expected the notarized app bundle to be named $APP_NAME.app"
[[ -f "$DMG_LAYOUT_SCRIPT" ]] || distribution_fail \
  "DMG layout script not found at $DMG_LAYOUT_SCRIPT"

SETFILE_BIN="$(/usr/bin/xcrun --find SetFile)"
GETFILEINFO_BIN="$(/usr/bin/xcrun --find GetFileInfo)"
[[ -x "$SETFILE_BIN" && -x "$GETFILEINFO_BIN" ]] || distribution_fail \
  "Xcode resource tools SetFile and GetFileInfo are required"

APP_VERSION="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$INPUT_APP/Contents/Info.plist")"

distribution_require_safe_filename_component "app version" "$APP_VERSION"

DMG_NAME="$APP_NAME-$APP_VERSION.dmg"
VOLUME_NAME="$APP_NAME $APP_VERSION"
if [[ -z "$OUTPUT_DMG" ]]; then
  OUTPUT_DMG="$PWD/$DMG_NAME"
fi
OUTPUT_DMG="$(distribution_resolve_new_output_path \
  "$OUTPUT_DMG" "$DMG_NAME" "DMG output")"
case "$OUTPUT_DMG" in
  "$INPUT_APP"|"$INPUT_APP"/*)
    distribution_fail "DMG output cannot be inside the input app: $OUTPUT_DMG"
    ;;
esac
OUTPUT_PARENT="$(/usr/bin/dirname "$OUTPUT_DMG")"
OUTPUT_STAGING_DIR="$(/usr/bin/mktemp -d \
  "$OUTPUT_PARENT/.ThruRNDIS-dmg-build.XXXXXX")"
STAGED_DMG="$OUTPUT_STAGING_DIR/$DMG_NAME"

WORK_DIR="$(/usr/bin/mktemp -d /tmp/ThruRNDIS-dmg-build.XXXXXX)"
INPUT_INITIAL_FINGERPRINT="$WORK_DIR/input-app-initial-fingerprint.mtree"
INPUT_FINAL_FINGERPRINT="$WORK_DIR/input-app-final-fingerprint.mtree"

echo "Validating the notarized app before DMG creation..."
distribution_validate_notarized_app \
  "$INPUT_APP" "$WORK_DIR/input-signing"
DEVELOPMENT_TEAM="$(distribution_team_identifier "$INPUT_APP")"
distribution_write_app_fingerprint "$INPUT_APP" "$INPUT_INITIAL_FINGERPRINT"

APP_SIGNING_AUTHORITY="$(distribution_leaf_signing_authority "$INPUT_APP")"
DMG_SIGNING_IDENTITY_SHA1="$(distribution_resolve_dmg_signing_identity \
  "$INPUT_APP" \
  "$APP_SIGNING_AUTHORITY" \
  "$DEVELOPMENT_TEAM" \
  "$WORK_DIR/input-app-signing-certificate-")"
DMG_SOURCE_DIR="$WORK_DIR/dmg-source"
DMG_SOURCE_APP="$DMG_SOURCE_DIR/$APP_NAME.app"
WRITABLE_DMG="$WORK_DIR/$APP_NAME-writable.dmg"
DMG_LAYOUT_MOUNT_DIR="$WORK_DIR/dmg-layout-mount"
DMG_VERIFY_MOUNT_DIR="$WORK_DIR/dmg-verify-mount"
APP_ICON="$(distribution_resolve_app_icon "$INPUT_APP")"
APP_ICON_SHA256="$(distribution_sha256 "$APP_ICON")"

/bin/mkdir -p \
  "$DMG_SOURCE_DIR" \
  "$DMG_LAYOUT_MOUNT_DIR" \
  "$DMG_VERIFY_MOUNT_DIR"
/usr/bin/ditto "$INPUT_APP" "$DMG_SOURCE_APP"
/bin/ln -s /Applications "$DMG_SOURCE_DIR/Applications"
distribution_compare_app_contents \
  "$INPUT_APP" "$DMG_SOURCE_APP" "$WORK_DIR/source-copy-validation"
distribution_validate_app \
  "$DMG_SOURCE_APP" \
  "$WORK_DIR/source-copy-signing" \
  "$DEVELOPMENT_TEAM"

echo "Creating the writable $DMG_NAME with hdiutil..."
/usr/bin/hdiutil create \
  -ov \
  -srcfolder "$DMG_SOURCE_DIR" \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -fsargs '-c c=64,a=16,e=16' \
  -format UDRW \
  -nospotlight \
  "$WRITABLE_DMG"
RESIZE_LIMITS="$(/usr/bin/hdiutil resize -limits "$WRITABLE_DMG")"
CURRENT_IMAGE_SECTORS="$(/usr/bin/printf '%s\n' "$RESIZE_LIMITS" | \
  /usr/bin/awk 'NR == 1 { print $2 }')"
MAX_IMAGE_SECTORS="$(/usr/bin/printf '%s\n' "$RESIZE_LIMITS" | \
  /usr/bin/awk 'NR == 1 { print $3 }')"
[[ "$CURRENT_IMAGE_SECTORS" =~ ^[0-9]+$ && "$MAX_IMAGE_SECTORS" =~ ^[0-9]+$ ]] || distribution_fail \
  "could not parse hdiutil resize limits: $RESIZE_LIMITS"
TARGET_IMAGE_SECTORS="$(( CURRENT_IMAGE_SECTORS + DMG_FREE_SPACE_MIB * 2048 ))"
[[ "$TARGET_IMAGE_SECTORS" -le "$MAX_IMAGE_SECTORS" ]] || distribution_fail \
  "hdiutil cannot add ${DMG_FREE_SPACE_MIB} MiB of Finder metadata space"
/usr/bin/hdiutil resize -sectors "$TARGET_IMAGE_SECTORS" "$WRITABLE_DMG"

verify_mounted_dmg() {
  local mount_path="$1"
  local validation_dir="$2"
  local mounted_app="$mount_path/$APP_NAME.app"
  local actual_icon_size

  [[ -d "$mounted_app" ]] || distribution_fail \
    "mounted DMG does not contain $APP_NAME.app"
  [[ -L "$mount_path/Applications" ]] || distribution_fail \
    "mounted DMG does not contain the Applications symlink"
  [[ "$(/usr/bin/readlink "$mount_path/Applications")" == "/Applications" ]] || distribution_fail \
    "mounted DMG Applications link does not target /Applications"
  [[ -f "$mount_path/.VolumeIcon.icns" ]] || distribution_fail \
    "mounted DMG does not contain .VolumeIcon.icns"
  [[ "$(distribution_sha256 "$mount_path/.VolumeIcon.icns")" == "$APP_ICON_SHA256" ]] || distribution_fail \
    "mounted DMG volume icon does not match the built app icon"
  [[ "$("$GETFILEINFO_BIN" -a "$mount_path")" == *C* ]] || distribution_fail \
    "mounted DMG custom volume-icon flag is missing"
  [[ -f "$mount_path/.DS_Store" ]] || distribution_fail \
    "mounted DMG does not contain the Finder layout"

  actual_icon_size="$(/usr/bin/osascript \
    "$DMG_LAYOUT_SCRIPT" \
    "$mount_path" \
    "$APP_NAME.app" \
    "$DMG_ICON_SIZE" \
    "$DMG_WINDOW_WIDTH" \
    "$DMG_WINDOW_HEIGHT" \
    "$DMG_APP_ICON_X" \
    "$DMG_APP_ICON_Y" \
    "$DMG_APPLICATIONS_ICON_X" \
    "$DMG_APPLICATIONS_ICON_Y" \
    verify)"
  [[ "$actual_icon_size" == "$DMG_ICON_SIZE" ]] || distribution_fail \
    "Finder read DMG icon size $actual_icon_size instead of $DMG_ICON_SIZE"

  distribution_compare_app_contents \
    "$INPUT_APP" "$mounted_app" "$validation_dir/content-comparison"
  distribution_validate_app \
    "$mounted_app" \
    "$validation_dir/signing" \
    "$DEVELOPMENT_TEAM"
}

echo "Applying the app icon and persisted Finder layout..."
distribution_attach_disk_image \
  -readwrite "$WRITABLE_DMG" "$DMG_LAYOUT_MOUNT_DIR" DMG_LAYOUT_DEVICE
/usr/bin/ditto "$APP_ICON" "$DMG_LAYOUT_MOUNT_DIR/.VolumeIcon.icns"
"$SETFILE_BIN" -c icnC "$DMG_LAYOUT_MOUNT_DIR/.VolumeIcon.icns"
[[ "$(distribution_sha256 "$DMG_LAYOUT_MOUNT_DIR/.VolumeIcon.icns")" == "$APP_ICON_SHA256" ]] || distribution_fail \
  "writable DMG volume icon does not match the built app icon"

ACTUAL_DMG_ICON_SIZE="$(/usr/bin/osascript \
  "$DMG_LAYOUT_SCRIPT" \
  "$DMG_LAYOUT_MOUNT_DIR" \
  "$APP_NAME.app" \
  "$DMG_ICON_SIZE" \
  "$DMG_WINDOW_WIDTH" \
  "$DMG_WINDOW_HEIGHT" \
  "$DMG_APP_ICON_X" \
  "$DMG_APP_ICON_Y" \
  "$DMG_APPLICATIONS_ICON_X" \
  "$DMG_APPLICATIONS_ICON_Y" \
  configure)"
[[ "$ACTUAL_DMG_ICON_SIZE" == "$DMG_ICON_SIZE" ]] || distribution_fail \
  "Finder saved DMG icon size $ACTUAL_DMG_ICON_SIZE instead of $DMG_ICON_SIZE"
"$SETFILE_BIN" -a V "$DMG_LAYOUT_MOUNT_DIR/.VolumeIcon.icns"
"$SETFILE_BIN" -a C "$DMG_LAYOUT_MOUNT_DIR"
verify_mounted_dmg "$DMG_LAYOUT_MOUNT_DIR" "$WORK_DIR/writable-volume-validation"

/bin/sync
distribution_detach_disk_image "$DMG_LAYOUT_DEVICE" || distribution_fail \
  "could not detach writable DMG device $DMG_LAYOUT_DEVICE"
DMG_LAYOUT_DEVICE=""

echo "Compressing and verifying $DMG_NAME..."
/usr/bin/hdiutil convert \
  "$WRITABLE_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$STAGED_DMG"
[[ -f "$STAGED_DMG" ]] || distribution_fail \
  "hdiutil did not produce $STAGED_DMG"
/usr/bin/hdiutil verify "$STAGED_DMG"

distribution_attach_disk_image \
  -readonly "$STAGED_DMG" "$DMG_VERIFY_MOUNT_DIR" DMG_VERIFY_DEVICE
verify_mounted_dmg "$DMG_VERIFY_MOUNT_DIR" "$WORK_DIR/compressed-volume-validation"
distribution_detach_disk_image "$DMG_VERIFY_DEVICE" || distribution_fail \
  "could not detach compressed DMG device $DMG_VERIFY_DEVICE"
DMG_VERIFY_DEVICE=""

echo "Signing $DMG_NAME without modifying the notarized app..."
/usr/bin/codesign --force --sign "$DMG_SIGNING_IDENTITY_SHA1" --timestamp "$STAGED_DMG"
distribution_validate_dmg_signature "$STAGED_DMG" "$DEVELOPMENT_TEAM"

distribution_write_app_fingerprint "$INPUT_APP" "$INPUT_FINAL_FINGERPRINT"
/usr/bin/cmp -s "$INPUT_INITIAL_FINGERPRINT" "$INPUT_FINAL_FINGERPRINT" || distribution_fail \
  "the input app changed during DMG creation"

[[ ! -e "$OUTPUT_DMG" && ! -L "$OUTPUT_DMG" ]] || distribution_fail \
  "DMG output appeared while this build was running: $OUTPUT_DMG"
/bin/mv "$STAGED_DMG" "$OUTPUT_DMG"
/bin/rmdir "$OUTPUT_STAGING_DIR"
OUTPUT_STAGING_DIR=""

echo "Signed DMG build: $OUTPUT_DMG"
echo "Preserved notarized app: $INPUT_APP"
echo "Next: $SCRIPT_DIR/notarize_dmg.sh \"$OUTPUT_DMG\""
