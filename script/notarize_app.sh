#!/usr/bin/env bash

# Requirements for ./script/notarize_app.sh:
# - One signed ThruRNDIS.app produced by build_app.sh.
# - Apple notary credentials stored in the Keychain profile `thrurndis-notary`:
#     xcrun notarytool store-credentials "thrurndis-notary"
#   Set THRURNDIS_NOTARY_KEYCHAIN_PROFILE to use a different profile.
# - Internet access to the Apple notary service.
#
# This script validates, submits, staples, and verifies the supplied app in
# place. It never rebuilds or re-signs the app. If submission fails, the signed
# input remains at the same path for a direct retry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/support/distribution_common.sh
source "$SCRIPT_DIR/support/distribution_common.sh"

APP_NAME="ThruRNDIS"
DEFAULT_NOTARY_KEYCHAIN_PROFILE="thrurndis-notary"

APP_VERIFICATION_SCRIPT="$SCRIPT_DIR/verify_notarized_app.sh"
NOTARY_KEYCHAIN_PROFILE="${THRURNDIS_NOTARY_KEYCHAIN_PROFILE:-$DEFAULT_NOTARY_KEYCHAIN_PROFILE}"

WORK_DIR=""
INPUT_APP=""
SKIP_VERIFICATION=0

usage() {
  echo "usage: $0 [--skip-verification] SIGNED_APP" >&2
}

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      /tmp/ThruRNDIS-app-notarization.*|/private/tmp/ThruRNDIS-app-notarization.*)
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
[[ -d "$INPUT_APP" ]] || distribution_fail "signed app not found at $INPUT_APP"
if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  [[ -x "$APP_VERIFICATION_SCRIPT" ]] || distribution_fail \
    "app verification script is missing or not executable: $APP_VERIFICATION_SCRIPT"
else
  echo "warning: standalone post-notarization app verification is disabled" >&2
fi

INPUT_APP="$(cd "$INPUT_APP" && /bin/pwd -P)"
[[ "$(/usr/bin/basename "$INPUT_APP")" == "$APP_NAME.app" ]] || distribution_fail \
  "expected the signed app bundle to be named $APP_NAME.app"

distribution_validate_notary_credentials "$NOTARY_KEYCHAIN_PROFILE"

WORK_DIR="$(/usr/bin/mktemp -d /tmp/ThruRNDIS-app-notarization.XXXXXX)"
APP_SUBMISSION_ZIP="$WORK_DIR/$APP_NAME-notary-submission.zip"
VALIDATION_DIR="$WORK_DIR/validation"
ORIGINAL_FINGERPRINT="$WORK_DIR/original-app-fingerprint.mtree"
PRE_STAPLE_FINGERPRINT="$WORK_DIR/pre-staple-app-fingerprint.mtree"
/bin/mkdir "$VALIDATION_DIR"

distribution_validate_app "$INPUT_APP" "$VALIDATION_DIR"
distribution_run_notary_submission_preflight "$INPUT_APP"
distribution_write_app_fingerprint "$INPUT_APP" "$ORIGINAL_FINGERPRINT"

echo "Submitting the signed app to Apple notary service..."
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "$INPUT_APP" "$APP_SUBMISSION_ZIP"
/usr/bin/xcrun notarytool submit "$APP_SUBMISSION_ZIP" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait

distribution_write_app_fingerprint "$INPUT_APP" "$PRE_STAPLE_FINGERPRINT"
/usr/bin/cmp -s "$ORIGINAL_FINGERPRINT" "$PRE_STAPLE_FINGERPRINT" || distribution_fail \
  "the app changed while its notarization submission was running"

echo "Stapling the app notarization ticket..."
/usr/bin/xcrun stapler staple -v "$INPUT_APP"
/usr/bin/xcrun stapler validate -v "$INPUT_APP"
if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  "$APP_VERIFICATION_SCRIPT" "$INPUT_APP"
fi

echo "Notarized app: $INPUT_APP"
if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
  echo "Post-notarization app verification: skipped"
fi
