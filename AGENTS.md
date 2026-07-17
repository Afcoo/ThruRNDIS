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
- `ThruRNDISWireGuardNetworkExtension` is a WireGuardKit-backed Network System
  Extension embedded under `Contents/Library/SystemExtensions`. The app manages
  one host packet-tunnel profile and session, but does not inspect or relay
  packet payloads itself.
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

- `TetheringStore` owns cross-feature orchestration, general app state,
  WireGuard presentation state, onboarding/preferences, and the serialized USB
  approval/start/restart workflow. High-frequency or independently observed
  state lives in child stores: `EventLogStore` owns the bounded app event log,
  `ConsoleSessionStore` owns only VM serial-console output and endpoint scanning,
  `USBSessionStore` owns the atomic USB UI snapshot and pending prompt, and
  `VMConfigurationStore` owns persisted VM settings including the optional
  scratch disk. VM lifecycle work belongs in `VMCoordinator`; USB
  AccessoryAccess selection and passthrough policy belong in
  `USBAccessoryCoordinator`.
- `AppDelegate` is the composition root. It owns one shared
  `VMAssetWorkflowCoordinator`, constructs the VM, USB, and WireGuard adapters
  and the four child state stores, injects them into one shared `TetheringStore`,
  starts AccessoryAccess monitoring at app launch, and passes the same objects
  to onboarding, Settings, and the menu bar. Keep the dependency one-way:
  `TetheringStore` sees only the read-only `VMAssetProviding` boundary, and
  `VMAssetWorkflowCoordinator` must not reference `TetheringStore`.
- `VMAssetWorkflowCoordinator` is the `@MainActor` workflow owner for the current
  selection, installed releases, install state, progress, errors, cancellation,
  and stale-operation protection. It orchestrates protocol-injected release,
  download, install, and selection services; do not put `URLSession`,
  `FileManager`, `Process`, or hashing work directly in the coordinator.
- `GitHubVMAssetReleaseService` resolves the latest published release and
  requires exactly one `vm_assets.zip` and one `SHA256SUMS` attachment.
  `VMAssetDownloadService` owns HTTP validation, reported-size checks,
  progress, staging, cancellation, and partial-download cleanup.
  `VMAssetInstallService` owns checksum/archive validation, extraction, atomic
  promotion, metadata, and managed-release cleanup. `VMAssetSelectionStore`
  owns UserDefaults restoration and persistence for managed/manual selections
  and kernel/initramfs overrides. `VMAssetStorageLayout` defines the shared
  Application Support staging/release paths. `VMAssetFolderResolver` is the
  shared, file-only folder resolver and validator.
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
- `HostWireGuardTunnelController` activates the Network System Extension,
  creates the single `NETunnelProviderManager` profile, and starts/stops the
  session. It passes the rendered client configuration only in the in-memory
  `startTunnel(options:)` payload; do not persist the client private key in
  `providerConfiguration` or a system-wide location.
- The app does not inject WireGuard diagnostics into the VM console. Keep the
  console available for user-driven troubleshooting, independent of provider
  connection management.

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
- The optional scratch disk remains `VMConfigurationStore` state owned by the
  shared `TetheringStore` and is neither downloaded nor deleted by VM Asset
  installation or selection changes.
  WireGuard keys/configuration likewise remain in the separate Application
  Support `WireGuard/` tree and never come from a VM Asset release.

## Data Path

The current baseline data path is:

```text
ThruRNDIS WireGuardKit Network System Extension
-> VZNAT guest endpoint UDP/<ListenPort>
-> guest wg0
-> guest nftables masquerade
-> USB RNDIS upstream
```

- The current WireGuard test addresses are guest `10.100.0.1/24` and
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
- The app-generated client configuration lets the user override DNS servers,
  Endpoint, and Allowed IPs in Settings. A blank Endpoint falls back to the
  discovered guest VZNAT address, and blank Allowed IPs fall back to
  `0.0.0.0/0`. The default DNS servers are `1.1.1.1`, `1.0.0.1`, `8.8.8.8`,
  and `8.8.4.4`. IPv6 routing remains out of scope.
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
  WireGuard endpoint. Do not replace it with vmnet, bridged networking,
  route-command UI, or an app-local packet relay.

## Directory Guide

The project uses a layer-oriented source tree. Keep physical directories and
Xcode groups aligned, and keep each file in the narrowest layer that owns its
primary responsibility.

- `ThruRNDIS/App`: executable entrypoint and `AppDelegate` composition/lifecycle
  only. Do not place menu or window controllers here.
- `ThruRNDIS/Presentation`: AppKit presentation owners: the menu-bar controller
  and the window controllers that host SwiftUI onboarding, Settings, and console
  views.
- `ThruRNDIS/Views`: SwiftUI views. Settings tabs remain under
  `ThruRNDIS/Views/Settings`; reusable view-only components stay under
  `ThruRNDIS/Views/SharedViews`.
- `ThruRNDIS/Coordinators`: long-running workflows. `VMCoordinator` owns
  Virtualization lifecycle, `USBAccessoryCoordinator` owns AccessoryAccess
  selection and passthrough policy, and `VMAssetWorkflowCoordinator` owns VM
  Asset installation and selection workflow state. `VMCoordinating` remains a
  protocol boundary because tests provide a replacement implementation;
  `USBAccessoryCoordinator` stays concrete until a narrower tested boundary is
  required.
