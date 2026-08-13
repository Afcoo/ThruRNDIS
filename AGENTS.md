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
- `ThruRNDISPrivilegedHelper` is a small command-line privileged helper embedded
  at `Contents/MacOS/ThruRNDISPrivilegedHelper`, with its launchd property list
  at `Contents/Library/LaunchDaemons/ThruRNDISPrivilegedHelper.plist`. The app
  registers it with `SMAppService.daemon` only after an explicit request in the
  onboarding permissions page or Dummy Ethernet Settings tab. The app bundle is
  the helper executable's only source; never copy it to
  `/Library/PrivilegedHelperTools` or maintain a versioned system-path copy.
  This project does not use DriverKit.
- Linux assets are not bundled with the app. The shared onboarding and Settings
  flow presents `Download & Install Latest` while assets are unconfigured and
  `Check & Install Latest` once a valid selection is ready. The app downloads
  the exact `vm_assets.zip` and `SHA256SUMS` attachments from the latest published
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

- `TetheringStore` is the app-facing facade for reset ordering, onboarding
  presentation/listener coordination, and general VM, USB, and WireGuard
  commands. It adapts VM and USB callbacks into observable presentation state
  and forwards cross-feature events to `TetheringWorkflowCoordinator`, which
  owns only the serialized USB approval, VM preparation, passthrough, and
  optional WireGuard request workflow. `ManagedWireGuardConnectionCoordinator`
  separately owns the Dummy Ethernet preparation, WireGuard tunnel wait, cleanup,
  cancellation, and stale-operation protection used by app-managed connections.
  State that can be observed independently lives in child stores. `EventLogStore`
  owns the bounded in-memory app event log and screen filtering, while
  `EventLogFileStore` serially persists every event under Application Support
  with 10 MiB or 24-hour session-file rotation and seven-day retention.
  `ConsoleSessionStore`
  owns only VM serial-console output and endpoint scanning, `USBSessionStore`
  owns the atomic USB UI snapshot plus USB attachment prompt queue, de-duplication,
  and VM-asset deferral, `VMConfigurationStore`
  owns persisted VM settings including the optional scratch disk,
  `WireGuardSessionStore` owns WireGuard tunnel/System Extension presentation state,
  the USB-triggered WireGuard connection prompt, WireGuard inputs, validation,
  and configuration readiness, and
  `AppPreferencesStore` owns onboarding completion, USB/WireGuard preferences,
  WireGuard Manual Configuration Mode, and Launch at Login state. WireGuard
  Manual Configuration Mode keeps guest WireGuard configuration generation and host configuration
  export available, but disables app-managed host WireGuard connections and
  Dummy Ethernet. VM lifecycle work belongs in `VMCoordinator`; USB
  AccessoryAccess selection and passthrough policy belong in
  `USBAccessoryCoordinator`.
- `AppDelegate` is the composition root. It owns one shared
  `VMAssetWorkflowCoordinator`, constructs the VM, USB, and WireGuard adapters
  and the independently injected child state stores, and injects them into one shared `TetheringStore`,
  requests AccessoryAccess monitoring at app launch, and passes the same objects
  to onboarding, Settings, and the menu bar. Before each listener start in normal
  app-managed mode, `TetheringStore` requires completed onboarding, valid VM Assets,
  an active Network Extension, and the current Dummy Ethernet helper. Manual
  Configuration Mode requires only completed onboarding and valid VM Assets;
  it must not require Network Extension activation or privileged-helper installation.
  Views observe the narrowest child
  store that owns their state while invoking `TetheringStore` only for
  cross-feature actions. Keep the dependency one-way: `TetheringStore` sees
  only the read-only `VMAssetProviding` boundary, and
  `VMAssetWorkflowCoordinator` must not reference `TetheringStore`.
