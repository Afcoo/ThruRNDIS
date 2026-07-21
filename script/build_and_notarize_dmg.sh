#!/usr/bin/env bash

# Requirements for ./script/build_and_notarize_dmg.sh:
# - One notarized ThruRNDIS.app produced by build_and_notarize_app.sh. Its
#   sibling artifact-info.plist, app-contents.sha256, and app-fingerprint.mtree
#   files must still match the app.
# - macOS hdiutil and the Xcode resource tools SetFile and GetFileInfo.
# - Permission for the invoking terminal to automate Finder. Finder writes and
#   verifies the compact 480x300 DMG window layout, fixed icon positions, and
#   96 px icon size.
# - A Developer ID Application certificate, including its private key, matching
#   the app signing team. Only the DMG is signed; the notarized app is never
#   signed or otherwise modified by this script.
# - Apple notary credentials stored in the Keychain profile `thrurndis-notary`:
#     xcrun notarytool store-credentials "thrurndis-notary"
#   Set THRURNDIS_NOTARY_KEYCHAIN_PROFILE to use a different profile.
# - Internet access for Apple notarization.
#
# The mounted volume icon is derived from the exact CFBundleIconFile .icns
# inside the input app. The .dmg file itself uses the standard macOS disk-image
# icon so raw GitHub Release downloads do not depend on Finder metadata. Pass
# --skip-verification to skip the standalone post-notarization checks while
# still signing, submitting, stapling, and publishing the DMG.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=script/distribution_common.sh
source "$SCRIPT_DIR/distribution_common.sh"

APP_NAME="ThruRNDIS"
DEFAULT_NOTARY_KEYCHAIN_PROFILE="thrurndis-notary"
DMG_ICON_SIZE=96
# The extra vertical allowance includes the Finder labels below each icon.
DMG_WINDOW_WIDTH=480
DMG_WINDOW_HEIGHT=300
DMG_APP_ICON_X=120
DMG_APP_ICON_Y=108
DMG_APPLICATIONS_ICON_X=360
DMG_APPLICATIONS_ICON_Y=108
DMG_FREE_SPACE_MIB=32

OUTPUT_DIR="${THRURNDIS_DISTRIBUTION_OUTPUT_DIR:-$ROOT_DIR/dist}"
NOTARY_KEYCHAIN_PROFILE="${THRURNDIS_NOTARY_KEYCHAIN_PROFILE:-$DEFAULT_NOTARY_KEYCHAIN_PROFILE}"
DMG_LAYOUT_SCRIPT="$SCRIPT_DIR/configure_dmg_layout.applescript"
APP_VERIFICATION_SCRIPT="$SCRIPT_DIR/verify_notarized_app.sh"
DMG_VERIFICATION_SCRIPT="$SCRIPT_DIR/verify_notarized_dmg.sh"

WORK_DIR=""
OUTPUT_STAGING_DIR=""
DMG_LAYOUT_DEVICE=""
DMG_VERIFY_DEVICE=""
DMG_LAYOUT_MOUNT_DIR=""
DMG_VERIFY_MOUNT_DIR=""
RESULT_FILE=""
RESULT_FILE_DIR=""
RESULT_STAGING_FILE=""
INPUT_APP=""
SKIP_VERIFICATION=0

usage() {
  echo "usage: $0 [--skip-verification] [--result-file PATH] NOTARIZED_APP" >&2
}

distribution_reject_result_file_conflict() {
  local protected_path="$1"
  local protected_label="$2"

  [[ -n "$RESULT_FILE" ]] || return 0
  if [[ "$RESULT_FILE" == "$protected_path" ]] ||
     [[ -e "$RESULT_FILE" && -e "$protected_path" && "$RESULT_FILE" -ef "$protected_path" ]]; then
    distribution_fail "result-file conflicts with $protected_label: $protected_path"
  fi
}

