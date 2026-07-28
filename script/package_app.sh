#!/usr/bin/env bash

# Requirements for ./script/package_app.sh:
# - All requirements listed at the top of build_app.sh, notarize_app.sh,
#   build_dmg.sh, and notarize_dmg.sh: Release signing profiles, a Developer ID
#   Application certificate/private key, Finder automation permission, Xcode
#   command-line/resource tools, hdiutil, internet access, and Apple notary
#   credentials stored as `thrurndis-notary` by default.
# - Configuration/LocalSigning.xcconfig must contain the local team, bundle ID,
#   and exact app/System Extension direct-distribution provisioning profiles.
#
# This is the one-command release orchestrator:
#   build app -> notarize app -> build DMG -> notarize DMG
# Incomplete work is kept in one versioned directory under
# dist/.package-work/ so rerunning this command resumes completed stages. A
# successful run publishes the app and DMG together under one versioned
# directory in dist/ and removes the empty .package-work root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=script/support/distribution_common.sh
source "$SCRIPT_DIR/support/distribution_common.sh"

APP_NAME="ThruRNDIS"
PROJECT_PATH="$ROOT_DIR/ThruRNDIS.xcodeproj"
CONFIGURATION="Release"

APP_BUILD_SCRIPT="$SCRIPT_DIR/build_app.sh"
APP_NOTARIZATION_SCRIPT="$SCRIPT_DIR/notarize_app.sh"
DMG_BUILD_SCRIPT="$SCRIPT_DIR/build_dmg.sh"
DMG_NOTARIZATION_SCRIPT="$SCRIPT_DIR/notarize_dmg.sh"
XCODEBUILD_BIN="${THRURNDIS_XCODEBUILD:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild}"

OUTPUT_DIR="${THRURNDIS_DISTRIBUTION_OUTPUT_DIR:-$ROOT_DIR/dist}"
PACKAGE_WORK_ROOT="${THRURNDIS_PACKAGE_WORK_DIR:-$OUTPUT_DIR/.package-work}"

WORK_DIR=""
SKIP_VERIFICATION=0

usage() {
  echo "usage: $0 [--skip-verification]" >&2
}

cleanup() {
  if [[ -n "$PACKAGE_WORK_ROOT" && -d "$PACKAGE_WORK_ROOT" ]]; then
    /bin/rmdir "$PACKAGE_WORK_ROOT" 2>/dev/null || true
  fi

  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    echo "Package work preserved; rerun package_app.sh to resume: $WORK_DIR" >&2
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-verification)
      SKIP_VERIFICATION=1
      shift
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

for required_script in \
  "$APP_BUILD_SCRIPT" \
  "$APP_NOTARIZATION_SCRIPT" \
  "$DMG_BUILD_SCRIPT" \
  "$DMG_NOTARIZATION_SCRIPT"; do
  [[ -x "$required_script" ]] || distribution_fail \
    "distribution script is missing or not executable: $required_script"
done
[[ -x "$XCODEBUILD_BIN" ]] || distribution_fail \
  "Xcode beta xcodebuild not found at $XCODEBUILD_BIN"
[[ "$OUTPUT_DIR" != "/" && "$PACKAGE_WORK_ROOT" != "/" ]] || distribution_fail \
  "distribution directories cannot be /"

echo "Resolving package version and build number..."
APP_BUILD_SETTINGS="$("$XCODEBUILD_BIN" \
  -project "$PROJECT_PATH" \
  -target "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -showBuildSettings)"
APP_VERSION="$(distribution_build_setting_value \
  "$APP_BUILD_SETTINGS" MARKETING_VERSION)"
APP_BUILD="$(distribution_build_setting_value \
  "$APP_BUILD_SETTINGS" CURRENT_PROJECT_VERSION)"
distribution_require_safe_filename_component "app version" "$APP_VERSION"
distribution_require_safe_filename_component "app build number" "$APP_BUILD"

/bin/mkdir -p "$OUTPUT_DIR" "$PACKAGE_WORK_ROOT"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && /bin/pwd -P)"
PACKAGE_WORK_ROOT="$(cd "$PACKAGE_WORK_ROOT" && /bin/pwd -P)"
[[ "$OUTPUT_DIR" != "/" && "$PACKAGE_WORK_ROOT" != "/" ]] || distribution_fail \
  "canonical distribution directories cannot be /"

