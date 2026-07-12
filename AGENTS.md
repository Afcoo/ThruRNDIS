# AGENTS.md

This repository is a macOS 27+ USB RNDIS tethering VM project. Future agents
should read this file before the README and treat the current
WireGuard-over-VZNAT architecture as the baseline.

## Project Shape

- The app is a menu-bar utility with an AppKit `NSStatusItem`, not a Dock app or
  CLI `main.swift` entrypoint. It has no primary `WindowGroup`; SwiftUI provides
  the Settings scene, while a small AppKit window controller presents
  first-run onboarding.
- The Xcode project is `RNDIS Tethering VM Passthrough.xcodeproj`.
- The main app target is `RTPVM` and builds a macOS app bundle.
- There is no host packet-tunnel extension target. The app does not create a
  host VPN, and does not inspect or forward packet payloads.
- Linux assets are not bundled. Users load the generated asset folder or select
  the kernel, initramfs, and raw disk image from the app UI.

## Architecture

- `TetheringStore` owns SwiftUI-facing app state, WireGuard configuration state,
  onboarding/preferences, USB approval workflow, and the console/event logs. VM
  lifecycle work belongs in `VMCoordinator`; USB AccessoryAccess selection and
  passthrough policy belong in `USBAccessoryCoordinator`.
- `AppDelegate` owns the shared `TetheringStore`, starts AccessoryAccess
  monitoring at app launch, and connects AppKit presentation to store state.
  `MenuBarController` owns only the native status item/menu and forwards all
  actions into the store.
- `WireGuardConfStore` owns the app-local WireGuard directory and creates the
  server/client private-key files on first launch. `WireGuardConfBuilder`
  accepts editable configuration elements, uses defaults for now, generates
  `Shared/wg0.conf`, and renders the client configuration for preview/export.
  Neither type reads WireGuard configuration from the selected VM asset tree or
  hard-codes key material.
- `VMConfigurationFactory` builds the Linux VM configuration. The current
  baseline uses `VZLinuxBootLoader`, raw disk attachment, an XHCI USB
  controller, `VZNATNetworkDeviceAttachment`, and
  `VZVirtioFileSystemDeviceConfiguration(tag: "rtpvm-wireguard")`. Its
  `VZSharedDirectory(readOnly: true)` points only at `WireGuard/Shared/`.
- USB passthrough must stay on the public API path that passes an
  AccessoryAccess `AAUSBAccessory` into
  `VZUSBPassthroughDeviceConfiguration(device:)`.
- The guest owns packet forwarding by running a normal WireGuard peer on the
  Virtualization NAT private network and masquerading WireGuard client traffic
  out the USB RNDIS interface.
- The host side is intentionally manual: users configure the host WireGuard
  client from the generated client `.conf`. The official WireGuard macOS client
  currently has a connection bring-up issue in this validation flow; recommend
  `wireguard-go` for macOS validation. This app must not start, stop, or manage
  the host WireGuard tunnel.

## Data Path

The current baseline data path is:

```text
macOS WireGuard client
-> VZNAT guest endpoint UDP/<ListenPort>
-> guest wg0
-> guest nftables masquerade
-> USB RNDIS upstream
```

- The current manual WireGuard test addresses are guest `10.100.0.1/24` and
  macOS host tunnel `10.100.0.2/24`; the guest peer should allow
  `10.100.0.2/32`.
  This is the WireGuard overlay address, not the guest `usb0` RNDIS DHCP
  address.
- The app's default server configuration listens on UDP port `51820`, but the
  guest reads `ListenPort` from the runtime configuration instead of baking a
  port into the VM assets. The app parses
  `RTPVM_WG_ENDPOINT=<guest-nat-ip>:<listen-port>` from serial console output.
- WireGuard configuration lives under
  `~/Library/Application Support/<bundle-id>/WireGuard/`: `wg-server.key` and
  `wg-client.key` are the persistent private-key sources, while the generated
  guest server file is `Shared/wg0.conf`. Directories use mode `0700` and files
  use mode `0600`. Only `Shared/` is shared with the VM, so `wg-client.key`
  never crosses the VirtioFS boundary.
- If both key files are absent, `WireGuardConfStore` generates server/client
  X25519 keys with CryptoKit. If only one key is missing or either key is
  malformed, it reports an error without replacing the existing key.
  `WireGuardConfBuilder` derives both public keys and atomically regenerates
  `Shared/wg0.conf` from the keys and current configuration elements. The
  client `.conf` is not stored in Application Support; it is rendered on
  demand. Existing asset configurations are ignored and are not migrated.
  `PresharedKey` is not part of the current configuration format.
- BusyBox `init` runs `init-virtiofs-wgconf` as a `::wait` action between
  `init-rndis` and `init-network`. It mounts the `rtpvm-wireguard` VirtioFS tag
  read-only at `/run/rtpvm-wireguard` and verifies that `wg0.conf` exists and
  is nonempty. `init-network` starts the interface directly from the shared
  config with `wg-quick`; host file changes do not alter an already-running
  interface and take effect on the next VM start.
