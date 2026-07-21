#!/usr/bin/env bash

# Requirements for ./script/build_and_notarize_app.sh:
# - macOS with Xcode beta installed at /Applications/Xcode-beta.app, or set
#   THRURNDIS_XCODEBUILD to another xcodebuild executable.
# - Configuration/LocalSigning.xcconfig copied from the example and configured
#   with DEVELOPMENT_TEAM, the app bundle identifier, and the exact installed
#   direct-distribution provisioning-profile names for both the app and the
#   WireGuard Network System Extension.
# - A Developer ID Application certificate, including its private key, for the
#   configured team in the login Keychain.
# - Apple notary credentials stored in the Keychain profile `thrurndis-notary`:
#     xcrun notarytool store-credentials "thrurndis-notary"
#   Set THRURNDIS_NOTARY_KEYCHAIN_PROFILE to use a different profile.
# - Internet access for Apple notarization and any explicitly enabled Xcode
#   provisioning updates. Set THRURNDIS_ALLOW_PROVISIONING_UPDATES=1 only when
#   Xcode should be allowed to fetch or update signing assets.
#
# The result is a versioned app artifact under dist/app-artifacts/. Its parent
# directory includes the app version and build number, and existing artifact
# directories are never replaced. Pass --skip-verification to skip the
# standalone post-notarization checks while still signing, submitting,
# stapling, and preserving the artifact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=script/distribution_common.sh
source "$SCRIPT_DIR/distribution_common.sh"

APP_NAME="ThruRNDIS"
PROJECT_NAME="ThruRNDIS.xcodeproj"
SCHEME_NAME="ThruRNDIS Runtime"
CONFIGURATION="Release"
DEFAULT_NOTARY_KEYCHAIN_PROFILE="thrurndis-notary"

PROJECT_PATH="$ROOT_DIR/$PROJECT_NAME"
APP_VERIFICATION_SCRIPT="$SCRIPT_DIR/verify_notarized_app.sh"
LOCAL_SIGNING_CONFIG="$ROOT_DIR/Configuration/LocalSigning.xcconfig"
DERIVED_DATA_PATH="${THRURNDIS_DISTRIBUTION_DERIVED_DATA_PATH:-/tmp/ThruRNDIS-DistributionDerivedData}"
OUTPUT_DIR="${THRURNDIS_DISTRIBUTION_OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_ARTIFACT_ROOT="${THRURNDIS_APP_ARTIFACT_DIR:-$OUTPUT_DIR/app-artifacts}"
NOTARY_KEYCHAIN_PROFILE="${THRURNDIS_NOTARY_KEYCHAIN_PROFILE:-$DEFAULT_NOTARY_KEYCHAIN_PROFILE}"
XCODEBUILD_BIN="${THRURNDIS_XCODEBUILD:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild}"

WORK_DIR=""
ARTIFACT_STAGING_DIR=""
PUBLISH_LOCK_DIR=""
PUBLISH_LOCK_HELD=0
RESULT_FILE=""
SKIP_VERIFICATION=0

usage() {
  echo "usage: $0 [--skip-verification] [--result-file PATH]" >&2
}

cleanup() {
  if [[ "$PUBLISH_LOCK_HELD" -eq 1 && -n "$PUBLISH_LOCK_DIR" ]]; then
    case "$PUBLISH_LOCK_DIR" in
      "$APP_ARTIFACT_ROOT"/.ThruRNDIS-*.publish-lock)
        /bin/rmdir "$PUBLISH_LOCK_DIR" 2>/dev/null || true
        ;;
    esac
  fi

  if [[ -n "$ARTIFACT_STAGING_DIR" ]]; then
    case "$ARTIFACT_STAGING_DIR" in
      "$APP_ARTIFACT_ROOT"/.ThruRNDIS-app-artifact.*)
        /bin/chmod -R u+w "$ARTIFACT_STAGING_DIR" 2>/dev/null || true
        /bin/rm -rf "$ARTIFACT_STAGING_DIR"
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
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -x "$XCODEBUILD_BIN" ]] || distribution_fail \
  "Xcode beta xcodebuild not found at $XCODEBUILD_BIN"
if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  [[ -x "$APP_VERIFICATION_SCRIPT" ]] || distribution_fail \
    "app verification script is missing or not executable: $APP_VERIFICATION_SCRIPT"
else
  echo "warning: standalone post-notarization app verification is disabled" >&2
fi
[[ -f "$LOCAL_SIGNING_CONFIG" ]] || distribution_fail \
  "missing $LOCAL_SIGNING_CONFIG; copy LocalSigning.xcconfig.example and configure Developer ID signing first"
[[ "$OUTPUT_DIR" != "/" && "$APP_ARTIFACT_ROOT" != "/" ]] || distribution_fail \
  "distribution output directories cannot be /"