WORK_DIR="$PACKAGE_WORK_ROOT/$APP_NAME-$APP_VERSION-$APP_BUILD"
WORK_APP="$WORK_DIR/$APP_NAME.app"
WORK_DMG="$WORK_DIR/$APP_NAME-$APP_VERSION.dmg"
FINAL_DIR="$OUTPUT_DIR/$APP_NAME-$APP_VERSION-$APP_BUILD"
FINAL_APP="$FINAL_DIR/$APP_NAME.app"
FINAL_DMG="$FINAL_DIR/$APP_NAME-$APP_VERSION.dmg"

if [[ -e "$FINAL_DIR" ]]; then
  [[ -d "$FINAL_DIR" && -d "$FINAL_APP" && -f "$FINAL_DMG" ]] || distribution_fail \
    "package output is incomplete; expected both $FINAL_APP and $FINAL_DMG"

  echo "Package output already exists; validating stapled tickets..."
  /usr/bin/xcrun stapler validate -v "$FINAL_APP"
  /usr/bin/xcrun stapler validate -v "$FINAL_DMG"
  /bin/rmdir "$WORK_DIR" 2>/dev/null || true
  /bin/rmdir "$PACKAGE_WORK_ROOT" 2>/dev/null || true

  echo "Release app artifact: $FINAL_APP"
  echo "Release DMG: $FINAL_DMG"
  echo "Package output already complete; no build or notarization was repeated."
  exit 0
fi

if [[ -e "$WORK_DIR" || -L "$WORK_DIR" ]]; then
  [[ -d "$WORK_DIR" && ! -L "$WORK_DIR" ]] || distribution_fail \
    "package work path is not a directory: $WORK_DIR"
  echo "Resuming package work: $WORK_DIR"
else
  /bin/mkdir "$WORK_DIR"
fi

if [[ -e "$WORK_DMG" && ! -d "$WORK_APP" ]]; then
  distribution_fail "package work contains a DMG without its source app: $WORK_DIR"
fi

if [[ ! -d "$WORK_APP" ]]; then
  "$APP_BUILD_SCRIPT" --output "$WORK_APP"
fi
[[ -d "$WORK_APP" ]] || distribution_fail \
  "app build stage did not produce $WORK_APP"
[[ "$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$WORK_APP/Contents/Info.plist")" == \
  "$APP_VERSION" ]] || distribution_fail \
  "package work app version does not match $APP_VERSION"
[[ "$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' "$WORK_APP/Contents/Info.plist")" == \
  "$APP_BUILD" ]] || distribution_fail \
  "package work app build number does not match $APP_BUILD"

if /usr/bin/xcrun stapler validate "$WORK_APP" >/dev/null 2>&1; then
  echo "Reusing notarized app from package work."
else
  [[ ! -e "$WORK_DMG" ]] || distribution_fail \
    "package work DMG exists but its source app is not notarized: $WORK_DIR"
  if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
    echo "warning: standalone post-notarization verification is disabled for both notarization stages" >&2
    "$APP_NOTARIZATION_SCRIPT" --skip-verification "$WORK_APP"
  else
    "$APP_NOTARIZATION_SCRIPT" "$WORK_APP"
  fi
fi

if [[ ! -f "$WORK_DMG" ]]; then
  "$DMG_BUILD_SCRIPT" --output "$WORK_DMG" "$WORK_APP"
fi
[[ -f "$WORK_DMG" ]] || distribution_fail \
  "DMG build stage did not produce $WORK_DMG"

if /usr/bin/xcrun stapler validate "$WORK_DMG" >/dev/null 2>&1; then
  echo "Reusing notarized DMG from package work."
else
  if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
    "$DMG_NOTARIZATION_SCRIPT" --skip-verification "$WORK_DMG"
  else
    "$DMG_NOTARIZATION_SCRIPT" "$WORK_DMG"
  fi
fi

[[ ! -e "$FINAL_DIR" ]] || distribution_fail \
  "package output appeared while packaging was running: $FINAL_DIR"

/bin/mv "$WORK_DIR" "$FINAL_DIR"
WORK_DIR=""

/bin/rmdir "$PACKAGE_WORK_ROOT" 2>/dev/null || true

echo "Release app artifact: $FINAL_APP"
echo "Release DMG: $FINAL_DMG"
if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
  echo "Post-notarization verification: skipped"
fi
