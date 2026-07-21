#!/usr/bin/env bash

# Shared requirements for the distribution validation helpers:
# - Run on macOS with Xcode command-line tools available through xcrun.
# - The input app must contain exactly one Network System Extension and must be
#   signed with a timestamped Developer ID Application identity.
# - The app and extension must carry the direct-distribution entitlements
#   declared by this project. These helpers validate artifacts; they never sign
#   an app or mutate one. The generic entitlement extractor is also reused by
#   the signed RuntimeDebug installer.
#
# This file is a sourced library. Run build_and_install.sh, package_app.sh,
# build_and_notarize_app.sh, build_and_notarize_dmg.sh,
# verify_notarized_app.sh, or verify_notarized_dmg.sh instead.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "error: distribution_common.sh must be sourced by a project script" >&2
  exit 2
fi

distribution_fail() {
  echo "error: $*" >&2
  exit 1
}

distribution_build_setting_value() {
  local build_settings="$1"
  local setting_name="$2"

  /usr/bin/printf '%s\n' "$build_settings" | /usr/bin/awk -v setting_name="$setting_name" '
    index($0, setting_name " = ") && !found {
      value = $0
      sub("^[[:space:]]*" setting_name "[[:space:]]*=[[:space:]]*", "", value)
      print value
      found = 1
    }
  '
}

distribution_extract_entitlements() {
  local bundle_path="$1"
  local output_path="$2"
  local der_diagnostics
  local der_path
  local extraction_succeeded=0
  local temporary_directory
  local temporary_output_path
  local xml_diagnostics

  if ! temporary_directory="$(/usr/bin/mktemp -d \
    /tmp/ThruRNDIS-entitlements.XXXXXX)"; then
    distribution_fail "could not create a temporary directory for entitlement extraction"
  fi
  der_diagnostics="$temporary_directory/der-diagnostics.txt"
  der_path="$temporary_directory/entitlements.der"
  temporary_output_path="$temporary_directory/entitlements.plist"
  xml_diagnostics="$temporary_directory/xml-diagnostics.txt"

  if /usr/bin/codesign -d \
      --entitlements "$temporary_output_path" \
      --xml \
      "$bundle_path" 2>"$xml_diagnostics" &&
      [[ -s "$temporary_output_path" ]] &&
      /usr/bin/plutil -lint "$temporary_output_path" \
        >/dev/null 2>>"$xml_diagnostics"; then
    extraction_succeeded=1
  else
    /bin/rm -f "$temporary_output_path"
    if /usr/bin/codesign -d \
        --entitlements "$der_path" \
        --der \
        "$bundle_path" 2>"$der_diagnostics" &&
        [[ -s "$der_path" ]] &&
        /usr/bin/derq query \
          -i "$der_path" \
          -o "$temporary_output_path" \
          --xml 2>>"$der_diagnostics" &&
        [[ -s "$temporary_output_path" ]] &&
        /usr/bin/plutil -lint "$temporary_output_path" \
          >/dev/null 2>>"$der_diagnostics"; then
      extraction_succeeded=1
    fi
  fi

  if [[ "$extraction_succeeded" -ne 1 ]]; then
    [[ ! -s "$xml_diagnostics" ]] || /bin/cat "$xml_diagnostics" >&2
    [[ ! -s "$der_diagnostics" ]] || /bin/cat "$der_diagnostics" >&2
    /bin/rm -f \
      "$temporary_output_path" \
      "$der_path" \
      "$xml_diagnostics" \
      "$der_diagnostics"
    /bin/rmdir "$temporary_directory" 2>/dev/null || true
    distribution_fail "could not extract valid entitlements from $bundle_path"
  fi

  if ! /bin/mv -f "$temporary_output_path" "$output_path"; then
    /bin/rm -f \
      "$temporary_output_path" \
      "$der_path" \
      "$xml_diagnostics" \
      "$der_diagnostics"
    /bin/rmdir "$temporary_directory" 2>/dev/null || true
    distribution_fail "could not write extracted entitlements to $output_path"
  fi

  /bin/rm -f "$der_path" "$xml_diagnostics" "$der_diagnostics"
  /bin/rmdir "$temporary_directory" 2>/dev/null || true
}

