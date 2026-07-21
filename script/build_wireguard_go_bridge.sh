#!/bin/bash

# Xcode Legacy Target entrypoint for building WireGuardKit's libwg-go.a.
# BUILD_DIR and DEVELOPER_BIN_DIR are supplied by Xcode. The script derives the
# SourcePackages checkout from DerivedData because BUILD_DIR has a different
# layout during archive builds than it does during ordinary builds.

set -euo pipefail

if [[ -z "${BUILD_DIR:-}" ]]; then
  echo "error: BUILD_DIR is not set by Xcode" >&2
  exit 1
fi

DERIVED_DATA_PATH="${BUILD_DIR%/Build/*}"
if [[ "$DERIVED_DATA_PATH" == "$BUILD_DIR" ]]; then
  echo "error: cannot derive the DerivedData path from BUILD_DIR: $BUILD_DIR" >&2
  exit 1
fi

WIREGUARD_GO_DIR="$DERIVED_DATA_PATH/SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo"
if [[ ! -f "$WIREGUARD_GO_DIR/Makefile" ]]; then
  echo "error: WireGuardKitGo checkout not found at $WIREGUARD_GO_DIR" >&2
  exit 1
fi

if [[ -z "${CONFIGURATION:-}" || -z "${CONFIGURATION_BUILD_DIR:-}" ]]; then
  echo "error: CONFIGURATION and CONFIGURATION_BUILD_DIR must be set by Xcode" >&2
  exit 1
fi

# GNU Make treats spaces in expanded target paths as separators. Archive paths
# include the scheme name "ThruRNDIS Runtime", so stage outside that path while
# remaining under Xcode's intermediates directory so `xcodebuild clean` removes
# the cached bridge products.
BRIDGE_ROOT="$DERIVED_DATA_PATH/Build/Intermediates.noindex/ThruRNDISWireGuardGoBridge/$CONFIGURATION"
BRIDGE_INTERMEDIATES_DIR="$BRIDGE_ROOT/Intermediates"
BRIDGE_PRODUCTS_DIR="$BRIDGE_ROOT/Products"

MAKE_BIN="${DEVELOPER_BIN_DIR:-}/make"
if [[ -z "${DEVELOPER_BIN_DIR:-}" || ! -x "$MAKE_BIN" ]]; then
  MAKE_BIN="$(/usr/bin/xcrun --find make)"
fi
if [[ ! -x "$MAKE_BIN" ]]; then
  echo "error: make executable not found at $MAKE_BIN" >&2
  exit 1
fi

MAKE_ARGS=(
  -C "$WIREGUARD_GO_DIR"
  "CONFIGURATION_TEMP_DIR=$BRIDGE_INTERMEDIATES_DIR"
  "CONFIGURATION_BUILD_DIR=$BRIDGE_PRODUCTS_DIR"
  "BUILDDIR=$BRIDGE_INTERMEDIATES_DIR/wireguard-go-bridge"
  "DESTDIR=$BRIDGE_PRODUCTS_DIR"
)
if [[ -n "${ACTION:-}" ]]; then
  MAKE_ARGS+=("$ACTION")
fi

"$MAKE_BIN" "${MAKE_ARGS[@]}"

if [[ "${ACTION:-}" == "clean" ]]; then
  exit 0
fi

BUILT_LIBRARY="$BRIDGE_PRODUCTS_DIR/libwg-go.a"
if [[ ! -f "$BUILT_LIBRARY" ]]; then
  echo "error: WireGuardGo library was not produced at $BUILT_LIBRARY" >&2
  exit 1
fi

/bin/mkdir -p "$CONFIGURATION_BUILD_DIR"
/bin/cp -f "$BUILT_LIBRARY" "$CONFIGURATION_BUILD_DIR/libwg-go.a"
