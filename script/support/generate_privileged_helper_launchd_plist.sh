#!/usr/bin/env bash
set -euo pipefail

PLACEHOLDER="__THRURNDIS_PRIVILEGED_HELPER_BUNDLE_IDENTIFIER__"
OUTPUT_NAME="ThruRNDISPrivilegedHelper.plist"
EXPECTED_BUNDLE_PROGRAM="Contents/MacOS/ThruRNDISPrivilegedHelper"

fail() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMPORARY_OUTPUT:-}" ]]; then
    case "$TEMPORARY_OUTPUT" in
      "${OUTPUT_DIRECTORY:-}"/.ThruRNDISPrivilegedHelper.plist.*)
        /bin/rm -f "$TEMPORARY_OUTPUT"
        ;;
    esac
  fi
}

trap cleanup EXIT

if [[ $# -ne 3 ]]; then
  echo "usage: $0 TEMPLATE_PATH OUTPUT_PATH HELPER_BUNDLE_IDENTIFIER" >&2
  exit 2
fi

TEMPLATE_PATH="$1"
OUTPUT_PATH="$2"
HELPER_BUNDLE_IDENTIFIER="$3"

[[ -n "${TARGET_BUILD_DIR:-}" && "$TARGET_BUILD_DIR" == /* ]] || fail \
  "TARGET_BUILD_DIR must be an absolute Xcode build directory"
[[ -n "${WRAPPER_NAME:-}" && "$WRAPPER_NAME" != */* &&
   "$WRAPPER_NAME" != "." && "$WRAPPER_NAME" != ".." ]] || fail \
  "WRAPPER_NAME must be a safe app bundle name"
EXPECTED_OUTPUT_PATH="${TARGET_BUILD_DIR%/}/$WRAPPER_NAME/Contents/Library/LaunchDaemons/$OUTPUT_NAME"
[[ "$OUTPUT_PATH" == "$EXPECTED_OUTPUT_PATH" ]] || fail \
  "refusing launchd plist output outside the configured app bundle: $OUTPUT_PATH"
if [[ -n "${SCRIPT_OUTPUT_FILE_0:-}" && "$OUTPUT_PATH" != "$SCRIPT_OUTPUT_FILE_0" ]]; then
  fail "launchd plist output does not match SCRIPT_OUTPUT_FILE_0"
fi

[[ "$HELPER_BUNDLE_IDENTIFIER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ &&
   "$HELPER_BUNDLE_IDENTIFIER" == *.* &&
   "$HELPER_BUNDLE_IDENTIFIER" != *..* &&
   "$HELPER_BUNDLE_IDENTIFIER" == *.privileged-helper ]] || fail \
  "unsafe privileged-helper bundle identifier: $HELPER_BUNDLE_IDENTIFIER"
[[ "$TEMPLATE_PATH" == /* && -f "$TEMPLATE_PATH" && ! -L "$TEMPLATE_PATH" ]] || fail \
  "launchd plist template must be an absolute, regular file: $TEMPLATE_PATH"
[[ "$OUTPUT_PATH" == /* && "${OUTPUT_PATH##*/}" == "$OUTPUT_NAME" ]] || fail \
  "launchd plist output must be an absolute path ending in $OUTPUT_NAME"
[[ ! -L "$OUTPUT_PATH" ]] || fail \
  "refusing to replace a symbolic-link launchd plist output: $OUTPUT_PATH"

OUTPUT_DIRECTORY="$(/usr/bin/dirname "$OUTPUT_PATH")"
[[ -d "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || fail \
  "launchd plist output directory must already exist and must not be a symbolic link: $OUTPUT_DIRECTORY"

PLACEHOLDER_COUNT="$(/usr/bin/awk -v placeholder="$PLACEHOLDER" '
  {
    line = $0
    while ((position = index(line, placeholder)) != 0) {
      count += 1
      line = substr(line, position + length(placeholder))
    }
  }
  END { print count + 0 }
' "$TEMPLATE_PATH")"
[[ "$PLACEHOLDER_COUNT" -eq 2 ]] || fail \
  "launchd plist template must contain $PLACEHOLDER exactly once for Label and once for MachServices"

TEMPORARY_OUTPUT="$(/usr/bin/mktemp \
  "$OUTPUT_DIRECTORY/.ThruRNDISPrivilegedHelper.plist.XXXXXX")"
/usr/bin/awk \
  -v placeholder="$PLACEHOLDER" \
  -v replacement="$HELPER_BUNDLE_IDENTIFIER" '
    {
      gsub(placeholder, replacement)
      print
    }
  ' "$TEMPLATE_PATH" >"$TEMPORARY_OUTPUT"

if /usr/bin/grep -Fq "$PLACEHOLDER" "$TEMPORARY_OUTPUT"; then
  fail "privileged-helper bundle identifier placeholder was not replaced"
fi
/usr/bin/plutil -lint "$TEMPORARY_OUTPUT" >/dev/null || fail \
  "generated privileged-helper launchd plist is invalid"

LABEL="$(/usr/bin/plutil \
  -extract Label raw -expect string -o - "$TEMPORARY_OUTPUT" \
  2>/dev/null || true)"
[[ "$LABEL" == "$HELPER_BUNDLE_IDENTIFIER" ]] || fail \
  "generated launchd Label is $LABEL instead of $HELPER_BUNDLE_IDENTIFIER"
BUNDLE_PROGRAM="$(/usr/bin/plutil \
  -extract BundleProgram raw -expect string -o - "$TEMPORARY_OUTPUT" \
  2>/dev/null || true)"
[[ "$BUNDLE_PROGRAM" == "$EXPECTED_BUNDLE_PROGRAM" ]] || fail \
  "generated launchd BundleProgram is $BUNDLE_PROGRAM instead of $EXPECTED_BUNDLE_PROGRAM"
MACH_SERVICES_KEYS="$(/usr/bin/plutil \
  -extract MachServices raw -expect dictionary -o - "$TEMPORARY_OUTPUT" \
  2>/dev/null || true)"
[[ "$MACH_SERVICES_KEYS" == "$HELPER_BUNDLE_IDENTIFIER" ]] || fail \
  "generated launchd MachServices must contain only $HELPER_BUNDLE_IDENTIFIER"
ESCAPED_HELPER_BUNDLE_IDENTIFIER="${HELPER_BUNDLE_IDENTIFIER//./\.}"
MACH_SERVICE_VALUE="$(/usr/bin/plutil \
  -extract "MachServices.$ESCAPED_HELPER_BUNDLE_IDENTIFIER" \
  raw -expect bool -o - "$TEMPORARY_OUTPUT" 2>/dev/null || true)"
[[ "$MACH_SERVICE_VALUE" == "true" ]] || fail \
  "generated launchd MachServices entry must enable $HELPER_BUNDLE_IDENTIFIER"

/bin/chmod 0644 "$TEMPORARY_OUTPUT"
/bin/mv -f "$TEMPORARY_OUTPUT" "$OUTPUT_PATH"
TEMPORARY_OUTPUT=""
