#!/usr/bin/env bash

# Requirements for ./script/package_app.sh:
# - All requirements listed at the top of build_and_notarize_app.sh and
#   build_and_notarize_dmg.sh: Release signing profiles, a Developer ID
#   Application certificate/private key, Finder automation permission, Xcode
#   command-line/resource tools, hdiutil, internet access, and Apple notary
#   credentials stored as `thrurndis-notary` by default.
# - Configuration/LocalSigning.xcconfig must contain the local team, bundle ID,
#   and exact app/System Extension direct-distribution provisioning profiles.
#
# This is the one-command release orchestrator. It first publishes a notarized
# app under dist/app-artifacts/ThruRNDIS-<version>-<build>/ without replacing an
# existing app artifact, then passes that exact app to the independent DMG
# stage. The DMG stage revalidates the app and signs/notarizes only the DMG.
# Pass --skip-verification to keep signing, notarization, and stapling enabled
# while skipping the standalone post-notarization verification scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_STAGE_SCRIPT="$SCRIPT_DIR/build_and_notarize_app.sh"
DMG_STAGE_SCRIPT="$SCRIPT_DIR/build_and_notarize_dmg.sh"

fail() {
  echo "error: $*" >&2
  exit 1
}

WORK_DIR=""
SKIP_VERIFICATION=0

usage() {
  echo "usage: $0 [--skip-verification]" >&2
}

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      /tmp/ThruRNDIS-package.*|/private/tmp/ThruRNDIS-package.*)
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

[[ -x "$APP_STAGE_SCRIPT" ]] || fail \
  "app release stage is missing or not executable: $APP_STAGE_SCRIPT"
[[ -x "$DMG_STAGE_SCRIPT" ]] || fail \
  "DMG release stage is missing or not executable: $DMG_STAGE_SCRIPT"

WORK_DIR="$(/usr/bin/mktemp -d /tmp/ThruRNDIS-package.XXXXXX)"
APP_RESULT_FILE="$WORK_DIR/app-result.txt"
DMG_RESULT_FILE="$WORK_DIR/dmg-result.txt"
if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
  echo "warning: standalone post-notarization verification is disabled for both release stages" >&2
  "$APP_STAGE_SCRIPT" --skip-verification --result-file "$APP_RESULT_FILE"
else
  "$APP_STAGE_SCRIPT" --result-file "$APP_RESULT_FILE"
fi
[[ -s "$APP_RESULT_FILE" ]] || fail \
  "app release stage did not report its immutable artifact"
NOTARIZED_APP="$(/usr/bin/sed -n '1p' "$APP_RESULT_FILE")"
[[ -d "$NOTARIZED_APP" ]] || fail \
  "app release stage reported a missing artifact: $NOTARIZED_APP"

if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
  "$DMG_STAGE_SCRIPT" \
    --skip-verification \
    --result-file "$DMG_RESULT_FILE" \
    "$NOTARIZED_APP"
else
  "$DMG_STAGE_SCRIPT" --result-file "$DMG_RESULT_FILE" "$NOTARIZED_APP"
fi
[[ -s "$DMG_RESULT_FILE" ]] || fail \
  "DMG release stage did not report its final artifact"
NOTARIZED_DMG="$(/usr/bin/sed -n '1p' "$DMG_RESULT_FILE")"
[[ -f "$NOTARIZED_DMG" ]] || fail \
  "DMG release stage reported a missing artifact: $NOTARIZED_DMG"

echo "Release app artifact: $NOTARIZED_APP"
echo "Release DMG: $NOTARIZED_DMG"
if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
  echo "Post-notarization verification: skipped"
fi