distribution_validate_result_file_location() {
  [[ -n "$RESULT_FILE" ]] || return 0

  [[ ! -L "$RESULT_FILE" ]] || distribution_fail \
    "result-file must not be a symbolic link: $RESULT_FILE"
  [[ ! -d "$RESULT_FILE" ]] || distribution_fail \
    "result-file must not be a directory: $RESULT_FILE"
  case "$RESULT_FILE" in
    "$INPUT_APP"|"$INPUT_APP"/*)
      distribution_fail "result-file must not be the input app or a path inside it: $RESULT_FILE"
      ;;
  esac
}

distribution_validate_result_file_safety() {
  [[ -n "$RESULT_FILE" ]] || return 0

  distribution_validate_result_file_location

  distribution_reject_result_file_conflict "$ARTIFACT_INFO" "artifact-info.plist"
  distribution_reject_result_file_conflict \
    "$ARTIFACT_CONTENT_MANIFEST" "app-contents.sha256"
  distribution_reject_result_file_conflict \
    "$ARTIFACT_FINGERPRINT" "app-fingerprint.mtree"
  distribution_reject_result_file_conflict "$FINAL_DMG" "the final DMG"
  distribution_reject_result_file_conflict "$STAGED_DMG" "the staged DMG"
}

distribution_resolve_dmg_signing_identity() {
  local app_path="$1"
  local expected_authority="$2"
  local expected_team="$3"
  local certificate_prefix="$4"
  local leaf_certificate="${certificate_prefix}0"
  local candidate_identities
  local certificate_sha1
  local selected_identity
  local signing_identities

  certificate_sha1=""
  if /usr/bin/codesign \
    -d \
    --extract-certificates="$certificate_prefix" \
    "$app_path" >/dev/null 2>&1; then
    if [[ -f "$leaf_certificate" ]]; then
      certificate_sha1="$(/usr/bin/shasum -a 1 "$leaf_certificate" | \
        /usr/bin/awk '{ print toupper($1) }')"
      [[ "$certificate_sha1" =~ ^[0-9A-F]{40}$ ]] || distribution_fail \
        "could not calculate the input app signing certificate SHA-1"
    fi
  fi

  # find-identity reports code-signing identities only when the certificate is
  # paired with its private key. Prefer the app's exact leaf certificate, then
  # allow another valid Developer ID Application identity from the same team so
  # a preserved app can still be packaged after certificate renewal.
  if ! signing_identities="$(/usr/bin/security find-identity -v -p codesigning)"; then
    distribution_fail "could not enumerate available code-signing identities"
  fi
  candidate_identities="$(/usr/bin/printf '%s\n' "$signing_identities" | \
    /usr/bin/awk -v expected_team="$expected_team" '
      function is_hex_sha1(value) {
        return length(value) == 40 && value !~ /[^0-9A-Fa-f]/
      }
      $1 ~ /^[[:digit:]]+\)$/ && is_hex_sha1($2) {
        first_quote = index($0, "\"")
        if (!first_quote) {
          next
        }
        identity_name = substr($0, first_quote + 1)
        sub(/\"$/, "", identity_name)
        team_suffix = "(" expected_team ")"
        if (index(identity_name, "Developer ID Application:") == 1 &&
            length(identity_name) >= length(team_suffix) &&
            substr(identity_name, length(identity_name) - length(team_suffix) + 1) == team_suffix) {
          identity_sha1 = toupper($2)
          if (!seen[identity_sha1]++) {
            print identity_sha1
          }
        }
      }
    ')"
  [[ -n "$candidate_identities" ]] || distribution_fail \
    "no Developer ID Application private key is available for team $expected_team"

  selected_identity=""
  if [[ -n "$certificate_sha1" ]] && /usr/bin/printf '%s\n' "$candidate_identities" | \
    /usr/bin/grep -qx "$certificate_sha1"; then
    selected_identity="$certificate_sha1"
  else
    selected_identity="$(/usr/bin/printf '%s\n' "$candidate_identities" | \
      /usr/bin/awk 'NF { print; exit }')"
    if [[ -n "$certificate_sha1" ]]; then
      echo "warning: the input app certificate private key is unavailable: $expected_authority ($certificate_sha1)" >&2
      echo "warning: using another valid Developer ID Application identity for team $expected_team" >&2
    else
      echo "warning: could not extract the input app leaf certificate; using a valid identity for team $expected_team" >&2
    fi
  fi
  [[ "$selected_identity" =~ ^[0-9A-F]{40}$ ]] || distribution_fail \
    "could not select a unique Developer ID Application identity for team $expected_team"

  /usr/bin/printf '%s\n' "$selected_identity"
}

detach_device() {
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
  if [[ -n "$DMG_VERIFY_DEVICE" ]]; then
    detach_device "$DMG_VERIFY_DEVICE" >/dev/null 2>&1 || true
    DMG_VERIFY_DEVICE=""
  fi
  if [[ -n "$DMG_LAYOUT_DEVICE" ]]; then
    detach_device "$DMG_LAYOUT_DEVICE" >/dev/null 2>&1 || true
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

  if [[ -n "$OUTPUT_STAGING_DIR" ]]; then
    case "$OUTPUT_STAGING_DIR" in
      "$OUTPUT_DIR"/.ThruRNDIS-dmg-distribution.*)
        /bin/rm -rf "$OUTPUT_STAGING_DIR"
        ;;
    esac
  fi

  if [[ -n "$RESULT_STAGING_FILE" ]]; then
    /bin/rm -f "$RESULT_STAGING_FILE"
    RESULT_STAGING_FILE=""
  fi

  if [[ -n "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      /tmp/ThruRNDIS-dmg-distribution.*|/private/tmp/ThruRNDIS-dmg-distribution.*)
        /bin/rm -rf "$WORK_DIR"
        ;;
    esac
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-verification)
      SKIP_VERIFICATION=1
      shift
      ;;
    --result-file)
      [[ $# -ge 2 ]] || {
        usage
        exit 2
      }
      RESULT_FILE="$2"
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
if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  [[ -x "$APP_VERIFICATION_SCRIPT" ]] || distribution_fail \
    "app verification script is missing or not executable: $APP_VERIFICATION_SCRIPT"
  [[ -x "$DMG_VERIFICATION_SCRIPT" ]] || distribution_fail \
    "DMG verification script is missing or not executable: $DMG_VERIFICATION_SCRIPT"
else
  echo "warning: standalone post-notarization app and DMG verification is disabled" >&2
fi
# Resolve the app directory itself, not only its parent. This keeps result-file
# containment checks anchored to the immutable app even when the caller passes
# a symbolic link to it.
INPUT_APP="$(cd "$INPUT_APP" && /bin/pwd -P)"
[[ "$(/usr/bin/basename "$INPUT_APP")" == "$APP_NAME.app" ]] || distribution_fail \
  "expected the preserved app bundle to be named $APP_NAME.app"
[[ -f "$DMG_LAYOUT_SCRIPT" ]] || distribution_fail \
  "DMG layout script not found at $DMG_LAYOUT_SCRIPT"
[[ "$OUTPUT_DIR" != "/" ]] || distribution_fail \
  "the distribution output directory cannot be /"

/bin/mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && /bin/pwd -P)"
[[ "$OUTPUT_DIR" != "/" ]] || distribution_fail \
  "the canonical distribution output directory cannot be /"
if [[ -n "$RESULT_FILE" ]]; then
  [[ "$RESULT_FILE" != */ ]] || distribution_fail \
    "result-file must name a file, not a directory: $RESULT_FILE"
  RESULT_FILE_DIR="$(/usr/bin/dirname "$RESULT_FILE")"
  [[ -d "$RESULT_FILE_DIR" ]] || distribution_fail \
    "result-file directory does not exist: $RESULT_FILE_DIR"
  RESULT_FILE_NAME="$(/usr/bin/basename "$RESULT_FILE")"
  [[ -n "$RESULT_FILE_NAME" && "$RESULT_FILE_NAME" != "." && "$RESULT_FILE_NAME" != ".." ]] || \
    distribution_fail "result-file must have a valid file name: $RESULT_FILE"
  RESULT_FILE_DIR="$(cd "$RESULT_FILE_DIR" && /bin/pwd -P)"
  RESULT_FILE="$RESULT_FILE_DIR/$RESULT_FILE_NAME"
  distribution_validate_result_file_location