- The app-generated client `.conf` acts as a WireGuard client and uses
  `<RTPVM_WG_ENDPOINT>` as a placeholder for the discovered guest VZNAT address.
  The client `.conf` uses IPv4 full-tunnel routing with
  `AllowedIPs = 10.100.0.0/24, 0.0.0.0/1, 128.0.0.0/1`. Keep the explicit
  overlay route so `10.100.0.1` remains reachable, and prefer split internet
  routes over `0.0.0.0/0` on macOS to avoid a bad `wg-quick` direct route over
  the VZNAT endpoint. IPv6 tunneling remains out of scope until RNDIS IPv6 is
  tested.
- The BusyBox init network one-shot brings up the VZNAT NIC `eth0`, runs
  `udhcpc`, reads the endpoint port from the runtime server configuration, and
  derives the source policy-routing prefix from the connected IPv4 CIDR on the
  active `wg0` interface. WireGuard port and overlay CIDR are not generated into
  the asset bundle.
- The guest RNDIS interface is fixed to `usb0`. The app supports one
  passthrough RNDIS accessory per VM session. A newly available AccessoryAccess
  device is never attached silently: the app asks the user first, starts the VM
  on approval if needed, and then attaches it. Replacing the session device
  requires detaching the old device and restarting the VM. An unexpected
  detach also restarts the VM so a different device is never hot-attached into
  the old guest session.
- Guest NAT is based on `nftables` masquerade from `wg0` traffic to `usb0`.
- The setup NAT NIC provides the private host-to-guest network used for the
  WireGuard endpoint. Do not
  replace it with vmnet, bridged networking, route-command UI, or a host-side
  packet-tunnel provider.

## Directory Guide

- `RTPVM/App`: SwiftUI app entrypoint, AppKit menu-bar controller, and
  onboarding window controller.
- `RTPVM/Views`: setup, USB, console, and WireGuard views.
- `RTPVM/Coordinators`: `VMCoordinator` for Virtualization VM lifecycle and
  `USBAccessoryCoordinator` for AccessoryAccess USB selection/passthrough
  policy.
- `RTPVM/Stores`: `TetheringStore` orchestration and SwiftUI-facing app state.
- `RTPVM/Services`: `USBAccessoryMonitor`, VM configuration
  factory, and VM delegate glue.
- `RTPVM/Support`: file picker, clipboard, runtime entitlement reader helpers,
  `WireGuardConfStore` key creation/validation, and `WireGuardConfBuilder`
  server/client configuration rendering.
- `RTPVM/GuestScripts`: currently empty. Guest boot scripts are sourced from
  `script/initramfs`; no WireGuard configuration or private key is bundled in
  the generated initramfs.
- `RTPVM/Models`: USB accessory records and approval prompts, VM state, and
  WireGuard settings.
- `script`: local build/run/debug/verify entrypoints and Alpine asset
  generation.
- `script/initramfs`: source files copied into the generated initramfs for
  BusyBox init, including `rcS`, `init-rndis`, `init-virtiofs-wgconf`,
  `init-network`, and `init-console`.

## Build And Run

- Local compile/UI iteration should not treat signing as the default blocker.
- Default run:

```sh
./script/build_and_run.sh
```

- The default script builds the `RNDIS Tethering VM Passthrough` scheme,
  `Debug` configuration, with `CODE_SIGNING_ALLOWED=NO`, then opens the app.
- For direct builds, prefer the Xcode beta `xcodebuild`:

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project "RNDIS Tethering VM Passthrough.xcodeproj" \
  -scheme "RNDIS Tethering VM Passthrough" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/RTPVM-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

- Runtime signing checks are meaningful only after the required entitlements are
  included in the provisioning profile.

```sh
./script/build_and_run.sh --runtime
```

- `--runtime` uses the `RNDIS Tethering VM Passthrough Runtime` scheme and
  the `RuntimeDebug` configuration, and does not disable signing.

## Signing And Entitlements

- The current baseline is WireGuard-over-VZNAT. Do not reintroduce host
  packet-tunnel extension code, app-local packet relays, virtio-socket packet
  bridges, vmnet, `VZVmnetNetworkDeviceAttachment`, or
  `VZBridgedNetworkDeviceAttachment`.
- Checked-in signing defaults live in `Configuration/BuildSettings.xcconfig`.
  This file intentionally uses placeholder bundle identifiers and no
  development team.
- For local runtime signing, copy
  `Configuration/LocalSigning.xcconfig.example` to
  `Configuration/LocalSigning.xcconfig` and set the local `DEVELOPMENT_TEAM` and
  app bundle identifier there. The local file is intentionally ignored by Git.
- Do not hard-code a personal development team ID, provisioning profile, or local
  bundle identifier into the Xcode project file.