distribution_require_boolean_entitlement() {
  local entitlements_path="$1"
  local entitlement_name="$2"
  local entitlement_value

  entitlement_value="$(/usr/libexec/PlistBuddy \
    -c "Print :$entitlement_name" "$entitlements_path" 2>/dev/null || true)"
  [[ "$entitlement_value" == "true" ]] || distribution_fail \
    "required boolean entitlement is missing or false: $entitlement_name"
}

distribution_require_exact_array_value() {
  local entitlements_path="$1"
  local entitlement_name="$2"
  local expected_value="$3"
  local entitlement_json
  local escaped_key_path
  local expected_json

  escaped_key_path="${entitlement_name//./\\.}"
  entitlement_json="$(/usr/bin/plutil \
    -extract "$escaped_key_path" json -o - "$entitlements_path" 2>/dev/null || true)"
  expected_json="[\"$expected_value\"]"
  [[ "$entitlement_json" == "$expected_json" ]] || distribution_fail \
    "entitlement must contain exactly one value: $entitlement_name = $expected_value"
}

distribution_reject_true_entitlement() {
  local entitlements_path="$1"
  local entitlement_name="$2"
  local entitlement_value

  entitlement_value="$(/usr/libexec/PlistBuddy \
    -c "Print :$entitlement_name" "$entitlements_path" 2>/dev/null || true)"
  [[ "$entitlement_value" != "true" ]] || distribution_fail \
    "distribution app must not enable entitlement: $entitlement_name"
}

distribution_team_identifier() {
  /usr/bin/codesign -dvvv "$1" 2>&1 | /usr/bin/awk '
    /^TeamIdentifier=/ && !found {
      sub(/^TeamIdentifier=/, "")
      print
      found = 1
    }
  '
}

distribution_leaf_signing_authority() {
  /usr/bin/codesign -dvvv "$1" 2>&1 | /usr/bin/awk '
    /^Authority=/ && !found {
      sub(/^Authority=/, "")
      print
      found = 1
    }
  '
}

distribution_validate_developer_id_requirement() {
  local signed_path="$1"
  local expected_team="$2"
  local requirement

  requirement="anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$expected_team\""
  /usr/bin/codesign \
    --verify \
    --strict \
    --verbose=2 \
    -R="$requirement" \
    "$signed_path"
}