fi

SETFILE_BIN="$(/usr/bin/xcrun --find SetFile)"
GETFILEINFO_BIN="$(/usr/bin/xcrun --find GetFileInfo)"
[[ -x "$SETFILE_BIN" && -x "$GETFILEINFO_BIN" ]] || distribution_fail \
  "Xcode resource tools SetFile and GetFileInfo are required"

ARTIFACT_DIR="$(/usr/bin/dirname "$INPUT_APP")"
ARTIFACT_INFO="$ARTIFACT_DIR/artifact-info.plist"
ARTIFACT_CONTENT_MANIFEST="$ARTIFACT_DIR/app-contents.sha256"
ARTIFACT_FINGERPRINT="$ARTIFACT_DIR/app-fingerprint.mtree"
[[ -f "$ARTIFACT_INFO" && -f "$ARTIFACT_CONTENT_MANIFEST" && -f "$ARTIFACT_FINGERPRINT" ]] || distribution_fail \
  "the app is missing immutable artifact metadata produced by build_and_notarize_app.sh"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :version' "$ARTIFACT_INFO")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :build' "$ARTIFACT_INFO")"
ARTIFACT_APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :appName' "$ARTIFACT_INFO")"
APP_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy \
  -c 'Print :bundleIdentifier' "$ARTIFACT_INFO")"
