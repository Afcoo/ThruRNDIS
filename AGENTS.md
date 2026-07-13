# AGENTS.md

This repository is a macOS 27+ USB RNDIS tethering VM project. Future agents
should read this file before the README and treat the current
WireGuard-over-VZNAT architecture as the baseline.

## Project Shape

- The app is a menu-bar utility with an AppKit `NSStatusItem`, not a Dock app or
  CLI `main.swift` entrypoint. It has no primary `WindowGroup`; SwiftUI provides
  the Settings scene, while a small AppKit window controller presents
  first-run onboarding.
- The Xcode project is `ThruRNDIS.xcodeproj`.
- The main app target is `ThruRNDIS` and builds a macOS app bundle.
- There is no host packet-tunnel extension target. The app does not create a
  host VPN, and does not inspect or forward packet payloads.
- Linux assets are not bundled with the app. The baseline user flow is the
  explicit `Download & Install Latest` action in onboarding, or
  `Check & Install Latest` in Settings. The app downloads the exact
  `vm_assets.zip` and `SHA256SUMS` attachments from the latest published
  [Afcoo/ThruRNDIS_VM_Assets Release](https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases),
  verifies and installs them in Application Support, and activates the managed
  release. Manual download, checksum verification, extraction, and folder
  selection remain a fallback. An optional raw scratch disk is user-managed
  separately. Do not direct users to build VM assets locally from this
  repository.
- The VM boots with the kernel image and initial ramdisk (initramfs) contained
  in the `vm_assets.zip` release artifact. After extraction and selection,
  `VMConfigurationFactory` passes those files from the selected `vm_assets`
  folder to `VZLinuxBootLoader` as its kernel and `initialRamdiskURL`.

## Architecture

- `TetheringStore` owns the general SwiftUI-facing app state, WireGuard
  configuration state, onboarding/preferences, optional scratch-disk
  selection, USB approval workflow, and console/event logs. It does not own VM
  Asset selection, persistence, or installation. VM lifecycle work belongs in
  `VMCoordinator`; USB AccessoryAccess selection and passthrough policy belong
  in `USBAccessoryCoordinator`.
- `AppDelegate` owns one shared `VMAssetController` and one shared
  `TetheringStore(assetProvider:)`, starts AccessoryAccess monitoring at app
  launch, and injects the same controller into onboarding, Settings, and the
  menu bar. Keep the dependency one-way: `TetheringStore` sees only the
  read-only `VMAssetProviding` boundary, and `VMAssetController` must not
  reference `TetheringStore`.
- `VMAssetController` is the `@MainActor` UI/workflow owner for the current
  selection, installed releases, install state, progress, errors, cancellation,
  and stale-operation protection. It orchestrates protocol-injected release,
  download, install, and selection services; do not put `URLSession`,
  `FileManager`, `Process`, or hashing work directly in the controller.
- `GitHubVMAssetReleaseService` resolves the latest published release and
  requires exactly one `vm_assets.zip` and one `SHA256SUMS` attachment.
  `VMAssetDownloadService` owns HTTP validation, reported-size checks,
  progress, staging, cancellation, and partial-download cleanup.
  `VMAssetInstallService` owns checksum/archive validation, extraction, atomic
  promotion, metadata, and managed-release cleanup. `VMAssetSelectionStore`
  owns UserDefaults restoration and persistence for managed/manual selections
  and kernel/initramfs overrides. `VMAssetFolderResolver` is the shared,
  file-only folder resolver and validator.
- `WireGuardConfStore` owns the app-local WireGuard directory and creates the
  server/client private-key files on first launch. `WireGuardConfBuilder`
  accepts editable configuration elements, uses defaults for now, generates
  `Shared/wg0.conf`, and renders the client configuration for preview/export.
  Neither type reads WireGuard configuration from the selected VM asset tree or
  hard-codes key material.
- `VMConfigurationFactory` builds the Linux VM configuration. The current
  baseline uses `VZLinuxBootLoader`, an optional raw scratch-disk attachment,
  an XHCI USB controller, `VZNATNetworkDeviceAttachment`, and
  `VZVirtioFileSystemDeviceConfiguration(tag: "thrurndis-wireguard")`. Its
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

## VM Asset Installation

- App launch restores and validates the persisted local selection and enumerates
  managed installations without making a network request. Latest-release lookup
  begins only after an explicit user action. It uses the unauthenticated GitHub
  latest-release API; surface rate-limit and network failures instead of adding
  a token, background update, automatic retry, or silent fallback.
