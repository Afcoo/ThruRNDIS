#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ThruRNDIS"
PROJECT_NAME="ThruRNDIS.xcodeproj"
SCHEME_NAME="ThruRNDIS Runtime"
CONFIGURATION="RuntimeDebug"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=script/distribution_common.sh
source "$SCRIPT_DIR/distribution_common.sh"
PROJECT_PATH="$ROOT_DIR/$PROJECT_NAME"
LOCAL_SIGNING_CONFIG="$ROOT_DIR/Configuration/LocalSigning.xcconfig"
WIREGUARD_GO_BRIDGE_SCRIPT="$ROOT_DIR/script/build_wireguard_go_bridge.sh"
DERIVED_DATA_PATH="${THRURNDIS_RUNTIME_DERIVED_DATA_PATH:-/tmp/ThruRNDIS-RuntimeDerivedData}"
BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
XCODEBUILD_BIN="${THRURNDIS_XCODEBUILD:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild}"

VALIDATION_DIR=""
INSTALL_STAGING_ROOT=""
BACKUP_APP=""
RESTORE_BACKUP=0

fail() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  if [[ "$RESTORE_BACKUP" -eq 1 && -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
    if [[ -e "$INSTALL_APP" ]]; then
      /bin/mv "$INSTALL_APP" "$INSTALL_STAGING_ROOT/Failed-$APP_NAME.app" || true
    fi
    /bin/mv "$BACKUP_APP" "$INSTALL_APP" || true
  fi

  if [[ -n "$INSTALL_STAGING_ROOT" ]]; then
    case "$INSTALL_STAGING_ROOT" in
      /Applications/.ThruRNDIS-install.*)
        /bin/rm -rf "$INSTALL_STAGING_ROOT"
        ;;
    esac
  fi

  if [[ -n "$VALIDATION_DIR" ]]; then
    case "$VALIDATION_DIR" in
      /tmp/ThruRNDIS-signing.*|/private/tmp/ThruRNDIS-signing.*)
        /bin/rm -rf "$VALIDATION_DIR"
        ;;
    esac
  fi
}

trap cleanup EXIT

if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi

[[ -x "$XCODEBUILD_BIN" ]] || fail "Xcode beta xcodebuild not found at $XCODEBUILD_BIN"
[[ -f "$LOCAL_SIGNING_CONFIG" ]] || fail \
  "missing $LOCAL_SIGNING_CONFIG; copy LocalSigning.xcconfig.example and configure local signing first"
[[ -x "$WIREGUARD_GO_BRIDGE_SCRIPT" ]] || fail \
  "WireGuard Go bridge build script is not executable at $WIREGUARD_GO_BRIDGE_SCRIPT"

VALIDATION_DIR="$(/usr/bin/mktemp -d /tmp/ThruRNDIS-signing.XXXXXX)"

require_boolean_entitlement() {
  local entitlements_path="$1"
  local entitlement_name="$2"
  local entitlement_value

  entitlement_value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement_name" "$entitlements_path" 2>/dev/null || true)"
  [[ "$entitlement_value" == "true" ]] || fail \
    "required boolean entitlement is missing or false: $entitlement_name"
}

require_array_value() {
  local entitlements_path="$1"
  local entitlement_name="$2"
  local expected_value="$3"
  local entitlement_value

  entitlement_value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement_name:0" "$entitlements_path" 2>/dev/null || true)"
  [[ "$entitlement_value" == "$expected_value" ]] || fail \
    "required entitlement value is missing: $entitlement_name contains $expected_value"
}

require_nonempty_array_value() {
  local entitlements_path="$1"
  local entitlement_name="$2"
  local entitlement_value

  entitlement_value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement_name:0" "$entitlements_path" 2>/dev/null || true)"
  [[ -n "$entitlement_value" ]] || fail \
    "required entitlement array is empty or missing: $entitlement_name"
}

team_identifier() {
  /usr/bin/codesign -dvvv "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1
}