- `ThruRNDIS/Stores`: `@MainActor`/observable UI-facing state owners.
  `TetheringStore` owns cross-feature orchestration, `EventLogStore` owns the
  app event log, `ConsoleSessionStore` owns VM serial-console state,
  `USBSessionStore` owns the USB UI projection, and `VMConfigurationStore` owns
  editable VM settings and their UserDefaults persistence.
- `ThruRNDIS/Persistence`: non-observable durable-storage adapters and path
  definitions. `VMAssetSelectionStore` persists Asset selection,
  `WireGuardConfStore` owns Application Support keys/configuration, and
  `VMAssetStorageLayout` defines VM Asset staging and release locations.
- `ThruRNDIS/Services`: external/system operations such as GitHub release
  lookup, downloads, archive verification/install, AccessoryAccess monitoring,
  launch-at-login integration, Network System Extension activation, host
  WireGuard tunnel management, and Virtualization configuration creation.
- `ThruRNDIS/Models`: value types and protocol boundaries shared across layers,
  including VM Asset values, USB records/prompts, VM state, and WireGuard
  settings.
- `ThruRNDIS/Support`: small stateless helpers and narrow platform edges:
  clipboard/file panels, runtime entitlement reads, VM Asset folder validation,
  and WireGuard configuration rendering.
- `ThruRNDISTests`: mirrors production ownership with `Coordinators`,
  `Persistence`, `Services`, and `Stores` groups. Cross-layer fixtures live in
  `TestSupport`.
- `Configuration`: checked-in shared build settings and the local-signing
  template. `Configuration/LocalSigning.xcconfig` is local and ignored.
- `ThruRNDISWireGuardNetworkExtension`: the system-extension executable entry,
  `NEPacketTunnelProvider`, Info.plist, and development/distribution
  entitlements. Shared parser/constants files remain under `ThruRNDIS/Support`
  and are compiled into both targets.

This repository intentionally has no `GuestScripts/` or `script/` directory.
Published guest boot assets and their build/release tooling belong to the
separate `Afcoo/ThruRNDIS_VM_Assets` repository.

## Build And Run

- Local compile/UI iteration should not treat signing as the default blocker.
- For the default unsigned compile, use the Xcode beta `xcodebuild` directly:

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
  included in the provisioning profiles for both the app and Network System
  Extension.

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project "ThruRNDIS.xcodeproj" \
  -scheme "ThruRNDIS Runtime" \
  -configuration RuntimeDebug \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/ThruRNDIS-RuntimeDerivedData \
  build
```

- The runtime command does not disable signing.

## Signing And Entitlements

- The current baseline is WireGuardKit in a Network System Extension over the
  VZNAT guest endpoint. Do not add app-local packet relays, virtio-socket packet
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
  - `com.apple.developer.networking.networkextension` with
    `packet-tunnel-provider`
  - `com.apple.developer.system-extension.install`
  - `com.apple.security.virtualization`
- `Runtime.entitlements` mirrors the same runtime entitlement set for
  `RuntimeDebug` validation. `Distribution.entitlements` uses the Developer ID
  `packet-tunnel-provider-systemextension` suffix.
- The Network System Extension uses `Development.entitlements` for development
  signing and `Distribution.entitlements` with the same system-extension suffix
  for Developer ID distribution. Direct distribution must embed a
  `.systemextension`, not an App Store `.appex` packet-tunnel provider.
- If restricted entitlements are missing from the provisioning profile, the
  runtime path fails. Do not use ad hoc signing as a substitute for restricted
  entitlement runtime validation.

## Development Notes

- The app owns one WireGuard `NETunnelProviderManager` profile and exposes
  Connect, Disconnect, and Refresh controls. Keep `.conf` copy/save as a
  diagnostic fallback; do not hand the persistent private-key files to the
  provider or store plaintext configuration in preferences.
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
  operation is active. VM/USB start paths must reject requests while the Asset
  workflow is active and must revalidate the effective kernel/initramfs URLs.
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
- Keep WireGuard key material and server configuration read-only. The Connection
  section may edit and persist only the client DNS servers, Endpoint override,
  and Allowed IPs; preview, copy, save/export, and provider connection must all
  use the same effective values rendered by `WireGuardConfBuilder`. Applying
  edited server configuration to an already-running guest `wg0` remains
  follow-up work.
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
- Real USB/WireGuard runtime validation requires macOS 27 beta, an approved
  app profile for USB/Virtualization/NetworkExtension/System Extension install,
  an approved Network System Extension profile, a valid signing identity, a
  real RNDIS USB device, and approval in System Settings. Install the signed app
  in `/Applications` before testing activation.
- Signing/provisioning failures should not block compile builds, UI work, or
  documentation work.
- After code changes, the minimum verification is the unsigned Xcode build shown
  above. If app launch verification is needed, open the built
  `/tmp/ThruRNDIS-DerivedData/Build/Products/Debug/ThruRNDIS.app` after a
  successful build.