- `RTPVM.entitlements` is the main app entitlement file used by
  the standard app target configurations and includes:
  - `com.apple.developer.accessory-access.usb`
  - `com.apple.security.virtualization`
- `Runtime.entitlements` mirrors the same runtime entitlement set for
  `RuntimeDebug` validation and includes:
  - `com.apple.developer.accessory-access.usb`
  - `com.apple.security.virtualization`
- If restricted entitlements are missing from the provisioning profile, the
  runtime path fails. Do not use ad hoc signing as a substitute for restricted
  entitlement runtime validation.

## Development Notes

- The host WireGuard client is user-managed outside this app. The app may
  generate/copy/save `.conf` files but must not install or activate host VPN
  configurations. For macOS validation, prefer `wireguard-go` over the official
  WireGuard macOS GUI client until the current bring-up issue is understood.
- AccessoryAccess monitoring starts with the app even when no Settings or
  onboarding window is visible. Settings may stop or sequentially reload the
  listener for the current session, but a later app launch starts it again.
- Keep USB approval prompts AppKit-presented so they remain visible while all
  windows are closed. The store must serialize approval, VM start/restart, and
  VZ attach/detach completions. Preserve the VM-generation and USB-operation
  tokens that prevent callbacks from an earlier VM or attachment from mutating
  the current session.
- VM assets are selected during first-run onboarding and can later be changed
  in Settings. A valid generated asset folder requires the kernel and RTPVM
  initramfs; asset selection and validation must not require WireGuard
  configuration files. Before VM start, validate the separate app-local key
  pair, regenerate `Shared/wg0.conf`, and block startup with a visible
  WireGuard error if a key is missing or malformed.
- Clearing VM assets preserves the Application Support WireGuard directory.
  Reset App Settings may delete that directory only while the VM is stopped;
  if deletion fails, report the error and do not restart the app. A successful
  reset creates fresh key files and a generated server config on the next launch.
- Keep the WireGuard screen read-only: preview, copy, save/export, and reload
  use `WireGuardConfBuilder`. Its `WireGuardConfElements` input is ready for a
  future editor but currently uses defaults. Configuration editing and applying
  changes to an already-running `wg0` are follow-up work.
- WireGuard private/public keys are generated by the app with CryptoKit, not by
  `script/make_vm_assets` or the host `wg` command. Do not restore hardcoded
  keys, asset config migration, or asset-relative config lookup in Swift, shell
  scripts, README examples, or AGENTS guidance.
- BusyBox `init` is the generated initramfs PID 1. Its `sysinit` action mounts
  the early filesystems and prepares the console-side early boot path. Keep
  `init-rndis`, `init-virtiofs-wgconf`, and `init-network` ordered as `::wait`
  actions so the read-only VirtioFS configuration is mounted before
  `wg-quick up /run/rtpvm-wireguard/wg0.conf`. The RNDIS watcher handles `usb0` DHCP,
  installs source policy routing for the live `wg0` connected IPv4 CIDR via the
  RNDIS default gateway, enables IPv4 forwarding, and installs narrow nftables
  masquerade from `wg0` to `usb0`.
- Use `RTPVM_WG_ENDPOINT=<guest-nat-ip>:<listen-port>` from the guest console
  when rendering the app-generated client config. The port comes from the
  runtime server config's `ListenPort`.
- `make_vm_assets` includes `iproute2`, `nftables`,
  `wireguard-tools-wg-quick`, `tcpdump`, RNDIS module files, WireGuard module
  files and their dependencies, the `virtiofs` module plus its `fuse`
  dependencies, a `udhcpc` default script, and netfilter/NAT module files in the
  initramfs. It writes only VM assets under `script/assets`; ISO extraction,
  base initramfs files, and APKs stay under `script/assets/.cache`. It must not
  probe for host `wg`, generate WireGuard keys/configs, copy a config into the
  initramfs, or list configs in the manifest. Remove legacy
  `script/assets/wireguard` remnants during generation. Do not restore runtime
  guest `apk add`, and keep automatic forwarding scoped to IPv4 `wg0` traffic
  leaving through fixed RNDIS `usb0`.
- `script/wg_host_setup` has no asset-relative client-config fallback. Set
  `RTPVM_CLIENT_CONF` to the client config path saved or exported from the app
  before asking the helper to create a runtime host configuration.
- Real USB/WireGuard runtime validation requires macOS 27 beta, an approved
  provisioning profile for USB/Virtualization, a real RNDIS USB device, and a
  host WireGuard client.
- Signing/provisioning failures should not block compile builds, UI work, or
  documentation work.
- After code changes, the minimum verification is a
  `CODE_SIGNING_ALLOWED=NO` Xcode build. If app launch verification is needed,
  use `DERIVED_DATA=/tmp/RTPVM-Check ./script/build_and_run.sh --verify`.