- `TetheringStore` owns `DummyEthernetStore`, which owns Dummy Ethernet network
  configuration, runtime presentation state, and Start/Stop/Restart operations.
  `DummyEthernetHelperStore` is its separately observable child and owns only
  privileged-helper registration state and Install/Reinstall/Remove actions.
  Onboarding, Settings, and the menu bar receive both stores through the shared
  `TetheringStore` and observe the narrower owner. Every app-managed WireGuard
  connection requested from the USB prompt or USB auto-connect path is requested
  by `TetheringWorkflowCoordinator` and executed by
  `ManagedWireGuardConnectionCoordinator`, which asks the owned
  `DummyEthernetStore` to prepare and wait until it is active before starting
  the WireGuard tunnel. Preparation starts an inactive configuration and explicitly
  restarts a known degraded configuration through the shared Restart flow. The
  coordinator then stops Dummy Ethernet only after the tunnel reports that it
  is connected. The normal-mode menu bar uses the same prepared connection
  path, while Settings and the debug-mode menu bar keep the direct WireGuard
  connection path and require Dummy Ethernet to be managed separately. A failed
  preparation must prevent the WireGuard start, and an unsuccessful tunnel start
  must not trigger automatic Dummy Ethernet cleanup. Do not inject Dummy
  Ethernet into USB attach or VM start flows. The app-wide Reset All
  Settings workflow is owned by `TetheringStore`; after its VM, USB, and
  WireGuard cleanup, it asks `DummyEthernetStore` to stop its managed
  configuration and `DummyEthernetHelperStore` to unregister the privileged
  helper before `AppDelegate` clears the remaining selection and quits.
  A failed stop must leave the helper registered, and any Dummy Ethernet
  cleanup failure must prevent quitting. Normal application termination in
  app-managed mode also waits for any configured Dummy Ethernet operation and
  its stop request to finish before `AppDelegate` allows the process to exit.
  The menu bar keeps a
  leading configuration section that lists Settings guidance for each unavailable
  VM Assets, Network Extension, and privileged-helper prerequisite. In normal
  mode, any unavailable prerequisite hides every status and control section;
  debug mode keeps those sections visible below the configuration guidance.
  Settings and Quit remain available in both modes. Once all prerequisites are
  ready, the menu bar keeps all status items in one leading section. Debug mode
  then orders its control sections as VM, USB, WireGuard, and Dummy Ethernet,
  with a separator between sections; normal mode omits VM and Dummy Ethernet
  controls. Debug-mode status
  and control order
  is VM, USB, WireGuard, then Dummy Ethernet. The normal-mode combined status
  evaluates only VM, USB, and WireGuard because Dummy Ethernet is stopped after
  establishing an automatically managed tunnel. In debug mode, a helper
  operation that begins while the enabled-helper menu is visible uses the fixed
  Helper Problem state until the menu is rebuilt for the resulting registration
  status.
  `DummyEthernetPrivilegedHelperRegistrationService` owns `SMAppService.daemon`
  registration and status, while `DummyEthernetPrivilegedHelperClient` owns the
  authenticated NSXPC connection to the helper. The unprivileged app must not
  execute `ifconfig`, `networksetup`, `scutil`, or `route` itself.
- `VMAssetWorkflowCoordinator` is the `@MainActor` workflow owner for the current
  selection, installed releases, install state, progress, errors, cancellation,
  and stale-operation protection. It orchestrates the concrete release,
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
- `WireGuardConfigurationStore` owns the app-local WireGuard directory and
  creates the server/client private-key files on first launch.
  `WireGuardConfigurationBuilder` accepts editable configuration elements, uses
  defaults for now, and builds the single-peer internal client connection state.
  `WgQuickConfigurationRenderer` renders the guest `Shared/wg0.conf` and renders
  that client state only for manual preview/export.
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
- `WireGuardTunnelController` activates the Network System Extension,
  creates the single `NETunnelProviderManager` profile, and starts/stops the
  session. `WireGuardSessionStore` updates and retains one validated single-peer
  client connection state whenever its keys or effective editable inputs change;
  connect and manual preview/export reuse that same state without reparsing the
  inputs. The controller passes the state's binary property-list encoding only
  in the in-memory `startTunnel(options:)` payload. The Network
  System Extension decodes that state and constructs WireGuardKit
  `InterfaceConfiguration`, `PeerConfiguration`, and `TunnelConfiguration`
  values directly. Do not persist the client private key in
  `providerConfiguration` or a system-wide location, and do not reintroduce a
  wg-quick parser into the provider connection path.
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

In WireGuard Manual Configuration Mode, a user-managed WireGuard client replaces the
ThruRNDIS Network System Extension at the start of this path. The app still
generates the guest `wg0.conf` and renders the host configuration for manual
copy/export, but it must not request a host tunnel connection or prepare Dummy
Ethernet.

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
- If both key files are absent, `WireGuardConfigurationStore` generates
  server/client X25519 keys with CryptoKit. If only one key is missing or either
  key is malformed, it reports an error without replacing the existing key.
  `WireGuardConfigurationBuilder` receives both public/private raw key values
  and builds the current single-peer client connection state. The wg-quick
  renderer atomically regenerates `Shared/wg0.conf` directly from the server
  key material and configuration elements. The client `.conf` is not stored in
  Application Support; it is rendered from the client connection state on
  demand only for manual preview/export. Existing asset configurations are
  ignored and are not migrated.
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
  on approval if needed, and then attaches it. One VM boot corresponds to one
  USB passthrough attachment lifetime. A manual detach, physical disconnect, or
  system-reported passthrough disconnect stops that VM session. A different
  device can be attached only after the current device is detached and the VM
  has stopped; it then follows the ordinary approval and fresh-VM start flow.
- Guest NAT is based on `nftables` masquerade from `wg0` traffic to `usb0`.
- The setup NAT NIC provides the private host-to-guest network used for the
  WireGuard endpoint. Do not replace it with vmnet, bridged networking,
  route-command UI, or an app-local packet relay.

## Dummy Ethernet Compatibility Service

