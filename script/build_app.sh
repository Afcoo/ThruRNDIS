#!/usr/bin/env bash

# Requirements for ./script/build_app.sh:
# - macOS with Xcode beta installed at /Applications/Xcode-beta.app, or set
#   THRURNDIS_XCODEBUILD to another xcodebuild executable.
# - Configuration/LocalSigning.xcconfig copied from the example and configured
#   with DEVELOPMENT_TEAM, the app bundle identifier, and the exact installed
#   direct-distribution provisioning-profile name for the app. The privileged
#   helper uses the derived app identifier suffix and the same signing team, but
#   no provisioning profile.
# - A Developer ID Application certificate, including its private key, for the
#   configured team in the login Keychain.
# - Internet access only when Xcode provisioning updates are explicitly
#   enabled. Set THRURNDIS_ALLOW_PROVISIONING_UPDATES=1 only when Xcode should
#   be allowed to fetch or update signing assets.
#
# This script only archives, exports, and validates the Developer ID app. It
# does not contact Apple notarization services or staple a ticket. Pass
# --output to choose the app path used by package_app.sh or a manual workflow;
# otherwise it writes ThruRNDIS.app in the current working directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=script/support/distribution_common.sh
source "$SCRIPT_DIR/support/distribution_common.sh"
# shellcheck source=script/support/distribution_io.sh
source "$SCRIPT_DIR/support/distribution_io.sh"

APP_NAME="ThruRNDIS"
PROJECT_NAME="ThruRNDIS.xcodeproj"
SCHEME_NAME="ThruRNDIS Runtime"
CONFIGURATION="Release"

PROJECT_PATH="$ROOT_DIR/$PROJECT_NAME"
LOCAL_SIGNING_CONFIG="$ROOT_DIR/Configuration/LocalSigning.xcconfig"
DERIVED_DATA_PATH="${THRURNDIS_DISTRIBUTION_DERIVED_DATA_PATH:-/tmp/ThruRNDIS-DistributionDerivedData}"
XCODEBUILD_BIN="${THRURNDIS_XCODEBUILD:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild}"

WORK_DIR=""
OUTPUT_STAGING_DIR=""
OUTPUT_PARENT=""
OUTPUT_APP=""

usage() {
  echo "usage: $0 [--output APP_PATH]" >&2
}

