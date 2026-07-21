#!/usr/bin/env bash

# Verifies an existing ThruRNDIS.app without signing or modifying it.
# Run this from a normal macOS terminal session. Restricted sandboxes can block
# the system trust services used by codesign, stapler, and syspolicy_check and
# can therefore report false signature or Gatekeeper failures.
#
# When the app is in a preserved artifact directory produced by
# build_and_notarize_app.sh, this also validates artifact-info.plist,
# app-contents.sha256, and app-fingerprint.mtree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/distribution_common.sh
source "$SCRIPT_DIR/distribution_common.sh"

APP_NAME="ThruRNDIS"
INPUT_APP=""
WORK_DIR=""

usage() {
  echo "usage: $0 NOTARIZED_APP" >&2
}

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      /tmp/ThruRNDIS-app-verification.*|/private/tmp/ThruRNDIS-app-verification.*)
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

INPUT_APP="$1"
[[ -d "$INPUT_APP" ]] || distribution_fail "app bundle not found at $INPUT_APP"
INPUT_APP="$(cd "$INPUT_APP" && /bin/pwd -P)"
[[ "$(/usr/bin/basename "$INPUT_APP")" == "$APP_NAME.app" ]] || distribution_fail \
  "expected the app bundle to be named $APP_NAME.app"

WORK_DIR="$(/usr/bin/mktemp -d /tmp/ThruRNDIS-app-verification.XXXXXX)"
VALIDATION_DIR="$WORK_DIR/signing"
ARTIFACT_DIR="$(/usr/bin/dirname "$INPUT_APP")"
ARTIFACT_INFO="$ARTIFACT_DIR/artifact-info.plist"
ARTIFACT_CONTENT_MANIFEST="$ARTIFACT_DIR/app-contents.sha256"
ARTIFACT_FINGERPRINT="$ARTIFACT_DIR/app-fingerprint.mtree"
EXPECTED_TEAM=""
EXPECTED_APP_GROUP=""

if [[ -f "$ARTIFACT_INFO" ]]; then
  [[ -f "$ARTIFACT_CONTENT_MANIFEST" && -f "$ARTIFACT_FINGERPRINT" ]] || distribution_fail \
    "the preserved app artifact metadata is incomplete in $ARTIFACT_DIR"

  ARTIFACT_APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :appName' "$ARTIFACT_INFO")"
  ARTIFACT_FILE="$(/usr/libexec/PlistBuddy -c 'Print :artifactFile' "$ARTIFACT_INFO")"
  ARTIFACT_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy \
    -c 'Print :bundleIdentifier' "$ARTIFACT_INFO")"
  ARTIFACT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :version' "$ARTIFACT_INFO")"
  ARTIFACT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :build' "$ARTIFACT_INFO")"
  EXPECTED_TEAM="$(/usr/libexec/PlistBuddy \
    -c 'Print :teamIdentifier' "$ARTIFACT_INFO")"
  EXPECTED_APP_GROUP="$(/usr/libexec/PlistBuddy \
    -c 'Print :wireGuardAppGroup' "$ARTIFACT_INFO")"
  EXPECTED_FINGERPRINT_SHA256="$(/usr/libexec/PlistBuddy \
    -c 'Print :fingerprintSHA256' "$ARTIFACT_INFO")"
  EXPECTED_CONTENT_MANIFEST_SHA256="$(/usr/libexec/PlistBuddy \
    -c 'Print :contentManifestSHA256' "$ARTIFACT_INFO")"

  distribution_require_safe_filename_component "app version" "$ARTIFACT_VERSION"
  distribution_require_safe_filename_component "app build number" "$ARTIFACT_BUILD"
  [[ "$ARTIFACT_APP_NAME" == "$APP_NAME" ]] || distribution_fail \
    "artifact metadata names app $ARTIFACT_APP_NAME instead of $APP_NAME"
  [[ "$ARTIFACT_FILE" == "$APP_NAME.app" ]] || distribution_fail \
    "artifact metadata names $ARTIFACT_FILE instead of $APP_NAME.app"
  [[ "$(/usr/bin/basename "$ARTIFACT_DIR")" == \
     "$APP_NAME-$ARTIFACT_VERSION-$ARTIFACT_BUILD" ]] || distribution_fail \
    "artifact directory name does not match app version/build $ARTIFACT_VERSION/$ARTIFACT_BUILD"
  [[ "$(distribution_sha256 "$ARTIFACT_FINGERPRINT")" == \
     "$EXPECTED_FINGERPRINT_SHA256" ]] || distribution_fail \
    "the stored app fingerprint does not match artifact-info.plist"
  [[ "$(distribution_sha256 "$ARTIFACT_CONTENT_MANIFEST")" == \
     "$EXPECTED_CONTENT_MANIFEST_SHA256" ]] || distribution_fail \
    "the stored app content manifest does not match artifact-info.plist"

  CURRENT_CONTENT_MANIFEST="$WORK_DIR/app-contents.sha256"
  CURRENT_FINGERPRINT="$WORK_DIR/app-fingerprint.mtree"
  distribution_write_app_content_manifest "$INPUT_APP" "$CURRENT_CONTENT_MANIFEST"
  /usr/bin/cmp -s "$ARTIFACT_CONTENT_MANIFEST" "$CURRENT_CONTENT_MANIFEST" || distribution_fail \
    "the preserved app contents no longer match app-contents.sha256"
  distribution_write_app_fingerprint "$INPUT_APP" "$CURRENT_FINGERPRINT"
  /usr/bin/cmp -s "$ARTIFACT_FINGERPRINT" "$CURRENT_FINGERPRINT" || distribution_fail \
    "the preserved app metadata no longer matches app-fingerprint.mtree"

  [[ "$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' "$INPUT_APP/Contents/Info.plist")" == \
    "$ARTIFACT_BUNDLE_IDENTIFIER" ]] || distribution_fail \
    "the app bundle ID does not match artifact-info.plist"
  [[ "$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' "$INPUT_APP/Contents/Info.plist")" == \
    "$ARTIFACT_VERSION" ]] || distribution_fail \
    "the app version does not match artifact-info.plist"
  [[ "$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' "$INPUT_APP/Contents/Info.plist")" == \
    "$ARTIFACT_BUILD" ]] || distribution_fail \
    "the app build number does not match artifact-info.plist"
fi

echo "Validating Developer ID signatures, entitlements, and notarization for $INPUT_APP..."
distribution_validate_notarized_app \
  "$INPUT_APP" \
  "$VALIDATION_DIR" \
  "$EXPECTED_TEAM" \
  "$EXPECTED_APP_GROUP"

APP_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' "$INPUT_APP/Contents/Info.plist")"
APP_VERSION="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$INPUT_APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' "$INPUT_APP/Contents/Info.plist")"
APP_TEAM="$(distribution_team_identifier "$INPUT_APP")"

echo "Verified notarized app: $INPUT_APP"
echo "Bundle: $APP_BUNDLE_IDENTIFIER"
echo "Version/build: $APP_VERSION/$APP_BUILD"
echo "Developer ID team: $APP_TEAM"