- Dummy Ethernet is an optional compatibility feature. Settings owns its
  editable configuration, while Settings and the debug-mode menu bar expose
  manual Start/Stop/Restart controls. The normal-mode menu bar does not show
  Dummy Ethernet controls, and neither menu mode exposes helper registration,
  installation, removal, approval, or reinstallation actions. The menu bar
  presents Dummy Ethernet as a colored status item in debug mode and excludes it
  from the combined status in normal mode. When the helper is not enabled, normal
  mode omits every status and control section, while debug mode retains the other
  sections and presents the fixed Helper Problem Dummy Ethernet status. For a
  helper operation that begins from the enabled state, present that same fixed
  Helper Problem guidance in the debug-mode status item until the menu is
  rebuilt; never expose helper registration status variants or a separate
  colorless helper item in the menu bar. It exists
  to provide a synthetic satisfied wired-Ethernet path for network-path
  evaluation. When macOS has no active network connection, the app-managed
  WireGuard setup requires Dummy Ethernet to provide that satisfied path.
  WireGuard connections accepted through the USB prompt, requested by USB
  auto-connect, or started from the normal-mode menu bar ensure Dummy Ethernet
  is active first and stop it after the WireGuard tunnel reaches the connected state.
  Connections started from Settings or the debug-mode menu bar keep Dummy
  Ethernet as a separate manual configuration. This requirement is limited to
  setup and network-path evaluation:
  Dummy Ethernet remains independent of the tethering data path, does not
  provide connectivity, forwarding, DNS, or NAT, and retains its manual
  Start/Stop/Restart controls in addition to the automatic WireGuard prerequisite.
  Normal application termination in app-managed mode waits for any configured
  Dummy Ethernet to stop before quitting. The explicit Reset All Settings
  action additionally unregisters the helper and restores the persisted Dummy
  Ethernet inputs to defaults after stopping the managed configuration.
  WireGuard Manual Configuration Mode hides Dummy Ethernet settings and menu presentation,
  excludes helper readiness from USB-listener prerequisites, and never starts
  Dummy Ethernet. It does not run app-managed WireGuard or Dummy Ethernet
  termination cleanup. Changing the mode requires user confirmation and
  application termination. Keep the running process in the mode selected at
  launch, finish that mode's termination preparation before persisting the
  target mode, and apply the change the next time the user opens the app. Do
  not add live-transition conditions, component-state tracking, or listener
  revalidation for a mode change.
- `SMAppService` registration is explicit. After a successful register request,
  record the helper-specific installation identity embedded in the helper file
  rather than the app build number or file-system metadata. Keep that identity
  stable when only the app marketing/build version changes, and increment it
  whenever the installed helper implementation changes. Replacing an app bundle
  can leave the previous root helper process alive; an identity mismatch must
  block network operations until the user explicitly reinstalls the helper or
  removes the old registration and installs it again.
  Do not add runtime helper metadata handshakes, connection-probe retry state,
  or automatic registration repair in response to refresh or a normal
  network-operation failure.
- The default host address is `192.168.100.2` with a fixed `/24` mask and the
  subnet `.1` address as its router (`192.168.100.1` by default). Settings may
  persist a different RFC 1918 host IPv4 address and separate Bond-member and
  router-peer names. Validation rejects `.0`, `.1`, and `.255` host octets;
  interface names must be distinct canonical `feth<number>` BSD names no more
  than 15 UTF-8 bytes. IPv6 is disabled for the service.
- The defaults are `feth0` (Bond member) and `feth1` (router peer), while the
  Bond BSD name comes from `SCBondInterfaceCreate` (`bond0`, `bond1`, and so
  on). Persist that Bond name, the Network Service ID, and both feth names in
  one property-list ownership value in the same `SCPreferences` transaction.
  Resolve and remove only those recorded objects. The branded Hardware Port and
  Network Service names are display labels, not discovery keys. Missing
  ownership metadata means there is no managed configuration; malformed
  metadata fails closed. Never scan for, adopt, migrate, or remove same-named
  legacy objects. Do not add an external ownership file or Dynamic Store state.
- The helper creates, configures, enables, and removes the Bond and
  Network Service only through the public SCNetworkConfiguration APIs. Do not
  restore `networksetup`, Dynamic Store writes, `configd` restarts, or direct
  route manipulation. Keep the service last in the current service order.
- `/sbin/ifconfig` remains only for creating, peering, addressing, bringing up
  or down, and destroying the validated feth pair, plus the static-Bond runtime sequence
  `ifconfig <allocated-bond> bondmode static` followed by
  `ifconfig <allocated-bond> bonddev <configured-member>`. The Bond argument
  must come only from `SCNetworkInterfaceGetBSDName`; invoke the tool with
  argument arrays and no shell API.
- Status contains only whether the branded SystemConfiguration objects exist,
  the allocated Bond and configured feth names, configured IPv4 address, and whether a bounded
  `NWPathMonitor(requiredInterfaceType: .wiredEthernet)` observation reports
  `NWPath.Status.satisfied` with that Bond available. Do not restore
  `scutil --nwi`, scoped-route parsing, command-output parsers, or detailed
  topology/recovery state.
- Start is idempotent only for an already active matching configuration.
  Otherwise, occupied feth names or a partial/mismatched recorded setup are an
  explicit conflict that the user must Stop or resolve. A failed Start rolls
  back only objects created by that invocation. Stop removes only the exact
  recorded SCNetworkConfiguration setup and the feth pair stored with it; feth
  names without that marker are treated as unrelated.