cleanup() {
  if [[ -n "$OUTPUT_STAGING_DIR" && -n "$OUTPUT_PARENT" ]]; then
    case "$OUTPUT_STAGING_DIR" in
      "$OUTPUT_PARENT"/.ThruRNDIS-app-build.*)
        /bin/rm -rf "$OUTPUT_STAGING_DIR"
        ;;
    esac
  fi

  if [[ -n "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      /tmp/ThruRNDIS-app-distribution.*|/private/tmp/ThruRNDIS-app-distribution.*)
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
      OUTPUT_APP="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -x "$XCODEBUILD_BIN" ]] || distribution_fail \
  "Xcode beta xcodebuild not found at $XCODEBUILD_BIN"
[[ -f "$LOCAL_SIGNING_CONFIG" ]] || distribution_fail \
  "missing $LOCAL_SIGNING_CONFIG; copy LocalSigning.xcconfig.example and configure Developer ID signing first"
[[ "${THRURNDIS_ALLOW_PROVISIONING_UPDATES:-0}" == "0" ||
   "${THRURNDIS_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]] || distribution_fail \
  "THRURNDIS_ALLOW_PROVISIONING_UPDATES must be 0 or 1"

echo "Resolving Release signing settings..."
APP_BUILD_SETTINGS="$("$XCODEBUILD_BIN" \
  -project "$PROJECT_PATH" \
  -target "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -showBuildSettings)"
HELPER_BUILD_SETTINGS="$("$XCODEBUILD_BIN" \
  -project "$PROJECT_PATH" \
  -target ThruRNDISPrivilegedHelper \
  -configuration "$CONFIGURATION" \
  -showBuildSettings)"

APP_BUNDLE_IDENTIFIER="$(distribution_build_setting_value \
  "$APP_BUILD_SETTINGS" PRODUCT_BUNDLE_IDENTIFIER)"
APP_PROVISIONING_PROFILE="$(distribution_build_setting_value \
  "$APP_BUILD_SETTINGS" PROVISIONING_PROFILE_SPECIFIER)"
DEVELOPMENT_TEAM="$(distribution_build_setting_value \
  "$APP_BUILD_SETTINGS" DEVELOPMENT_TEAM)"
APP_VERSION_SETTING="$(distribution_build_setting_value \
  "$APP_BUILD_SETTINGS" MARKETING_VERSION)"
APP_BUILD_SETTING="$(distribution_build_setting_value \
  "$APP_BUILD_SETTINGS" CURRENT_PROJECT_VERSION)"
HELPER_BUNDLE_IDENTIFIER="$(distribution_build_setting_value \
  "$HELPER_BUILD_SETTINGS" PRODUCT_BUNDLE_IDENTIFIER)"
HELPER_PROVISIONING_PROFILE="$(distribution_build_setting_value \
  "$HELPER_BUILD_SETTINGS" PROVISIONING_PROFILE_SPECIFIER)"
HELPER_DEVELOPMENT_TEAM="$(distribution_build_setting_value \
  "$HELPER_BUILD_SETTINGS" DEVELOPMENT_TEAM)"
EXPECTED_HELPER_BUNDLE_IDENTIFIER="$APP_BUNDLE_IDENTIFIER.privileged-helper"

[[ -n "$DEVELOPMENT_TEAM" ]] || distribution_fail \
  "DEVELOPMENT_TEAM is empty in LocalSigning.xcconfig"
[[ "$HELPER_DEVELOPMENT_TEAM" == "$DEVELOPMENT_TEAM" ]] || distribution_fail \
  "the app and privileged helper use different development teams"
[[ -n "$APP_BUNDLE_IDENTIFIER" && -n "$HELPER_BUNDLE_IDENTIFIER" ]] || distribution_fail \
  "Release bundle identifiers could not be resolved"
[[ "$HELPER_BUNDLE_IDENTIFIER" == "$EXPECTED_HELPER_BUNDLE_IDENTIFIER" ]] || distribution_fail \
  "the privileged-helper bundle ID is $HELPER_BUNDLE_IDENTIFIER instead of $EXPECTED_HELPER_BUNDLE_IDENTIFIER"
distribution_require_safe_filename_component "app version" "$APP_VERSION_SETTING"
distribution_require_safe_filename_component "app build number" "$APP_BUILD_SETTING"

if [[ -z "$OUTPUT_APP" ]]; then
  OUTPUT_APP="$PWD/$APP_NAME.app"
fi
OUTPUT_APP="$(distribution_resolve_new_output_path \
  "$OUTPUT_APP" "$APP_NAME.app" "app output")"
OUTPUT_PARENT="$(/usr/bin/dirname "$OUTPUT_APP")"

SIGNING_SETUP_VALID=1
if [[ -z "$APP_PROVISIONING_PROFILE" ]]; then
  echo "error: set THRURNDIS_APP_DISTRIBUTION_PROVISIONING_PROFILE in LocalSigning.xcconfig" >&2
  SIGNING_SETUP_VALID=0
fi
if [[ -n "$HELPER_PROVISIONING_PROFILE" ]]; then
  echo "error: the privileged helper must not use a provisioning profile" >&2
  SIGNING_SETUP_VALID=0
fi
SIGNING_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
if ! /usr/bin/printf '%s\n' "$SIGNING_IDENTITIES" | /usr/bin/awk -v team="$DEVELOPMENT_TEAM" '
  index($0, "Developer ID Application:") && index($0, "(" team ")") { found = 1 }
  END { exit(found ? 0 : 1) }
'; then
  echo "error: no Developer ID Application certificate is available for team $DEVELOPMENT_TEAM" >&2
  SIGNING_SETUP_VALID=0
fi
[[ "$SIGNING_SETUP_VALID" -eq 1 ]] || distribution_fail \
  "Release signing prerequisites are incomplete"

WORK_DIR="$(/usr/bin/mktemp -d /tmp/ThruRNDIS-app-distribution.XXXXXX)"
ARCHIVE_PATH="$WORK_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$WORK_DIR/export"
EXPORT_OPTIONS_PLIST="$WORK_DIR/ExportOptions.plist"
VALIDATION_DIR="$WORK_DIR/validation"

/bin/mkdir -p "$VALIDATION_DIR"
/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert destination -string export "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert method -string developer-id "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert signingStyle -string manual "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert signingCertificate -string "Developer ID Application" "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert teamID -string "$DEVELOPMENT_TEAM" "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy \
  -c "Add :provisioningProfiles:$APP_BUNDLE_IDENTIFIER string $APP_PROVISIONING_PROFILE" \
  "$EXPORT_OPTIONS_PLIST"
# A command-line privileged helper is nested code, not a provisioned app
# bundle. Intentionally keep it out of the ExportOptions provisioningProfiles
# dictionary; Xcode signs it with the app's Developer ID team identity.

ARCHIVE_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME_NAME"
  -configuration "$CONFIGURATION"
  -destination "platform=macOS"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -archivePath "$ARCHIVE_PATH"
)
EXPORT_ARGS=(
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)
if [[ "${THRURNDIS_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
  ARCHIVE_ARGS+=(-allowProvisioningUpdates)
  EXPORT_ARGS+=(-allowProvisioningUpdates)
fi
ARCHIVE_ARGS+=(archive)

echo "Archiving the Developer ID Release app..."
"$XCODEBUILD_BIN" "${ARCHIVE_ARGS[@]}"

echo "Exporting the Developer ID app..."
"$XCODEBUILD_BIN" "${EXPORT_ARGS[@]}"

EXPORTED_APP="$EXPORT_PATH/$APP_NAME.app"
[[ -d "$EXPORTED_APP" ]] || distribution_fail \
  "expected exported app bundle was not produced at $EXPORTED_APP"

APP_VERSION="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$EXPORTED_APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' "$EXPORTED_APP/Contents/Info.plist")"
EXPORTED_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' "$EXPORTED_APP/Contents/Info.plist")"
distribution_require_safe_filename_component "app version" "$APP_VERSION"
distribution_require_safe_filename_component "app build number" "$APP_BUILD"
[[ "$APP_VERSION" == "$APP_VERSION_SETTING" && "$APP_BUILD" == "$APP_BUILD_SETTING" ]] || distribution_fail \
  "exported app version/build $APP_VERSION/$APP_BUILD does not match resolved settings $APP_VERSION_SETTING/$APP_BUILD_SETTING"
[[ "$EXPORTED_BUNDLE_IDENTIFIER" == "$APP_BUNDLE_IDENTIFIER" ]] || distribution_fail \
  "exported app bundle ID $EXPORTED_BUNDLE_IDENTIFIER does not match $APP_BUNDLE_IDENTIFIER"

distribution_validate_app "$EXPORTED_APP" "$VALIDATION_DIR" "$DEVELOPMENT_TEAM"

OUTPUT_STAGING_DIR="$(/usr/bin/mktemp -d \
  "$OUTPUT_PARENT/.ThruRNDIS-app-build.XXXXXX")"
BUILT_APP="$OUTPUT_STAGING_DIR/$APP_NAME.app"

echo "Writing signed app build $APP_NAME-$APP_VERSION-$APP_BUILD..."
/usr/bin/ditto "$EXPORTED_APP" "$BUILT_APP"
distribution_compare_app_contents \
  "$EXPORTED_APP" "$BUILT_APP" "$WORK_DIR/build-copy-comparison"
distribution_validate_app \
  "$BUILT_APP" "$WORK_DIR/build-copy-validation" "$DEVELOPMENT_TEAM"

[[ ! -e "$OUTPUT_APP" && ! -L "$OUTPUT_APP" ]] || distribution_fail \
  "app output appeared while this build was running: $OUTPUT_APP"
/bin/mv "$BUILT_APP" "$OUTPUT_APP"
/bin/rmdir "$OUTPUT_STAGING_DIR"
OUTPUT_STAGING_DIR=""

echo "Signed app build: $OUTPUT_APP"
echo "Next: $SCRIPT_DIR/notarize_app.sh \"$OUTPUT_APP\""