DEVELOPMENT_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :teamIdentifier' "$ARTIFACT_INFO")"
WIREGUARD_APP_GROUP="$(/usr/libexec/PlistBuddy \
  -c 'Print :wireGuardAppGroup' "$ARTIFACT_INFO")"
ARTIFACT_FILE="$(/usr/libexec/PlistBuddy -c 'Print :artifactFile' "$ARTIFACT_INFO")"
EXPECTED_FINGERPRINT_SHA256="$(/usr/libexec/PlistBuddy \
  -c 'Print :fingerprintSHA256' "$ARTIFACT_INFO")"
EXPECTED_CONTENT_MANIFEST_SHA256="$(/usr/libexec/PlistBuddy \
  -c 'Print :contentManifestSHA256' "$ARTIFACT_INFO")"

distribution_require_safe_filename_component "app version" "$APP_VERSION"
distribution_require_safe_filename_component "app build number" "$APP_BUILD"
[[ "$ARTIFACT_APP_NAME" == "$APP_NAME" ]] || distribution_fail \
  "artifact metadata names app $ARTIFACT_APP_NAME instead of $APP_NAME"
[[ "$ARTIFACT_FILE" == "$APP_NAME.app" ]] || distribution_fail \
  "artifact metadata names $ARTIFACT_FILE instead of $APP_NAME.app"
[[ "$(/usr/bin/basename "$ARTIFACT_DIR")" == "$APP_NAME-$APP_VERSION-$APP_BUILD" ]] || distribution_fail \
  "artifact directory name does not match app version/build $APP_VERSION/$APP_BUILD"
[[ "$(distribution_sha256 "$ARTIFACT_FINGERPRINT")" == "$EXPECTED_FINGERPRINT_SHA256" ]] || distribution_fail \
  "the stored app fingerprint does not match artifact-info.plist"
[[ "$(distribution_sha256 "$ARTIFACT_CONTENT_MANIFEST")" == "$EXPECTED_CONTENT_MANIFEST_SHA256" ]] || distribution_fail \
  "the stored app content manifest does not match artifact-info.plist"

DMG_NAME="$APP_NAME-$APP_VERSION-$APP_BUILD.dmg"
VOLUME_NAME="$APP_NAME $APP_VERSION"
FINAL_DMG="$OUTPUT_DIR/$DMG_NAME"
distribution_reject_result_file_conflict "$FINAL_DMG" "the final DMG"
OUTPUT_STAGING_DIR="$(/usr/bin/mktemp -d \
  "$OUTPUT_DIR/.ThruRNDIS-dmg-distribution.XXXXXX")"
STAGED_DMG="$OUTPUT_STAGING_DIR/$DMG_NAME"
distribution_validate_result_file_safety

WORK_DIR="$(/usr/bin/mktemp -d /tmp/ThruRNDIS-dmg-distribution.XXXXXX)"
INPUT_CURRENT_CONTENT_MANIFEST="$WORK_DIR/input-app-contents.sha256"
INPUT_CURRENT_FINGERPRINT="$WORK_DIR/input-app-fingerprint.mtree"
INPUT_FINAL_FINGERPRINT="$WORK_DIR/input-app-final-fingerprint.mtree"

distribution_write_app_content_manifest "$INPUT_APP" "$INPUT_CURRENT_CONTENT_MANIFEST"
/usr/bin/cmp -s "$ARTIFACT_CONTENT_MANIFEST" "$INPUT_CURRENT_CONTENT_MANIFEST" || distribution_fail \
  "the preserved app contents no longer match app-contents.sha256"
distribution_write_app_fingerprint "$INPUT_APP" "$INPUT_CURRENT_FINGERPRINT"
/usr/bin/cmp -s "$ARTIFACT_FINGERPRINT" "$INPUT_CURRENT_FINGERPRINT" || distribution_fail \
  "the preserved app metadata no longer matches app-fingerprint.mtree"

if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  echo "Revalidating the notarized app before DMG creation..."
  "$APP_VERIFICATION_SCRIPT" "$INPUT_APP"
fi
[[ "$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' "$INPUT_APP/Contents/Info.plist")" == "$APP_BUNDLE_IDENTIFIER" ]] || distribution_fail \
  "the app bundle ID no longer matches artifact-info.plist"