- Restart is available while the runtime state is active or degraded. Its
  shared flow performs one explicit Stop followed by Start with the current
  validated configuration. Manual Restart and app-managed WireGuard preparation
  use that same flow when the known runtime state is degraded. If Stop succeeds
  but Start fails, retain the stopped runtime state so the user can retry Start.
- The helper accepts only the narrow Foundation-value NSXPC protocol, authenticates
  the connecting app's code-signing identifier and team, validates every input
  again while privileged, and invokes only fixed absolute system-tool paths with
  argument arrays. The app authenticates the helper with the corresponding
  derived identifier and team. Do not add an arbitrary command or shell API.

## Naming Conventions

- Follow Swift API naming conventions: types and protocols use `UpperCamelCase`;
  functions, properties, local values, parameters, and enum cases use
  `lowerCamelCase`. Prefer names that describe responsibility or behavior over
  implementation details.
- Preserve the project's established domain and product spellings. Type names
  use initialisms such as `VM`, `USB`, `URL`, `ID`, `DNS`, `MTU`, `MAC`,
  `RNDIS`, and `SHA256`, while lower-camel-case names begin with `vm`, `usb`,
  or `wg` and retain capitalized suffixes such as `operationID` and
  `directoryURL`. Keep the branded spellings `ThruRNDIS`, `WireGuard`, and
  `GitHub`.
- Spell app-owned configuration identifiers with `Configuration`; do not
  introduce abbreviated `Conf` or `Config` type, file, property, or parameter
  names. `WgQuickConfigurationRenderer` remains an exception because it
  identifies the wg-quick file format.
- Use role suffixes consistently. Observable UI state owners end in `Store`;
  long-running workflow and lifecycle owners in `Coordinator`; AppKit
  presentation owners in `Controller` or `WindowController`; external/system
  operation adapters in `Service`, `Monitor`, or `Activator`; and focused
  construction, transformation, or validation helpers in `Factory`, `Builder`,
  `Resolver`, `Validator`, or `Formatter`. SwiftUI types end in `View`, and
  error types end in `Error`.
- Name value and state projections by their semantics, using established
  suffixes such as `Record`, `Prompt`, `Input`, `Result`, `Descriptor`,
  `Metadata`, `Snapshot`, `State`, and `Status`. Prefer `struct` and `enum` for
  values and stateless namespaces; use `final class` for identity, mutable
  lifecycle, delegate, or observable state owners. UI-facing observable owners
  belong on `@MainActor`.
- Name protocol boundaries for the production capability they provide, normally
  with an `-ing` form such as `VMAssetProviding`. Add a protocol boundary only
  when the runtime architecture requires abstraction; do not create one solely
  to mirror a concrete type or prepare for possible testing.
- Name a Swift source file after its primary type and normally keep one primary
  responsibility per file. Private helper types may remain beside that owner.
  Closely related domain values and shared boundaries may use an umbrella file
  such as `VMAssetModels.swift` or `RuntimeEntitlements.swift`. Name focused
  extensions `ExtendedType+Concern.swift`, for example
  `NETunnelProviderProtocol+WireGuard.swift`.

## Test Creation Policy

- This repository intentionally has no automated test target, test source tree,
  test fixtures, test doubles, or production protocols created only for tests.
- Do not create or restore any test target, test source, fixture, mock, stub,
  fake, test-support utility, or test-only protocol unless the user gives
  separate, explicit instructions for the test configuration to build.
- A request to add, change, refactor, debug, or fix production behavior does not
  implicitly authorize test creation. Validate those changes with the relevant
  compile or build command and report that no automated test suite is configured.
- When the user explicitly defines a new test approach, follow that direction
  and update this section and the project structure to match it.

## SwiftUI Presentation

- Keep SwiftUI screens concise. Default to the control label, current state,
  and available action; do not add subtitles, descriptive paragraphs, section
  footers, captions, or repeated guidance merely to explain self-evident UI.
- Add persistent supporting copy only when it prevents a likely
  misconfiguration or explains a non-obvious permission, safety, or recovery
  consequence. Keep it to one short sentence and do not restate a section
  title, control label, or button action.
- Preserve useful accessibility labels, values, and hints without duplicating
  them as visible explanatory text.
- Any onboarding control that reads or changes configuration also exposed in
  Settings must reuse the same component from `ThruRNDIS/Views/SharedViews`.
  Keep page titles, introductory copy, supporting guidance, and step navigation
  in `OnboardingView`, while the shared component owns the configuration status,
  actions, validation, and error presentation used by both surfaces. Do not
  duplicate Settings implementations in onboarding. Both surfaces must host
  these shared components in a `Form`; the component provides wrapper-free Form
  rows rather than its own `Form`, `GroupBox`, or layout container. This policy
  applies to VM Assets, Network Extension permission, privileged-helper
  permission, and any future Settings-backed onboarding control. Each
  onboarding step owns one `Form` containing its page header, supporting copy,
  shared rows, and any other step content; do not nest another `Form` inside a
  step.