validate_signed_runtime_app() {
  local app_path="$1"
  local system_extensions_dir="$app_path/Contents/Library/SystemExtensions"
  local app_entitlements="$VALIDATION_DIR/app-entitlements.plist"
  local extension_entitlements="$VALIDATION_DIR/extension-entitlements.plist"
  local app_bundle_identifier
  local app_team
  local extension_bundle_identifier
  local extension_team
  local expected_extension_bundle_identifier
  local system_extensions

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

  shopt -s nullglob
  system_extensions=("$system_extensions_dir"/*.systemextension)
  shopt -u nullglob
  [[ "${#system_extensions[@]}" -eq 1 ]] || fail \
    "expected exactly one embedded Network System Extension in $system_extensions_dir"

  app_bundle_identifier="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
  extension_bundle_identifier="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' "${system_extensions[0]}/Contents/Info.plist")"
  expected_extension_bundle_identifier="$app_bundle_identifier.network-extension"
  [[ "$extension_bundle_identifier" == "$expected_extension_bundle_identifier" ]] || fail \
    "the Network System Extension bundle ID is $extension_bundle_identifier instead of $expected_extension_bundle_identifier"
  [[ "${system_extensions[0]##*/}" == "$extension_bundle_identifier.systemextension" ]] || fail \
    "the Network System Extension filename does not match its bundle ID: ${system_extensions[0]}"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "${system_extensions[0]}"

  app_team="$(team_identifier "$app_path")"
  extension_team="$(team_identifier "${system_extensions[0]}")"
  [[ -n "$app_team" && "$app_team" != "not set" ]] || fail \
    "the app is unsigned or ad hoc signed"
  [[ "$extension_team" == "$app_team" ]] || fail \
    "the app and Network System Extension use different signing teams"

  distribution_extract_entitlements "$app_path" "$app_entitlements"
  require_boolean_entitlement "$app_entitlements" "com.apple.developer.accessory-access.usb"
  require_boolean_entitlement "$app_entitlements" "com.apple.developer.system-extension.install"
  require_boolean_entitlement "$app_entitlements" "com.apple.security.virtualization"
  require_array_value "$app_entitlements" \
    "com.apple.developer.networking.networkextension" "packet-tunnel-provider"

  distribution_extract_entitlements "${system_extensions[0]}" "$extension_entitlements"
  require_boolean_entitlement "$extension_entitlements" "com.apple.security.app-sandbox"
  require_boolean_entitlement "$extension_entitlements" "com.apple.security.network.client"
  require_boolean_entitlement "$extension_entitlements" "com.apple.security.network.server"
  require_nonempty_array_value "$extension_entitlements" "com.apple.security.application-groups"
  require_array_value "$extension_entitlements" \
    "com.apple.developer.networking.networkextension" "packet-tunnel-provider"
}

# The app target depends on WireGuardGoBridgemacOS, which invokes the shared
# bridge script with the complete Xcode build environment before linking.
"$XCODEBUILD_BIN" \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

[[ -d "$BUILT_APP" ]] || fail "expected signed app bundle was not produced at $BUILT_APP"
validate_signed_runtime_app "$BUILT_APP"

INSTALL_STAGING_ROOT="$(/usr/bin/mktemp -d /Applications/.ThruRNDIS-install.XXXXXX)" || fail \
  "cannot create an installation staging directory in /Applications"
STAGED_APP="$INSTALL_STAGING_ROOT/$APP_NAME.app"
BACKUP_APP="$INSTALL_STAGING_ROOT/Previous-$APP_NAME.app"

/usr/bin/ditto "$BUILT_APP" "$STAGED_APP"
validate_signed_runtime_app "$STAGED_APP"

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ -e "$INSTALL_APP" ]]; then
  /bin/mv "$INSTALL_APP" "$BACKUP_APP"
  RESTORE_BACKUP=1
fi

/bin/mv "$STAGED_APP" "$INSTALL_APP"
validate_signed_runtime_app "$INSTALL_APP"
RESTORE_BACKUP=0

echo "Installed signed runtime app at $INSTALL_APP"
