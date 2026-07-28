#!/usr/bin/env bash

# Verifies an existing ThruRNDIS.app without signing or modifying it.
# Run this from a normal macOS terminal session. Restricted sandboxes can block
# the system trust services used by codesign, stapler, and syspolicy_check and
# can therefore report false signature or Gatekeeper failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/support/distribution_common.sh
source "$SCRIPT_DIR/support/distribution_common.sh"

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

echo "Validating Developer ID signatures, entitlements, and notarization for $INPUT_APP..."
distribution_validate_notarized_app \
  "$INPUT_APP" "$VALIDATION_DIR"

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
