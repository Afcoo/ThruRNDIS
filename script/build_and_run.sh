#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ThruRNDIS"
PROJECT_NAME="ThruRNDIS.xcodeproj"
SCHEME_NAME="ThruRNDIS"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/$PROJECT_NAME"
DERIVED_DATA_PATH="${THRURNDIS_DERIVED_DATA_PATH:-/tmp/ThruRNDIS-DerivedData}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
XCODEBUILD_BIN="${THRURNDIS_XCODEBUILD:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild}"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ ! -x "$XCODEBUILD_BIN" ]]; then
  echo "error: Xcode beta xcodebuild not found at $XCODEBUILD_BIN" >&2
  echo "Set THRURNDIS_XCODEBUILD to override the tool path." >&2
  exit 1
fi

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

"$XCODEBUILD_BIN" \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_BUNDLE" || ! -x "$APP_BINARY" ]]; then
  echo "error: expected app bundle was not produced at $APP_BUNDLE" >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..10}; do
      if /usr/bin/pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.5
    done
    echo "error: $APP_NAME did not remain running after launch" >&2
    exit 1
    ;;
esac