distribution_validate_app() {
  local app_path="$1"
  local validation_dir="$2"
  local expected_team="${3:-}"
  local configured_app_group="${4:-}"
  local system_extensions_dir="$app_path/Contents/Library/SystemExtensions"
  local app_entitlements="$validation_dir/app-entitlements.plist"
  local extension_entitlements="$validation_dir/extension-entitlements.plist"
  local app_authority
  local app_bundle_identifier
  local app_build
  local app_signing_details
  local app_team
  local app_version
  local application_identifier_prefix
  local application_identifier_suffix
  local expected_app_group
  local expected_extension_bundle_identifier
  local expected_mach_service
  local extension_authority
  local extension_application_identifier
  local extension_bundle_identifier
  local extension_build
  local extension_info_plist
  local extension_signing_details
  local extension_team
  local extension_version
  local system_extensions

  [[ -d "$app_path" ]] || distribution_fail "app bundle not found at $app_path"
  /bin/mkdir -p "$validation_dir"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

  shopt -s nullglob
  system_extensions=("$system_extensions_dir"/*.systemextension)
  shopt -u nullglob
  [[ "${#system_extensions[@]}" -eq 1 ]] || distribution_fail \
    "expected exactly one embedded Network System Extension in $system_extensions_dir"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "${system_extensions[0]}"

  app_authority="$(distribution_leaf_signing_authority "$app_path")"
  extension_authority="$(distribution_leaf_signing_authority "${system_extensions[0]}")"
  [[ "$app_authority" == "Developer ID Application:"* ]] || distribution_fail \
    "the app is not signed with Developer ID Application: $app_authority"
  [[ "$extension_authority" == "Developer ID Application:"* ]] || distribution_fail \
    "the Network System Extension is not signed with Developer ID Application: $extension_authority"

  app_team="$(distribution_team_identifier "$app_path")"
  extension_team="$(distribution_team_identifier "${system_extensions[0]}")"
  [[ -n "$app_team" && "$app_team" != "not set" ]] || distribution_fail \
    "the app has no signing team"
  [[ "$extension_team" == "$app_team" ]] || distribution_fail \
    "the app and Network System Extension use different signing teams"
  if [[ -n "$expected_team" && "$app_team" != "$expected_team" ]]; then
    distribution_fail "the app is signed for team $app_team instead of $expected_team"
  fi
  distribution_validate_developer_id_requirement "$app_path" "$app_team"
  distribution_validate_developer_id_requirement "${system_extensions[0]}" "$app_team"

  app_bundle_identifier="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
  app_version="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
  app_build="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
  extension_info_plist="${system_extensions[0]}/Contents/Info.plist"
  extension_bundle_identifier="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' "$extension_info_plist")"
  extension_version="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' "$extension_info_plist")"
  extension_build="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' "$extension_info_plist")"
  expected_extension_bundle_identifier="$app_bundle_identifier.network-extension"
  [[ "$extension_bundle_identifier" == "$expected_extension_bundle_identifier" ]] || distribution_fail \
    "the Network System Extension bundle ID is $extension_bundle_identifier instead of $expected_extension_bundle_identifier"
  [[ "${system_extensions[0]##*/}" == "$extension_bundle_identifier.systemextension" ]] || distribution_fail \
    "the Network System Extension filename does not match its bundle ID: ${system_extensions[0]}"
  [[ "$extension_version" == "$app_version" && "$extension_build" == "$app_build" ]] || distribution_fail \
    "the app and Network System Extension have different version/build values"

  app_signing_details="$(/usr/bin/codesign -dvvv "$app_path" 2>&1)"
  extension_signing_details="$(/usr/bin/codesign -dvvv "${system_extensions[0]}" 2>&1)"
  /usr/bin/printf '%s\n' "$app_signing_details" | \
    /usr/bin/grep -Eq '^CodeDirectory .*\(runtime\)' || distribution_fail \
    "the app does not enable the hardened runtime"
  /usr/bin/printf '%s\n' "$app_signing_details" | \
    /usr/bin/grep -q '^Timestamp=' || distribution_fail \
    "the app signature has no secure timestamp"
  /usr/bin/printf '%s\n' "$extension_signing_details" | \
    /usr/bin/grep -Eq '^CodeDirectory .*\(runtime\)' || distribution_fail \
    "the Network System Extension does not enable the hardened runtime"
  /usr/bin/printf '%s\n' "$extension_signing_details" | \
    /usr/bin/grep -q '^Timestamp=' || distribution_fail \
    "the Network System Extension signature has no secure timestamp"

  distribution_extract_entitlements "$app_path" "$app_entitlements"
  distribution_require_boolean_entitlement \
    "$app_entitlements" "com.apple.developer.accessory-access.usb"
  distribution_require_boolean_entitlement \
    "$app_entitlements" "com.apple.developer.system-extension.install"
  distribution_require_boolean_entitlement \
    "$app_entitlements" "com.apple.security.virtualization"
  distribution_require_exact_array_value \
    "$app_entitlements" \
    "com.apple.developer.networking.networkextension" \
    "packet-tunnel-provider-systemextension"
  distribution_reject_true_entitlement \
    "$app_entitlements" "com.apple.security.get-task-allow"

  distribution_extract_entitlements "${system_extensions[0]}" "$extension_entitlements"
  distribution_require_boolean_entitlement \
    "$extension_entitlements" "com.apple.security.app-sandbox"
  distribution_require_boolean_entitlement \
    "$extension_entitlements" "com.apple.security.network.client"
  distribution_require_boolean_entitlement \
    "$extension_entitlements" "com.apple.security.network.server"
  extension_application_identifier="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.application-identifier' "$extension_entitlements" 2>/dev/null || true)"
  application_identifier_suffix=".$extension_bundle_identifier"
  [[ "$extension_application_identifier" == *"$application_identifier_suffix" ]] || distribution_fail \
    "the Network System Extension application identifier does not match its bundle ID"
  application_identifier_prefix="${extension_application_identifier%"$application_identifier_suffix"}"
  [[ -n "$application_identifier_prefix" ]] || distribution_fail \
    "the Network System Extension application identifier has no prefix"
  expected_app_group="$application_identifier_prefix.group.$app_bundle_identifier"
  if [[ -n "$configured_app_group" && "$configured_app_group" != "$expected_app_group" ]]; then
    distribution_fail \
      "the signed WireGuard application group $expected_app_group does not match artifact metadata $configured_app_group"
  fi
  distribution_require_exact_array_value \
    "$extension_entitlements" \
    "com.apple.security.application-groups" \
    "$expected_app_group"
  distribution_require_exact_array_value \
    "$extension_entitlements" \
    "com.apple.developer.networking.networkextension" \
    "packet-tunnel-provider-systemextension"
  distribution_reject_true_entitlement \
    "$extension_entitlements" "com.apple.security.get-task-allow"

  expected_mach_service="$expected_app_group.network-extension"
  [[ "$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEMachServiceName' "$extension_info_plist")" == "$expected_mach_service" ]] || distribution_fail \
    "the Network System Extension NEMachServiceName does not match its application group"
}