[[ "$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$INPUT_APP/Contents/Info.plist")" == "$APP_VERSION" ]] || distribution_fail \
  "the app version no longer matches artifact-info.plist"
[[ "$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' "$INPUT_APP/Contents/Info.plist")" == "$APP_BUILD" ]] || distribution_fail \
  "the app build number no longer matches artifact-info.plist"

APP_SIGNING_AUTHORITY="$(distribution_leaf_signing_authority "$INPUT_APP")"
DMG_SIGNING_IDENTITY_SHA1="$(distribution_resolve_dmg_signing_identity \
  "$INPUT_APP" \
  "$APP_SIGNING_AUTHORITY" \
  "$DEVELOPMENT_TEAM" \
  "$WORK_DIR/input-app-signing-certificate-")"
distribution_validate_notary_credentials "$NOTARY_KEYCHAIN_PROFILE"

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
  "$DEVELOPMENT_TEAM" \
  "$WIREGUARD_APP_GROUP"

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

attach_image() {
  local access_mode="$1"
  local image_path="$2"
  local mount_path="$3"
  local output_variable="$4"
  local attach_output
  local device

  attach_output="$(/usr/bin/hdiutil attach \
    "$access_mode" \
    -nobrowse \
    -noautoopen \
    -mountpoint "$mount_path" \
    "$image_path")"
  device="$(/usr/bin/printf '%s\n' "$attach_output" | /usr/bin/awk '
    /^\/dev\// && !device { device = $1 }
    END { print device }
  ')"
  if [[ -z "$device" ]]; then
    /usr/bin/hdiutil detach "$mount_path" >/dev/null 2>&1 || true
    distribution_fail "could not determine the device for mounted image $image_path"
  fi
  # -v is provided by Bash's printf builtin, not by macOS /usr/bin/printf.
  if ! printf -v "$output_variable" '%s' "$device"; then
    detach_device "$device" >/dev/null 2>&1 || true
    distribution_fail "could not store the device for mounted image $image_path"
  fi
}

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
    "$DEVELOPMENT_TEAM" \
    "$WIREGUARD_APP_GROUP"
}

echo "Applying the app icon and persisted Finder layout..."
attach_image -readwrite "$WRITABLE_DMG" "$DMG_LAYOUT_MOUNT_DIR" DMG_LAYOUT_DEVICE
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
detach_device "$DMG_LAYOUT_DEVICE" || distribution_fail \
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

attach_image -readonly "$STAGED_DMG" "$DMG_VERIFY_MOUNT_DIR" DMG_VERIFY_DEVICE
verify_mounted_dmg "$DMG_VERIFY_MOUNT_DIR" "$WORK_DIR/compressed-volume-validation"
detach_device "$DMG_VERIFY_DEVICE" || distribution_fail \
  "could not detach compressed DMG device $DMG_VERIFY_DEVICE"
DMG_VERIFY_DEVICE=""

echo "Signing, notarizing, and stapling only $DMG_NAME..."
/usr/bin/codesign --force --sign "$DMG_SIGNING_IDENTITY_SHA1" --timestamp "$STAGED_DMG"
distribution_validate_dmg_signature "$STAGED_DMG" "$DEVELOPMENT_TEAM"
/usr/bin/xcrun notarytool submit "$STAGED_DMG" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait
/usr/bin/xcrun stapler staple -v "$STAGED_DMG"
if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  echo "Running standalone notarized DMG verification..."
  "$DMG_VERIFICATION_SCRIPT" "$STAGED_DMG"
fi

distribution_write_app_fingerprint "$INPUT_APP" "$INPUT_FINAL_FINGERPRINT"
/usr/bin/cmp -s "$ARTIFACT_FINGERPRINT" "$INPUT_FINAL_FINGERPRINT" || distribution_fail \
  "the immutable input app changed during DMG creation"

/bin/mv -f "$STAGED_DMG" "$FINAL_DMG"
/bin/rmdir "$OUTPUT_STAGING_DIR"
OUTPUT_STAGING_DIR=""

if [[ -n "$RESULT_FILE" ]]; then
  distribution_validate_result_file_safety
  RESULT_STAGING_FILE="$(/usr/bin/mktemp \
    "$RESULT_FILE_DIR/.ThruRNDIS-dmg-result.XXXXXX")"
  /usr/bin/printf '%s\n' "$FINAL_DMG" >"$RESULT_STAGING_FILE"
  /bin/mv -f "$RESULT_STAGING_FILE" "$RESULT_FILE"
  RESULT_STAGING_FILE=""
fi

echo "Notarized DMG: $FINAL_DMG"
echo "Preserved notarized app: $INPUT_APP"
if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
  echo "Post-notarization DMG verification: skipped"
fi
