# AGENTS.md

This repository is a macOS 27+ USB RNDIS tethering VM project. Read this file
before changing the app. The current baseline sends macOS IPv4 traffic to the
Linux guest with two privileged host routes through the guest's dynamically
assigned VZNAT address.

## Project Shape

- `ThruRNDIS.xcodeproj` is the Xcode project. `ThruRNDIS` is the menu-bar app
  target and `ThruRNDISPrivilegedHelper` is its embedded command-line helper.
- The app uses an AppKit `NSStatusItem`, SwiftUI Settings, and a small AppKit
  onboarding window. It has no primary `WindowGroup` and is not a CLI tool.
- The helper is embedded at
  `Contents/MacOS/ThruRNDISPrivilegedHelper`; its launchd property list is at
  `Contents/Library/LaunchDaemons/ThruRNDISPrivilegedHelper.plist`.
- `SMAppService.daemon` registers the helper only after an explicit onboarding
  or Settings action. A registered helper is replaced automatically when its
  recorded build differs from the app's `CFBundleVersion`.
- The app bundle is the helper executable's only source. Do not copy the helper
  into `/Library/PrivilegedHelperTools`, add a versioned system copy, or add a
  DriverKit target.
- There is no Network Extension or System Extension target. Do not add an
  app-local packet tunnel, packet relay, synthetic feth pair, bond, or bridge.