distribution_run_notary_submission_preflight() {
  local app_path="$1"
  local check_output
  local check_status
  local full_error_count

  set +e
  check_output="$(/usr/bin/syspolicy_check notary-submission "$app_path" --verbose 2>&1)"
  check_status=$?
  set -e

  /usr/bin/printf '%s\n' "$check_output"
  [[ "$check_status" -eq 0 ]] && return 0

  full_error_count="$(/usr/bin/printf '%s\n' "$check_output" | /usr/bin/awk '
    /Full Error:/ { count += 1 }
    END { print count + 0 }
  ')"

  # macOS 27 beta can report the expected pre-notarization Gatekeeper result
  # as one generic Codesign Error after every concrete local check passed.
  if [[ "$full_error_count" -eq 1 &&
        "$check_output" == *"Passed developer ID certificate check"* &&
        "$check_output" == *"Passed xptool"* &&
        "$check_output" == *"Passed amfi_preflight"* &&
        "$check_output" == *"Passed dual signature check"* &&
        "$check_output" == *"Codesign Error"* &&
        "$check_output" == *"Gatekeeper rejected this file"* ]]; then
    echo "warning: ignoring the generic macOS 27 beta pre-notarization Gatekeeper rejection" >&2
    echo "warning: continuing to the authoritative Apple notary service validation" >&2
    return 0
  fi

  distribution_fail "syspolicy_check notary-submission failed"
}

distribution_validate_notarized_app() {
  local app_path="$1"
  local validation_dir="$2"
  local expected_team="${3:-}"
  local expected_app_group="${4:-}"

  distribution_validate_app \
    "$app_path" "$validation_dir" "$expected_team" "$expected_app_group"
  /usr/bin/xcrun stapler validate -v "$app_path"
  /usr/bin/syspolicy_check distribution "$app_path" --verbose
}