- Downloads are staged under
  `~/Library/Application Support/<bundle-id>/VMAssets/.staging/<operation-id>/`.
  Require successful HTTP responses and sizes matching the release API for both
  exact asset names. Cancellation and every failure path must remove partial
  downloads and the operation staging directory.
- `SHA256SUMS` must contain exactly one valid entry for `vm_assets.zip`.
  Calculate the archive SHA-256 with CryptoKit before extraction. Inspect ZIP
  entries before running `/usr/bin/ditto -x -k`: accept only the `vm_assets/`
  root, reject absolute or traversal paths, duplicate entries, unexpected roots,
  and symbolic links. A managed release specifically requires regular
  `vm_assets/Image-lts` and
  `vm_assets/initramfs-thrurndis-lts` files.
- Promote a verified extraction atomically to
  `~/Library/Application Support/<bundle-id>/VMAssets/Releases/<release-id>-<archive-asset-id>/`
  and write `install.json` with the release ID/tag, archive asset ID, calculated
  hash, and install time.
  Reuse a valid matching installation without downloading it again. Persist the
  new selection before pruning older managed releases; never delete a manually
  selected directory. A failed/cancelled operation leaves the previous
  selection active, and clearing the selection preserves managed files.
- Manual selection of an extracted `vm_assets` folder and per-file kernel or
  initramfs overrides are supported fallbacks. `VMAssetFolderResolver` accepts
  the release root or its `boot/` directory layout and requires readable regular
  boot files. `VMConfigurationFactory` must receive only the validated effective
  boot URLs from `VMAssetProviding` immediately before VM start.
- The optional scratch disk remains `TetheringStore` state and is neither
  downloaded nor deleted by VM Asset installation or selection changes.
  WireGuard keys/configuration likewise remain in the separate Application
  Support `WireGuard/` tree and never come from a VM Asset release.

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
  `THRURNDIS_WG_ENDPOINT=<guest-nat-ip>:<listen-port>` from serial console output.
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
  `init-rndis` and `init-network`. It mounts the `thrurndis-wireguard` VirtioFS tag
  read-only at `/run/thrurndis-wireguard` and verifies that `wg0.conf` exists and
  is nonempty. `init-network` starts the interface directly from the shared
  config with `wg-quick`; host file changes do not alter an already-running
  interface and take effect on the next VM start.
- The app-generated client `.conf` acts as a WireGuard client and uses
  `<THRURNDIS_WG_ENDPOINT>` as a placeholder for the discovered guest VZNAT address.
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

- `ThruRNDIS/App`: SwiftUI app entrypoint, AppKit menu-bar controller, and
  onboarding window controller.
- `ThruRNDIS/Controllers`: `VMAssetController`, the shared VM Asset UI state and
  installation-workflow owner.
- `ThruRNDIS/Views`: setup, USB, console, and WireGuard views.
- `ThruRNDIS/Coordinators`: `VMCoordinator` for Virtualization VM lifecycle and
  `USBAccessoryCoordinator` for AccessoryAccess USB selection/passthrough
  policy.
- `ThruRNDIS/Stores`: `TetheringStore` orchestration/general app state and
  `VMAssetSelectionStore` selection persistence.
- `ThruRNDIS/Services`: VM Asset release lookup, download, verification/install,
  `USBAccessoryMonitor`, VM configuration factory, and VM delegate glue.
- `ThruRNDIS/Support`: file picker, clipboard, runtime entitlement reader helpers,
  `VMAssetFolderResolver`, `WireGuardConfStore` key creation/validation, and
  `WireGuardConfBuilder` server/client configuration rendering.
- `ThruRNDIS/GuestScripts`: currently empty. Published guest boot assets are owned
  by the separate `Afcoo/ThruRNDIS_VM_Assets` repository. No WireGuard
  configuration or private key is included in its release assets.
- `ThruRNDIS/Models`: VM Asset values/protocol boundaries, USB accessory records
  and approval prompts, VM state, and WireGuard settings.
- `script`: local app build/run/debug/verify entrypoints and host-side
  validation helpers. VM asset production and release belong to the separate
  public asset repository.

## Build And Run

- Local compile/UI iteration should not treat signing as the default blocker.
- Default run:

```sh
./script/build_and_run.sh
```