## Directory Guide

The project uses a layer-oriented source tree. Keep physical directories and
Xcode groups aligned, and keep each file in the narrowest layer that owns its
primary responsibility. The project uses explicit Xcode groups, so adding,
moving, renaming, or deleting a file also requires updating its Xcode group,
target membership, and build phase as applicable.

- `ThruRNDIS/App`: executable entrypoint and `AppDelegate` composition/lifecycle
  only. Do not place menu or window controllers here.
- `ThruRNDIS/Presentation`: AppKit presentation owners: the menu-bar controller
  and the window controllers that host SwiftUI onboarding, Settings, and console
  views. `WireGuardConfigurationFileController` owns the AppKit/file-system
  presentation actions for opening, copying, and exporting rendered WireGuard
  configuration; keep those actions out of stores and SwiftUI views.
- `ThruRNDIS/Views`: SwiftUI views. Settings tabs remain under
  `ThruRNDIS/Views/Settings`; reusable view-only components stay under
  `ThruRNDIS/Views/SharedViews`.
- `ThruRNDIS/Coordinators`: long-running workflows. `VMCoordinator` owns
  Virtualization lifecycle, `USBAccessoryCoordinator` owns AccessoryAccess
  selection and passthrough policy, `TetheringWorkflowCoordinator` serializes
  USB approval through VM preparation and an optional WireGuard request,
  `ManagedWireGuardConnectionCoordinator` owns Dummy Ethernet preparation and
  cleanup around an app-managed WireGuard connection, and
  `VMAssetWorkflowCoordinator` owns VM Asset installation and selection workflow
  state. `VMCoordinator` and `USBAccessoryCoordinator` are concrete production
  dependencies; do not add protocol mirrors for them without a production
  architecture requirement.
- `ThruRNDIS/Stores`: `@MainActor`/observable UI-facing state owners.
  `TetheringStore` exposes the app-facing observable facade, `EventLogStore` owns the
  bounded in-memory app event log and view filters, `ConsoleSessionStore` owns VM
  serial-console state,
  `USBSessionStore` owns the USB UI projection and attachment prompt queue, and
  `VMConfigurationStore` owns
  editable VM settings and their UserDefaults persistence.
  `WireGuardSessionStore` owns WireGuard presentation/session state, the
  USB-triggered connection prompt, and editable connection inputs, while
  `AppPreferencesStore` owns persisted app preferences,
  onboarding completion, and Launch at Login state. The `TetheringStore`-owned
  `DummyEthernetStore` owns persisted configuration input, manual
  Start/Stop/Restart actions, and presented network runtime state, while its
  `DummyEthernetHelperStore` child independently owns helper registration state
  and actions.
  View-scoped observable state such as `VideoPlaybackStore` also belongs here
  when it is substantial enough to live outside its SwiftUI view.
- `ThruRNDIS/Persistence`: non-observable durable-storage adapters and path
  definitions. `EventLogFileStore` owns rotated Application Support log files,
  retention cleanup, and file-based export. `VMAssetSelectionStore` persists
  Asset selection, `WireGuardConfigurationStore` owns Application Support
  keys/configuration, and `VMAssetStorageLayout` defines VM Asset staging and
  release locations.
- `ThruRNDIS/Services`: external/system operations such as GitHub release
  lookup, downloads, archive verification/install, AccessoryAccess monitoring,
  launch-at-login integration, Network System Extension activation, host
  WireGuard tunnel management, Virtualization configuration creation,
  privileged-helper registration, and the authenticated NSXPC helper client.
- `ThruRNDIS/Models`: value types and protocol boundaries shared across layers,
  including VM Asset values, USB records/prompts, VM state, WireGuard settings,
  the shared App-to-Network-Extension `WireGuardTunnelContract`, and the narrow
  Dummy Ethernet configuration and status values.
- `ThruRNDIS/Support`: small stateless helpers and narrow platform edges:
  clipboard/file panels, runtime entitlement reads, VM Asset folder validation,
  WireGuard configuration rendering, Dummy Ethernet IPv4 validation, shared
  helper constants, and peer code-signing requirement construction.
- `ThruRNDIS/Resources`: app-bundle resources such as localization catalogs and
  onboarding media. Keep app and menu-bar icon sources under the existing
  `ThruRNDIS.icon` asset folder and `ThruRNDISMenuBarIcon.svg` location.
- `Configuration`: checked-in shared build settings and the local-signing
  template. The privileged-helper identifier derives from the app identifier in
  `BuildSettings.xcconfig`; do not add a helper provisioning-profile setting.
  `Configuration/LocalSigning.xcconfig` is local and ignored.
- `images`: README-only images. Do not add this directory to the app's resource
  build phase.