distribution_validate_notary_credentials() {
  local keychain_profile="$1"

  [[ -n "$keychain_profile" ]] || distribution_fail \
    "THRURNDIS_NOTARY_KEYCHAIN_PROFILE must not be empty"
  echo "Validating notary credentials in Keychain profile '$keychain_profile'..."
  if ! /usr/bin/xcrun notarytool history \
    --keychain-profile "$keychain_profile" \
    --output-format json >/dev/null; then
    distribution_fail \
      "notary credentials are unavailable; store them with: xcrun notarytool store-credentials \"$keychain_profile\""
  fi
}

distribution_require_safe_filename_component() {
  local label="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || distribution_fail \
    "$label is unsafe for a distribution filename: $value"
}

distribution_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

distribution_write_app_content_manifest() {
  local app_path="$1"
  local output_path="$2"

  (
    cd "$app_path"
    /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort | while IFS= read -r relative_path; do
      /usr/bin/printf 'file\t%s\t%s\n' \
        "$(/usr/bin/shasum -a 256 "$relative_path" | /usr/bin/awk '{ print $1 }')" \
        "$relative_path"
    done
    /usr/bin/find . -type l -print | LC_ALL=C /usr/bin/sort | while IFS= read -r relative_path; do
      /usr/bin/printf 'link\t%s\t%s\n' \
        "$(/usr/bin/readlink "$relative_path")" \
        "$relative_path"
    done
  ) >"$output_path"
}

distribution_write_app_fingerprint() {
  local app_path="$1"
  local output_path="$2"

  /usr/sbin/mtree \
    -c \
    -n \
    -p "$app_path" \
    -k 'type,mode,size,link,sha256digest,xattrsdigest' >"$output_path"
}

distribution_compare_app_contents() {
  local expected_app="$1"
  local actual_app="$2"
  local validation_dir="$3"
  local expected_manifest="$validation_dir/expected-app-contents.txt"
  local actual_manifest="$validation_dir/actual-app-contents.txt"

  /bin/mkdir -p "$validation_dir"
  distribution_write_app_content_manifest "$expected_app" "$expected_manifest"
  distribution_write_app_content_manifest "$actual_app" "$actual_manifest"
  /usr/bin/cmp -s "$expected_manifest" "$actual_manifest" || distribution_fail \
    "the app contents changed while being copied into the DMG"
}

distribution_resolve_app_icon() {
  local app_path="$1"
  local icon_name
  local icon_path

  icon_name="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIconFile' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
  [[ -n "$icon_name" ]] || distribution_fail \
    "CFBundleIconFile is missing from the built app"
  [[ "$icon_name" != */* && "$icon_name" != "." && "$icon_name" != ".." ]] || distribution_fail \
    "CFBundleIconFile is not a safe resource name: $icon_name"
  if [[ "$icon_name" != *.icns ]]; then
    icon_name="$icon_name.icns"
  fi

  icon_path="$app_path/Contents/Resources/$icon_name"
  [[ -f "$icon_path" ]] || distribution_fail "built app icon not found at $icon_path"
  /usr/bin/printf '%s\n' "$icon_path"
}

distribution_validate_dmg_signature() {
  local dmg_path="$1"
  local expected_team="$2"
  local dmg_authority
  local dmg_signing_details
  local dmg_team

  /usr/bin/codesign --verify --strict --verbose=2 "$dmg_path"
  dmg_authority="$(distribution_leaf_signing_authority "$dmg_path")"
  dmg_team="$(distribution_team_identifier "$dmg_path")"
  [[ "$dmg_authority" == "Developer ID Application:"* ]] || distribution_fail \
    "the DMG is not signed with Developer ID Application: $dmg_authority"
  [[ "$dmg_team" == "$expected_team" ]] || distribution_fail \
    "the DMG is signed for team $dmg_team instead of $expected_team"
  distribution_validate_developer_id_requirement "$dmg_path" "$expected_team"
  dmg_signing_details="$(/usr/bin/codesign -dvvv "$dmg_path" 2>&1)"
  /usr/bin/printf '%s\n' "$dmg_signing_details" | \
    /usr/bin/grep -q '^Timestamp=' || distribution_fail \
    "the DMG signature has no secure timestamp"
}