[[ "${THRURNDIS_ALLOW_PROVISIONING_UPDATES:-0}" == "0" ||
   "${THRURNDIS_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]] || distribution_fail \
  "THRURNDIS_ALLOW_PROVISIONING_UPDATES must be 0 or 1"

/bin/mkdir -p "$OUTPUT_DIR" "$APP_ARTIFACT_ROOT"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && /bin/pwd -P)"
APP_ARTIFACT_ROOT="$(cd "$APP_ARTIFACT_ROOT" && /bin/pwd -P)"
[[ "$OUTPUT_DIR" != "/" && "$APP_ARTIFACT_ROOT" != "/" ]] || distribution_fail \
  "canonical distribution output directories cannot be /"
if [[ -n "$RESULT_FILE" ]]; then
  RESULT_FILE_DIR="$(/usr/bin/dirname "$RESULT_FILE")"
  [[ -d "$RESULT_FILE_DIR" ]] || distribution_fail \
    "result-file directory does not exist: $RESULT_FILE_DIR"
fi

echo "Resolving Release signing settings..."
APP_BUILD_SETTINGS="$("$XCODEBUILD_BIN" \
  -project "$PROJECT_PATH" \
  -target "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -showBuildSettings)"
EXTENSION_BUILD_SETTINGS="$("$XCODEBUILD_BIN" \
  -project "$PROJECT_PATH" \
  -target ThruRNDISWireGuardNetworkExtension \
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
EXTENSION_BUNDLE_IDENTIFIER="$(distribution_build_setting_value \
  "$EXTENSION_BUILD_SETTINGS" PRODUCT_BUNDLE_IDENTIFIER)"
EXTENSION_PROVISIONING_PROFILE="$(distribution_build_setting_value \
  "$EXTENSION_BUILD_SETTINGS" PROVISIONING_PROFILE_SPECIFIER)"
EXTENSION_DEVELOPMENT_TEAM="$(distribution_build_setting_value \
  "$EXTENSION_BUILD_SETTINGS" DEVELOPMENT_TEAM)"

[[ -n "$DEVELOPMENT_TEAM" ]] || distribution_fail \
  "DEVELOPMENT_TEAM is empty in LocalSigning.xcconfig"
[[ "$EXTENSION_DEVELOPMENT_TEAM" == "$DEVELOPMENT_TEAM" ]] || distribution_fail \
  "the app and Network System Extension use different development teams"
[[ -n "$APP_BUNDLE_IDENTIFIER" && -n "$EXTENSION_BUNDLE_IDENTIFIER" ]] || distribution_fail \
  "Release bundle identifiers could not be resolved"
distribution_require_safe_filename_component "app version" "$APP_VERSION_SETTING"
distribution_require_safe_filename_component "app build number" "$APP_BUILD_SETTING"

FINAL_ARTIFACT_DIR="$APP_ARTIFACT_ROOT/$APP_NAME-$APP_VERSION_SETTING-$APP_BUILD_SETTING"
[[ ! -e "$FINAL_ARTIFACT_DIR" ]] || distribution_fail \
  "immutable app artifact already exists at $FINAL_ARTIFACT_DIR; increment the build number or pass that artifact directly to build_and_notarize_dmg.sh"
PUBLISH_LOCK_DIR="$APP_ARTIFACT_ROOT/.ThruRNDIS-$APP_VERSION_SETTING-$APP_BUILD_SETTING.publish-lock"
if ! /bin/mkdir "$PUBLISH_LOCK_DIR" 2>/dev/null; then
  distribution_fail \
    "another release is publishing app version/build $APP_VERSION_SETTING/$APP_BUILD_SETTING, or a stale lock exists at $PUBLISH_LOCK_DIR"
fi
PUBLISH_LOCK_HELD=1

SIGNING_SETUP_VALID=1
if [[ -z "$APP_PROVISIONING_PROFILE" ]]; then
  echo "error: set THRURNDIS_APP_DISTRIBUTION_PROVISIONING_PROFILE in LocalSigning.xcconfig" >&2
  SIGNING_SETUP_VALID=0
fi
if [[ -z "$EXTENSION_PROVISIONING_PROFILE" ]]; then
  echo "error: set THRURNDIS_NETWORK_EXTENSION_DISTRIBUTION_PROVISIONING_PROFILE in LocalSigning.xcconfig" >&2
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

distribution_validate_notary_credentials "$NOTARY_KEYCHAIN_PROFILE"

WORK_DIR="$(/usr/bin/mktemp -d /tmp/ThruRNDIS-app-distribution.XXXXXX)"
ARCHIVE_PATH="$WORK_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$WORK_DIR/export"
EXPORT_OPTIONS_PLIST="$WORK_DIR/ExportOptions.plist"
APP_SUBMISSION_ZIP="$WORK_DIR/$APP_NAME-notary-submission.zip"
VALIDATION_DIR="$WORK_DIR/validation"
ARTIFACT_VALIDATION_DIR="$WORK_DIR/artifact-validation"

