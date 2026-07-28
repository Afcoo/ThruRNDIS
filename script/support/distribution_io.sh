#!/usr/bin/env bash

# Shared artifact-path and disk-image helpers for the distribution entrypoints.
# Source distribution_common.sh before this file so failures use the common
# distribution error path.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "error: distribution_io.sh must be sourced by a project script" >&2
  exit 2
fi
if ! declare -F distribution_fail >/dev/null; then
  echo "error: distribution_common.sh must be sourced before distribution_io.sh" >&2
  exit 2
fi

distribution_resolve_new_output_path() {
  local output_path="$1"
  local expected_name="$2"
  local output_label="$3"
  local output_parent

  [[ -n "$output_path" && "$output_path" != */ ]] || distribution_fail \
    "$output_label must name a path"
  [[ "$(/usr/bin/basename "$output_path")" == "$expected_name" ]] || distribution_fail \
    "$output_label must be named $expected_name: $output_path"

  output_parent="$(/usr/bin/dirname "$output_path")"
  /bin/mkdir -p "$output_parent"
  output_parent="$(cd "$output_parent" && /bin/pwd -P)"
  [[ "$output_parent" != "/" ]] || distribution_fail \
    "$output_label parent cannot be /"
  output_path="$output_parent/$expected_name"
  [[ ! -e "$output_path" && ! -L "$output_path" ]] || distribution_fail \
    "$output_label already exists at $output_path"

  /usr/bin/printf '%s\n' "$output_path"
}

distribution_detach_disk_image() {
  local device="$1"
  local attempt

  for attempt in 1 2 3; do
    if /usr/bin/hdiutil detach "$device" >/dev/null; then
      return 0
    fi
    /bin/sleep 1
  done
  return 1
}

distribution_attach_disk_image() {
  local access_mode="$1"
  local image_path="$2"
  local mount_path="$3"
  local output_variable="$4"
  local attach_output
  local device

  [[ "$access_mode" == "-readonly" || "$access_mode" == "-readwrite" ]] || \
    distribution_fail "unsupported disk-image access mode: $access_mode"
  [[ "$output_variable" =~ ^[A-Za-z_][0-9A-Za-z_]*$ ]] || distribution_fail \
    "disk-image output variable name is unsafe: $output_variable"
  attach_output="$(/usr/bin/hdiutil attach \
    "$access_mode" \
    -nobrowse \
    -noautoopen \
    -mountpoint "$mount_path" \
    "$image_path")"
  device="$(/usr/bin/printf '%s\n' "$attach_output" | /usr/bin/awk '
    /^\/dev\// && !device { device = $1 }
    END { print device }
  ')"
  if [[ "$device" != /dev/disk* ]]; then
    /usr/bin/hdiutil detach "$mount_path" >/dev/null 2>&1 || true
    distribution_fail "could not determine the device for mounted image $image_path"
  fi

  # -v is provided by Bash's printf builtin, not by macOS /usr/bin/printf.
  if ! printf -v "$output_variable" '%s' "$device"; then
    distribution_detach_disk_image "$device" >/dev/null 2>&1 || true
    distribution_fail "could not store the device for mounted image $image_path"
  fi
}