- `script`: project-local developer automation only. Keep
  `script/build_and_run.sh` as the unsigned kill, build, and launch entrypoint
  for normal Codex and shell iteration. Use `script/build_and_install.sh` only
  for the signed Runtime build and `/Applications` installation required by
  Network System Extension testing. Use `script/package_app.sh` as the full
  Developer ID Release orchestrator. It coordinates `script/build_app.sh`,
  `script/notarize_app.sh`, `script/build_dmg.sh`, and
  `script/notarize_dmg.sh` in that order; shared artifact validation
  belongs in `script/support/distribution_common.sh`, while shared artifact-path
  and disk-image I/O belongs in `script/support/distribution_io.sh`. Internal
  helpers that are sourced or invoked by Xcode/Finder automation belong under
  `script/support/`, including `build_wireguard_go_bridge.sh`,
  `generate_privileged_helper_launchd_plist.sh`, and
  `configure_dmg_layout.applescript`. The plist generator must safely replace
  the single designated bundle-identifier placeholder in both `Label` and the
  sole `MachServices` key, then validate its output before embedding.
  The build scripts do not contact Apple's
  notary service. The notarization scripts require credentials already stored
  in Keychain and staple their supplied artifact in place. `package_app.sh`
  alone owns the resumable `dist/.package-work/` lifecycle and final publication
  under `dist/`.
- `ThruRNDISWireGuardNetworkExtension`: the system-extension executable entry,
  `NEPacketTunnelProvider`, Info.plist, and development/distribution
  entitlements. `PacketTunnelProvider.swift` also owns its private provider
  errors and the conversion from the shared connection state into WireGuardKit
  values. `WireGuardTunnelContract.swift` is compiled into both app and
  extension targets. No wg-quick parser belongs in either target.
- `ThruRNDISPrivilegedHelper`: the minimal root helper executable, launchd plist
  template, fixed `ifconfig` runner, SCNetworkConfiguration adapter,
  Network.framework path monitor, and minimal feth/static-bond lifecycle. It
  must not become a general administrative service.

This repository intentionally contains no guest VM scripts or guest-asset build
pipeline. The `script/` directory is limited to host-app developer automation;
published guest boot assets and their build/release tooling belong to the
separate `Afcoo/ThruRNDIS_VM_Assets` repository.

## Build And Run

- Local compile/UI iteration should not treat signing as the default blocker.
- Use the project-local script as the default unsigned build-and-run entrypoint.
  It stops an existing `ThruRNDIS` process, builds with Xcode beta into the
  deterministic DerivedData path below, and launches the fresh app bundle:

```sh
./script/build_and_run.sh
```

- Optional modes are `--debug`, `--logs`, `--telemetry`, and `--verify`.
  `.codex/environments/environment.toml` wires the Codex Run action to the same
  no-flag command. Keep that action and the shell workflow on this single
  entrypoint.
- For signed USB, Virtualization, Network System Extension, and privileged-helper
  testing, first configure `Configuration/LocalSigning.xcconfig`, then build,
  validate, and install the Runtime app with:

```sh
./script/build_and_install.sh
```

  The install script uses the `ThruRNDIS Runtime` scheme and `RuntimeDebug`
  configuration, validates the app and embedded Network System Extension plus
  the exact privileged-helper executable/launchd-plist paths, signing identifiers,
  signing-team match, hardened runtime, launchd metadata, and required
  entitlements, then safely replaces `/Applications/ThruRNDIS.app`. It does not
  launch the installed app.
- For a build-only check or diagnosing the underlying Xcode invocation, use:

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
  Extension. The privileged helper shares their signing team but requires no
  provisioning profile.

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

- For public Developer ID distribution, configure the Release signing
  certificate and the exact app/System Extension distribution
  provisioning-profile names in `Configuration/LocalSigning.xcconfig`, and
  store Apple notary credentials once in the default Keychain profile:

```sh
xcrun notarytool store-credentials "thrurndis-notary"
```

  Then run the **Build Notarized DMG** Codex action or its single shell
  entrypoint:

```sh
./script/package_app.sh
```

  `package_app.sh` runs four focused stages in sequence:
  `build_app.sh`, `notarize_app.sh`, `build_dmg.sh`, and `notarize_dmg.sh`.
  It uses one ignored, versioned work directory at
  `dist/.package-work/ThruRNDIS-<version>-<build>/`, with `ThruRNDIS.app` and the
  DMG stored directly inside it. A rerun resumes completed build or notarization
  stages from that directory instead of creating a random hidden attempt.

  The app build stage archives and exports the `ThruRNDIS Runtime` scheme in
  `Release`, validates the Developer ID signatures, hardened runtime,
  distribution entitlements, embedded Network System Extension, and embedded
  privileged helper/launchd metadata without contacting Apple. The app
  notarization stage submits the supplied app once, then staples and verifies
  that same bundle without rebuilding or re-signing it.

  The DMG build stage revalidates the notarized input app, creates the compact
  480x300 Finder layout with 96 px icons and fixed app/Applications positions,
  validates the contained app copies, and signs the image without contacting
  Apple. The DMG notarization stage submits the supplied image once, then
  staples and verifies that same file. After all four stages succeed,
  `package_app.sh` publishes the app and DMG without overwriting an existing
  package at `dist/ThruRNDIS-<version>-<build>/`, containing `ThruRNDIS.app`
  and `ThruRNDIS-<version>.dmg`. The mounted volume uses the built app's `.icns`;
  the `.dmg` file itself intentionally uses the standard macOS disk-image icon.
  The app is never re-signed during DMG creation. Only the DMG is separately
  signed. Set
  `THRURNDIS_NOTARY_KEYCHAIN_PROFILE` to use a non-default profile. Set
  `THRURNDIS_ALLOW_PROVISIONING_UPDATES=1` only when Xcode should be allowed to
  fetch or update signing assets during archive/export.

  `notarize_app.sh` and `notarize_dmg.sh` invoke
  `verify_notarized_app.sh` and `verify_notarized_dmg.sh` respectively for
  post-notarization trust-policy checks.
  Pass `--skip-verification` to `package_app.sh`,
  `notarize_app.sh`, or `notarize_dmg.sh` to skip only those standalone
  post-notarization checks. Signing, Apple notary submission, ticket stapling,
  and the structural/integrity checks required to construct the artifact remain
  enabled.

  If a stage fails, rerun `package_app.sh` to resume the versioned package work.
  The focused notarization scripts may also be run directly:

```sh
./script/notarize_app.sh \
  dist/.package-work/ThruRNDIS-<version>-<build>/ThruRNDIS.app
./script/notarize_dmg.sh \
  dist/.package-work/ThruRNDIS-<version>-<build>/ThruRNDIS-<version>.dmg
```

  Successful publication moves that version's work directory as one unit to
  `dist/ThruRNDIS-<version>-<build>/`, then removes the empty `.package-work`
  root. If both final outputs already exist, a rerun validates
  their stapled tickets and exits without rebuilding or resubmitting either
  artifact.

  The focused build scripts accept `--output` for an explicit artifact path.
  Without it, `build_app.sh` writes `ThruRNDIS.app` and `build_dmg.sh` writes
  `ThruRNDIS-<version>.dmg` in the current working directory. To build only a
  DMG from an already-published app without resubmitting that app, run:

```sh
./script/build_dmg.sh --output <new-output>/ThruRNDIS-<version>.dmg \
  dist/ThruRNDIS-<version>-<build>/ThruRNDIS.app
```

  Independently revalidate an already-published app or DMG from a normal macOS
  terminal session with:

```sh
./script/verify_notarized_app.sh \
  dist/ThruRNDIS-<version>-<build>/ThruRNDIS.app
./script/verify_notarized_dmg.sh \
  dist/ThruRNDIS-<version>-<build>/ThruRNDIS-<version>.dmg
```

  The app verifier checks the app, embedded Network System Extension, and
  privileged helper signatures, hardened runtime, secure timestamps,
  direct-distribution entitlements, helper launchd metadata, stapled ticket,
  and Gatekeeper distribution policy. The DMG verifier checks the image
  checksum, Developer ID signature, secure timestamp, stapled ticket,
  Gatekeeper open policy, and the same app checks after a read-only mount. Run
  these trust-policy checks outside a restricted sandbox because blocked access
  to macOS security services can produce false failures.

## Signing And Entitlements

- The current baseline is WireGuardKit in a Network System Extension over the
  VZNAT guest endpoint. Do not add app-local packet relays, virtio-socket packet
  bridges, vmnet, `VZVmnetNetworkDeviceAttachment`, or
  `VZBridgedNetworkDeviceAttachment`. The manual Dummy Ethernet workaround uses
  feth plus a static bond through the privileged helper; do not add a DriverKit
  target or DEXT.
- Checked-in signing defaults live in `Configuration/BuildSettings.xcconfig`.
  This file intentionally uses placeholder bundle identifiers and no
  development team. `THRURNDIS_PRIVILEGED_HELPER_BUNDLE_IDENTIFIER` must remain
  derived as `$(THRURNDIS_APP_BUNDLE_IDENTIFIER).privileged-helper`.
- For local runtime signing, copy
  `Configuration/LocalSigning.xcconfig.example` to
  `Configuration/LocalSigning.xcconfig` and set the local `DEVELOPMENT_TEAM` and
  app bundle identifier there. The local file is intentionally ignored by Git.
- Release distribution additionally requires a Developer ID Application
  certificate and valid direct-distribution provisioning profiles for both the
  app and Network System Extension. Set their installed profile names in
  `THRURNDIS_APP_DISTRIBUTION_PROVISIONING_PROFILE` and
  `THRURNDIS_NETWORK_EXTENSION_DISTRIBUTION_PROVISIONING_PROFILE`. Release
  uses manual signing so the restricted profiles are deterministic; the export
  options map those profiles only to the app and Network System Extension bundle
  identifiers. The privileged helper is nested command-line code signed with
  the same Developer ID Application team and intentionally has no provisioning
  profile or ExportOptions profile entry. Notary credentials stay in Keychain
  and must never be added to xcconfig files, scripts, or the repository.
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
- The privileged helper must be embedded exactly at
  `Contents/MacOS/ThruRNDISPrivilegedHelper` and enable the hardened runtime.
  Its embedded Info.plist bundle identifier and app-shared marketing/build
  versions must be validated in final app artifacts; they are not a runtime XPC
  protocol.
  Its code-signing identifier, launchd `Label`, and only `MachServices` key must
  equal the derived helper bundle identifier; `BundleProgram` must equal
  `Contents/MacOS/ThruRNDISPrivilegedHelper`. Its team must match the app and
  Network System Extension. Developer ID builds additionally require a secure
  timestamp. Keep its launchd plist template placeholder-based so no personal or
  release bundle identifier is checked in.