/bin/mkdir -p \
  "$VALIDATION_DIR" \
  "$ARTIFACT_VALIDATION_DIR"
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
/usr/libexec/PlistBuddy \
  -c "Add :provisioningProfiles:$EXTENSION_BUNDLE_IDENTIFIER string $EXTENSION_PROVISIONING_PROFILE" \
  "$EXPORT_OPTIONS_PLIST"

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
distribution_run_notary_submission_preflight "$EXPORTED_APP"

echo "Submitting the app to Apple notary service..."
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "$EXPORTED_APP" "$APP_SUBMISSION_ZIP"
/usr/bin/xcrun notarytool submit "$APP_SUBMISSION_ZIP" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait

echo "Stapling the app notarization ticket..."
/usr/bin/xcrun stapler staple -v "$EXPORTED_APP"
if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  "$APP_VERIFICATION_SCRIPT" "$EXPORTED_APP"
fi

ARTIFACT_STAGING_DIR="$(/usr/bin/mktemp -d \
  "$APP_ARTIFACT_ROOT/.ThruRNDIS-app-artifact.XXXXXX")"
STAGED_APP="$ARTIFACT_STAGING_DIR/$APP_NAME.app"
STAGED_INFO="$ARTIFACT_STAGING_DIR/artifact-info.plist"
STAGED_CONTENT_MANIFEST="$ARTIFACT_STAGING_DIR/app-contents.sha256"
STAGED_FINGERPRINT="$ARTIFACT_STAGING_DIR/app-fingerprint.mtree"

echo "Creating versioned app artifact $APP_NAME-$APP_VERSION-$APP_BUILD..."
/usr/bin/ditto "$EXPORTED_APP" "$STAGED_APP"
distribution_compare_app_contents \
  "$EXPORTED_APP" "$STAGED_APP" "$ARTIFACT_VALIDATION_DIR/content-comparison"
if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  "$APP_VERIFICATION_SCRIPT" "$STAGED_APP"
fi
distribution_write_app_content_manifest "$STAGED_APP" "$STAGED_CONTENT_MANIFEST"
distribution_write_app_fingerprint "$STAGED_APP" "$STAGED_FINGERPRINT"

ARTIFACT_FINGERPRINT_SHA256="$(distribution_sha256 "$STAGED_FINGERPRINT")"
ARTIFACT_CONTENT_MANIFEST_SHA256="$(distribution_sha256 "$STAGED_CONTENT_MANIFEST")"
ARTIFACT_TEAM="$(distribution_team_identifier "$EXPORTED_APP")"
WIREGUARD_APP_GROUP="$(/usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.application-groups:0' \
  "$VALIDATION_DIR/extension-entitlements.plist")"
/usr/bin/plutil -create xml1 "$STAGED_INFO"
/usr/bin/plutil -insert appName -string "$APP_NAME" "$STAGED_INFO"
/usr/bin/plutil -insert bundleIdentifier -string "$APP_BUNDLE_IDENTIFIER" "$STAGED_INFO"
/usr/bin/plutil -insert version -string "$APP_VERSION" "$STAGED_INFO"
/usr/bin/plutil -insert build -string "$APP_BUILD" "$STAGED_INFO"
/usr/bin/plutil -insert teamIdentifier -string "$ARTIFACT_TEAM" "$STAGED_INFO"
/usr/bin/plutil -insert wireGuardAppGroup -string "$WIREGUARD_APP_GROUP" "$STAGED_INFO"
/usr/bin/plutil -insert artifactFile -string "$APP_NAME.app" "$STAGED_INFO"
/usr/bin/plutil -insert fingerprintSHA256 -string \
  "$ARTIFACT_FINGERPRINT_SHA256" "$STAGED_INFO"
/usr/bin/plutil -insert contentManifestSHA256 -string \
  "$ARTIFACT_CONTENT_MANIFEST_SHA256" "$STAGED_INFO"

[[ ! -e "$FINAL_ARTIFACT_DIR" ]] || distribution_fail \
  "immutable app artifact appeared while this build was running: $FINAL_ARTIFACT_DIR"
/bin/chmod 0444 \
  "$STAGED_INFO" \
  "$STAGED_CONTENT_MANIFEST" \
  "$STAGED_FINGERPRINT"
/bin/chmod 0555 "$ARTIFACT_STAGING_DIR"
/bin/mv "$ARTIFACT_STAGING_DIR" "$FINAL_ARTIFACT_DIR"
ARTIFACT_STAGING_DIR=""
/bin/rmdir "$PUBLISH_LOCK_DIR"
PUBLISH_LOCK_DIR=""
PUBLISH_LOCK_HELD=0

FINAL_ARTIFACT="$FINAL_ARTIFACT_DIR/$APP_NAME.app"
if [[ -n "$RESULT_FILE" ]]; then
  /usr/bin/printf '%s\n' "$FINAL_ARTIFACT" >"$RESULT_FILE"
fi

echo "Notarized app artifact: $FINAL_ARTIFACT"
echo "Artifact fingerprint: $FINAL_ARTIFACT_DIR/app-fingerprint.mtree"
if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
  echo "Post-notarization app verification: skipped"
fi