- Linux VM assets are not bundled or built here. Published assets come from
  [Afcoo/ThruRNDIS_VM_Assets](https://github.com/Afcoo/ThruRNDIS_VM_Assets).

## Data Path

The IPv4 proof-of-concept data path is:

```text
macOS 0.0.0.0/1 and 128.0.0.0/1 routes
-> dynamically discovered VZNAT guest IPv4 address
-> Linux guest eth0
-> IPv4 forwarding and nftables masquerade
-> Linux guest usb0
-> USB RNDIS upstream
```

- `VMConfigurationFactory` uses `VZNATNetworkDeviceAttachment`, an XHCI USB
  controller, and optional user-managed raw scratch storage. It does not create
  a VirtioFS networking configuration share.
- The guest obtains `eth0` configuration from VZNAT DHCP. It prints these
  machine-readable serial-console markers:
  - `THRURNDIS_VZNAT_IPV4=<guest-ipv4>`
  - `THRURNDIS_VZNAT_CIDR=<connected-cidr>`
  - `THRURNDIS_VZNAT_GATEWAY=<vznat-gateway>`
  - `THRURNDIS_RNDIS_ROUTE_READY=1` only after `usb0` forwarding and NAT are
    ready, and `THRURNDIS_RNDIS_ROUTE_READY=0` when they are not ready.
- The host must not install its `/1` routes from the address marker alone. It
  waits for both a valid guest address and the ready marker.
- `ConsoleSessionStore` parses console markers and `VMCoordinator` forwards the
  address/readiness changes into `NetworkRouteStore`.
- `NetworkRouteStore` reconciles desired routing state. It asks the helper to
  install routes only when the helper is current, the guest address is known,
  and RNDIS is ready. It removes routes when readiness is lost, the VM stops,
  app settings are reset, or the app terminates.
- The helper installs exactly `0.0.0.0/1` and `128.0.0.0/1`. These routes are
  more specific than the existing default route, so the original macOS default
  remains available for reaching the directly connected VZNAT network.
- IPv6 routing is out of scope. Do not claim that this PoC captures or blocks
  IPv6 traffic.

## Host Route Helper Contract

- All host network mutation belongs to `ThruRNDISPrivilegedHelper`. The
  unprivileged app must not execute `route`, `ifconfig`, `networksetup`, or
  another administrative networking tool.
- `NetworkRoutePrivilegedHelperRegistrationService` owns `SMAppService`
  registration. `NetworkRoutePrivilegedHelperClient` owns authenticated NSXPC.
  `NetworkRouteHelperStore` owns helper registration state and actions, while
  `NetworkRouteStore` owns route state and reconciliation.
- A successful `start` keeps that XPC connection alive as the route lease. The
  helper binds cleanup to that connection only after start succeeds, scopes
  invalidation cleanup to its controller lease token, and handles a disconnect
  racing start completion. Status and non-owning stop connections are
  transient. If the active lease breaks, the app clears its guest control path
  and makes one fresh authenticated stop attempt so a restarted helper can
  rediscover and remove the exactly owned routes.
- The shared XPC surface contains only `status`, `start(guestIPv4Address:)`, and
  `stop`. Keep values Foundation/XPC-safe and validate every value again in the
  helper.
- `VZNATInterfaceResolver` accepts only a canonical RFC 1918 IPv4 address. It
  enumerates active, non-loopback, non-point-to-point host IPv4 interfaces and
  requires exactly one directly connected interface whose subnet contains the
  guest address. Ambiguous or missing matches fail closed.
- `RouteCommandRunner` invokes only `/sbin/route` with an argument array and a
  fixed environment. Never add a shell API or arbitrary-command XPC method.
- Route creation is global and unscoped so ordinary macOS route lookups select
  it. It uses the discovered guest address as gateway and both `PROTO1` and
  `PROTO2` flags as the private ownership signature. The resolved VZNAT
  interface is used for validation, and status/removal require the exact
  destination, netmask, gateway, returned interface, and ownership flags to
  match. Do not add `-ifscope` to the managed `/1` routes.
- An unrelated or partially conflicting `/1` route is blocking. Never replace
  or delete a route that does not have the exact ThruRNDIS ownership signature.
- Starting is idempotent for the same exact pair. A changed guest address first
  removes the owned prior pair. Partial installation rolls back only routes
  added by that invocation.
- Do not add an external ownership file. The helper caches the current
  configuration in memory and may rediscover only the exact two routes carrying
  both ownership flags with one consistent gateway/interface after a restart;
  it must not adopt or delete arbitrary routes.
- The helper authenticates the connecting app's signing identifier and team;
  the app authenticates the helper using the corresponding derived identifier
  and team. Keep `PeerCodeSigningRequirementBuilder` shared by both targets.

## App Architecture

- `AppDelegate` is the composition root. It constructs the VM, USB, VM Asset,
  event-log, and route-helper dependencies and injects them into one shared
  `TetheringStore`.
- `TetheringStore` is the app-facing facade for reset ordering, listener
  prerequisites, and cross-feature commands. Independently observable state
  remains in child stores.
- `TetheringWorkflowCoordinator` serializes USB approval, VM preparation, and
  passthrough. It does not create host routes directly.
- `VMCoordinator` owns Virtualization lifecycle and current-console generation
  safety. `USBAccessoryCoordinator` owns AccessoryAccess selection and USB
  passthrough policy.
- `EventLogStore` owns the bounded in-memory log. `EventLogFileStore` serially
  persists logs under Application Support with the established rotation and
  retention policy.
- `ConsoleSessionStore` owns serial-console text and structured marker
  scanning. `USBSessionStore` owns the atomic USB UI snapshot, prompt queue,
  de-duplication, and VM-asset deferral. `VMConfigurationStore` owns persisted
  VM settings and the optional scratch disk.
- Normal operation requires completed onboarding, valid VM Assets, and the
  current enabled route helper before AccessoryAccess monitoring starts or
  reloads. Debug mode may expose controls, but it does not bypass USB
  entitlement or listener-transition safety.
- App reset stops managed routes before unregistering the helper. If route
  removal fails, do not unregister the helper or claim reset success.
- Application termination performs bounded best-effort route cleanup. Explicit
  user operations still surface failures normally.

## USB and VM Lifecycle

- USB passthrough must use an AccessoryAccess `AAUSBAccessory` with
  `VZUSBPassthroughDeviceConfiguration(device:)`.
- A newly available USB device is never attached silently. The app asks first,
  starts the VM when needed, then attaches the approved device.
- One VM boot corresponds to one passthrough attachment lifetime. Manual
  detach, physical disconnect, or passthrough disconnect stops that VM session.
- Preserve VM-generation and USB-operation tokens so callbacks from old
  sessions cannot mutate current state.
- Reset route input state before each VM start. Ignore structured console
  markers from a stale VM generation.
- Do not wait for `usb0` before booting the VM. The guest watcher is responsible
  for late USB attach, detach, and reconnect, and drives the readiness marker.

## VM Asset Installation

- App launch restores and validates local selection without a network request.
  Latest-release lookup begins only after explicit user action.
- The app downloads exactly `vm_assets.zip` and `SHA256SUMS` from the latest
  published VM Assets release, validates reported size and SHA-256, inspects ZIP
  entries, extracts to staging, and promotes atomically.
- ZIP contents must remain under `vm_assets/`; reject absolute paths,
  traversal, duplicates, unexpected roots, and symbolic links.
- Managed assets require regular `vm_assets/Image-lts` and
  `vm_assets/initramfs-thrurndis-lts` files. Manual extracted-folder selection
  and per-file overrides remain supported fallbacks.
- A failed or cancelled install leaves the previous selection active and
  removes partial staging data. Clearing selection preserves managed releases
  and the optional scratch disk.
- VM Asset production, dependency locking, license compliance, and releases
  belong to the VM Assets repository. Do not restore an asset builder or cache
  here.

## Signing and Entitlements

- Checked-in defaults live in `Configuration/BuildSettings.xcconfig`. Personal
  values belong only in ignored `Configuration/LocalSigning.xcconfig`.
- `THRURNDIS_PRIVILEGED_HELPER_BUNDLE_IDENTIFIER` remains derived as
  `$(THRURNDIS_APP_BUNDLE_IDENTIFIER).privileged-helper`.
- The app entitlement files contain only the required runtime capabilities:
  `com.apple.developer.accessory-access.usb` and
  `com.apple.security.virtualization`.
- Do not restore packet-tunnel, Network Extension, System Extension install,
  or application-group entitlements.
- The app's direct-distribution provisioning profile is configured with
  `THRURNDIS_APP_DISTRIBUTION_PROVISIONING_PROFILE`. The command-line helper
  uses no provisioning profile or ExportOptions profile entry.
- The helper enables hardened runtime, shares the app's signing team and
  marketing/build versions, and has a code-signing identifier equal to its
  launchd `Label` and sole `MachServices` key. `BundleProgram` remains
  `Contents/MacOS/ThruRNDISPrivilegedHelper`.
- Increment `CURRENT_PROJECT_VERSION` for every app update so a registered
  older helper is replaced.
- Runtime and distribution validators must reject any embedded
  `.systemextension` and any obsolete network/system-extension entitlement.

## Build and Release

Normal unsigned development:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

Signed Runtime build and installation for USB, Virtualization, helper, and real
route validation:

```sh
./script/build_and_install.sh
```

Developer ID, notarization, and DMG release:

```sh
./script/package_app.sh
```

- `script/build_and_run.sh` is the single normal kill/build/run entrypoint.
- `script/build_and_install.sh` validates the signed app, AccessoryAccess and
  Virtualization entitlements, embedded helper, launchd metadata, team match,
  and absence of System Extensions before installing in `/Applications`.
- `script/build_app.sh` archives and exports the app with one app provisioning
  profile. It keeps the helper outside ExportOptions provisioning profiles.
- `script/support/distribution_common.sh` validates the app, helper, hardened
  runtime, secure timestamps, entitlements, and absence of System Extensions.
- Notarization credentials stay in Keychain. Never put them in the repository.
- The project has no automated test target. Do not add tests or test-only
  production abstractions without separate explicit instructions.
- If signing is unavailable, use the unsigned build and report that signed
  helper/USB runtime behavior was not verified.

## Source Organization

The Xcode project uses explicit groups. Every source add, move, rename, or
delete requires matching file-reference, target-membership, and build-phase
updates.

- `ThruRNDIS/App`: executable composition and lifecycle.
- `ThruRNDIS/Presentation`: AppKit presentation owners.
- `ThruRNDIS/Views`: SwiftUI views; reusable onboarding/Settings rows live in
  `Views/SharedViews`.
- `ThruRNDIS/Coordinators`: long-running workflows and lifecycle owners.
- `ThruRNDIS/Stores`: `@MainActor` observable UI state owners.
- `ThruRNDIS/Persistence`: non-observable durable storage.
- `ThruRNDIS/Services`: external/system adapters, including helper registration
  and NSXPC.
- `ThruRNDIS/Models`: shared values and the narrow helper protocol.
- `ThruRNDIS/Support`: small stateless helpers and platform edges.
- `ThruRNDISPrivilegedHelper`: route controller, resolver, fixed command
  runner, authenticated XPC service, and executable entrypoint only.
- `Configuration`: shared build settings and local-signing template.
- `script`: developer, signing, notarization, and packaging automation only.

Use established Swift naming conventions. Observable state owners end in
`Store`, workflows in `Coordinator`, external operations in `Service`, and
focused transformations or validation in `Resolver`, `Validator`, `Builder`,
or `Formatter`. Keep UI-facing observable owners on `@MainActor`.

## Presentation Rules

- Keep SwiftUI screens concise: label, state, and action first. Add persistent
  copy only when it prevents a likely misconfiguration or explains a real
  permission/safety consequence.
- Keep useful accessibility labels, values, and hints without duplicating them
  as visible prose.
- Any onboarding control also exposed in Settings must reuse the same
  component from `Views/SharedViews`. Both surfaces host shared rows in a
  `Form`; shared components must not introduce a nested `Form`.
- Helper approval is the only networking permission step. Do not present a
  tunnel or System Extension approval workflow.

## Minimum Verification

After relevant changes:

- run `plutil -lint` on project, scheme, plist, and entitlement files;
- run `bash -n` and ShellCheck on changed shell scripts when available;
- run `xcodebuild -list` to verify project and scheme structure;
- run the unsigned app build, or `./script/build_and_run.sh --verify` when
  launching is in scope;
- for signed entitlement/helper changes, run `./script/build_and_install.sh`;
- for public release changes, run the full `./script/package_app.sh` workflow.

Real end-to-end route validation additionally requires macOS 27 beta, approved
AccessoryAccess and Virtualization entitlements, the signed app installed in
`/Applications`, administrator approval for the helper, a real RNDIS device,
and packet/route inspection on both host and guest. Signing availability must
not block compile, UI, or documentation work.