- If restricted entitlements are missing from the provisioning profile, the
  runtime path fails. Do not use ad hoc signing as a substitute for restricted
  entitlement runtime validation.

## Development Notes

- The app owns one WireGuard `NETunnelProviderManager` profile and exposes
  Connect, Disconnect, and Refresh controls. Keep `.conf` copy/save as a
  diagnostic fallback; do not hand the persistent private-key files to the
  provider or store plaintext configuration in preferences.
- Dummy Ethernet configuration remains Settings-owned with explicit manual
  Start/Stop/Restart controls. USB-prompt, USB auto-connect, and normal-mode
  menu-bar WireGuard requests are the only additional start paths and must wait
  for Dummy Ethernet to become active before starting the tunnel, then stop it
  only after the tunnel reports that it is connected. Settings and debug-mode
  menu-bar WireGuard requests use the direct connection path and do not start or
  stop Dummy Ethernet. Onboarding may show and manage only its privileged-helper
  permission;
  showing the current helper registration and network state at launch is allowed.
  Initial helper registration requires the explicit Install action. Replacing
  the app bundle requires an explicit Reinstall action, or explicit Remove and
  Install actions, when the registered helper-specific installation identity
  changes, but an app marketing/build version change alone must not require an
  update. Refresh and Start/Stop/Restart must never repair registration
  automatically.
  Do not remove network objects without a user's Stop/Restart action, except
  that application termination stops the managed configuration before exit and
  a confirmed Reset All Settings action removes it before unregistering the
  helper. A Login
  Items approval-required result is a visible recoverable state, not permission
  to bypass `SMAppService` or elevate through another mechanism.
- In normal app-managed mode, require completed onboarding, valid VM Assets, an active
  Network Extension, and the current enabled Dummy Ethernet privileged helper
  immediately before starting or reloading AccessoryAccess monitoring. Do not
  stop an active listener merely because a prerequisite later becomes
  unavailable; evaluate the prerequisites again only for a future start or
  reload. Debug mode bypasses these configuration restrictions, but not the
  AccessoryAccess entitlement or listener-transition safety checks. Settings may
  stop or sequentially reload the listener for the current session, but a later
  app launch requests it again.
  WireGuard Manual Configuration Mode instead requires only completed onboarding and valid
  VM Assets, skips the WireGuard connection prompt/auto-connect path, and omits
  app-managed WireGuard and Dummy Ethernet menu controls.
- Keep USB approval prompts AppKit-presented so they remain visible while all
  windows are closed. The store must serialize USB approval, VM
  start/stop/restart, and VZ attach completions. Preserve the VM-generation and
  USB-operation tokens that prevent callbacks from an earlier VM or attachment
  from mutating the current session.
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
  be requested while the VM or USB passthrough attachment is active: disconnect
  WireGuard first, stop the VM and wait for its USB attachment lifecycle to end,
  delete the WireGuard directory, stop the managed Dummy Ethernet configuration,
  unregister its privileged helper, and then clear the Asset selection. It
  preserves managed Asset releases. If the VM or Dummy Ethernet does not stop,
  WireGuard deletion fails, or helper removal fails, report the error and do not
  restart the app. A successful reset creates fresh key files and a generated
  server config on the next launch.
- Keep WireGuard key material and server configuration read-only. The Connection
  section may edit and persist only the client DNS servers, Endpoint override,
  and Allowed IPs; preview, copy, save/export, and provider connection must all
  use the same typed internal client state built by
  `WireGuardConfigurationBuilder`. Only preview, copy, and save/export render
  that state as a wg-quick configuration.
  Applying edited server configuration to an already-running guest `wg0`
  remains follow-up work.
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
  real RNDIS USB device, and approval in System Settings. Dummy Ethernet runtime
  validation additionally requires the same-team signed helper embedded in the
  app, installation under `/Applications`, administrator approval for the
  `SMAppService` daemon, and inspection of the actual interface, service,
  SCNetworkConfiguration state, and `NWPath.Status.satisfied` result. Install
  the signed app in `/Applications` before testing either activation path.
- Signing/provisioning failures should not block compile builds, UI work, or
  documentation work.
- After code changes, the normal minimum verification is
  `./script/build_and_run.sh --verify`. If launching the app is intentionally
  out of scope or unavailable, run the unsigned build-only Xcode command shown
  above and report that runtime launch was not checked. Changes to signing,
  entitlements, System Extension activation, or other runtime-only behavior
  additionally require `./script/build_and_install.sh` before testing from
  `/Applications/ThruRNDIS.app`.
- A public release artifact must additionally pass
  `./script/package_app.sh`; a compile or RuntimeDebug install does not
  validate Developer ID export, Apple notarization, ticket stapling, or DMG
  Gatekeeper assessment.