- The default script builds the `ThruRNDIS` scheme,
  `Debug` configuration, with `CODE_SIGNING_ALLOWED=NO`, then opens the app.
- For direct builds, prefer the Xcode beta `xcodebuild`:

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project "ThruRNDIS.xcodeproj" \
  -scheme "ThruRNDIS" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/ThruRNDIS-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

- Runtime signing checks are meaningful only after the required entitlements are
  included in the provisioning profile.

```sh
./script/build_and_run.sh --runtime
```

- `--runtime` uses the `ThruRNDIS Runtime` scheme and
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
- `ThruRNDIS.entitlements` is the main app entitlement file used by
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
- VM assets are installed during first-run onboarding and can later be checked,
  activated, manually selected, overridden, or cleared in Settings. Keep these
  controls disabled while VM configuration cannot be edited or an Asset
  operation is active. VM/USB start paths must reject requests while the
  controller is busy and must revalidate the effective kernel/initramfs URLs.
- Asset selection and validation must not require WireGuard configuration files;
  release assets never contain WireGuard keys or configuration. Before VM start,
  validate the separate app-local key pair, regenerate `Shared/wg0.conf`, and
  block startup with a visible WireGuard error if a key is missing or malformed.
- Clearing VM Asset selection preserves managed releases, the optional scratch
  disk, and the Application Support WireGuard directory. Reset App Settings may
  delete the WireGuard directory and clear the Asset selection only while the VM
  is stopped; it preserves managed Asset releases. If WireGuard deletion fails,
  report the error and do not restart the app. A successful reset creates fresh
  key files and a generated server config on the next launch.
- Keep the WireGuard screen read-only: preview, copy, save/export, and reload
  use `WireGuardConfBuilder`. Its `WireGuardConfElements` input is ready for a
  future editor but currently uses defaults. Configuration editing and applying
  changes to an already-running `wg0` are follow-up work.
- WireGuard private/public keys are generated by the app with CryptoKit, not by
  the external VM asset builder or the host `wg` command. Neither
  `vm_assets.zip` nor its corresponding-source release asset may contain a
  WireGuard key or configuration. Do not restore hardcoded keys, asset config
  migration, or asset-relative config lookup in Swift, shell scripts, README
  examples, or AGENTS guidance.
- BusyBox `init` is PID 1 in the published ThruRNDIS initramfs. Its `sysinit`
  action mounts the early filesystems and prepares the console-side early boot
  path. Keep `init-rndis`, `init-virtiofs-wgconf`, and `init-network` ordered
  as `::wait` actions so the read-only VirtioFS configuration is mounted before
  `wg-quick up /run/thrurndis-wireguard/wg0.conf`. The RNDIS watcher handles `usb0` DHCP,
  installs source policy routing for the live `wg0` connected IPv4 CIDR via the
  RNDIS default gateway, enables IPv4 forwarding, and installs narrow nftables
  masquerade from `wg0` to `usb0`.
- Use `THRURNDIS_WG_ENDPOINT=<guest-nat-ip>:<listen-port>` from the guest console
  when rendering the app-generated client config. The port comes from the
  runtime server config's `ListenPort`.
- VM asset production, dependency locking, license compliance, and GitHub
  Release publication belong to the public
  `https://github.com/Afcoo/ThruRNDIS_VM_Assets` repository. This app repository
  consumes its released `vm_assets.zip`; do not restore a local
  `make_vm_assets` pipeline or `script/assets` cache here. The published
  initramfs must retain the required networking tools and RNDIS, WireGuard,
  VirtioFS, and netfilter/NAT module closure, must not perform runtime guest
  `apk add`, and must keep automatic forwarding scoped to IPv4 `wg0` traffic
  leaving through fixed RNDIS `usb0`.
- `script/wg_host_setup` has no asset-relative client-config fallback. Set
  `THRURNDIS_CLIENT_CONF` to the client config path saved or exported from the app
  before asking the helper to create a runtime host configuration.
- Real USB/WireGuard runtime validation requires macOS 27 beta, an approved
  provisioning profile for USB/Virtualization, a real RNDIS USB device, and a
  host WireGuard client.
- Signing/provisioning failures should not block compile builds, UI work, or
  documentation work.
- After code changes, the minimum verification is a
  `CODE_SIGNING_ALLOWED=NO` Xcode build. If app launch verification is needed,
  use `DERIVED_DATA=/tmp/ThruRNDIS-Check ./script/build_and_run.sh --verify`.
