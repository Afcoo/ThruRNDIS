#!/usr/bin/env bash

# Requirements for ./script/notarize_dmg.sh:
# - One signed DMG produced by build_dmg.sh.
# - Apple notary credentials stored in the Keychain profile `thrurndis-notary`:
#     xcrun notarytool store-credentials "thrurndis-notary"
#   Set THRURNDIS_NOTARY_KEYCHAIN_PROFILE to use a different profile.
# - Internet access to the Apple notary service.
#
# This script validates, submits, staples, and verifies the supplied DMG in
# place. It never rebuilds or re-signs the DMG or its embedded app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/support/distribution_common.sh
source "$SCRIPT_DIR/support/distribution_common.sh"

APP_NAME="ThruRNDIS"
DEFAULT_NOTARY_KEYCHAIN_PROFILE="thrurndis-notary"

NOTARY_KEYCHAIN_PROFILE="${THRURNDIS_NOTARY_KEYCHAIN_PROFILE:-$DEFAULT_NOTARY_KEYCHAIN_PROFILE}"
DMG_VERIFICATION_SCRIPT="$SCRIPT_DIR/verify_notarized_dmg.sh"

INPUT_DMG=""
SKIP_VERIFICATION=0

usage() {
  echo "usage: $0 [--skip-verification] SIGNED_DMG" >&2
}

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
      [[ -z "$INPUT_DMG" ]] || {
        usage
        exit 2
      }
      INPUT_DMG="$1"
      shift
      ;;
  esac
done
if [[ $# -gt 0 ]]; then
  [[ -z "$INPUT_DMG" && $# -eq 1 ]] || {
    usage
    exit 2
  }
  INPUT_DMG="$1"
fi

[[ -n "$INPUT_DMG" ]] || {
  usage
  exit 2
}
[[ -f "$INPUT_DMG" ]] || distribution_fail "signed DMG not found at $INPUT_DMG"
if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  [[ -x "$DMG_VERIFICATION_SCRIPT" ]] || distribution_fail \
    "DMG verification script is missing or not executable: $DMG_VERIFICATION_SCRIPT"
else
  echo "warning: standalone post-notarization DMG verification is disabled" >&2
fi

INPUT_DMG_PARENT="$(/usr/bin/dirname "$INPUT_DMG")"
INPUT_DMG_NAME="$(/usr/bin/basename "$INPUT_DMG")"
INPUT_DMG_PARENT="$(cd "$INPUT_DMG_PARENT" && /bin/pwd -P)"
INPUT_DMG="$INPUT_DMG_PARENT/$INPUT_DMG_NAME"
[[ "$INPUT_DMG_NAME" == "$APP_NAME-"*.dmg ]] || distribution_fail \
  "expected a signed $APP_NAME-<version>.dmg"

echo "Validating the signed DMG before notarization..."
/usr/bin/hdiutil verify "$INPUT_DMG"
DMG_TEAM="$(distribution_team_identifier "$INPUT_DMG")"
[[ -n "$DMG_TEAM" && "$DMG_TEAM" != "not set" ]] || distribution_fail \
  "the DMG has no signing team"
distribution_validate_dmg_signature "$INPUT_DMG" "$DMG_TEAM"
distribution_validate_notary_credentials "$NOTARY_KEYCHAIN_PROFILE"

ORIGINAL_DMG_SHA256="$(distribution_sha256 "$INPUT_DMG")"

echo "Submitting the signed DMG to Apple notary service..."
/usr/bin/xcrun notarytool submit "$INPUT_DMG" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait

[[ "$(distribution_sha256 "$INPUT_DMG")" == "$ORIGINAL_DMG_SHA256" ]] || distribution_fail \
  "the DMG changed while its notarization submission was running"

echo "Stapling the DMG notarization ticket..."
/usr/bin/xcrun stapler staple -v "$INPUT_DMG"
/usr/bin/xcrun stapler validate -v "$INPUT_DMG"
if [[ "$SKIP_VERIFICATION" -eq 0 ]]; then
  "$DMG_VERIFICATION_SCRIPT" "$INPUT_DMG"
fi

echo "Notarized DMG: $INPUT_DMG"
if [[ "$SKIP_VERIFICATION" -eq 1 ]]; then
  echo "Post-notarization DMG verification: skipped"
fi
