# AGENTS.md

This repository is a macOS 27+ USB RNDIS tethering VM project. Read this file
before changing the app. This proof-of-concept sends macOS IPv4 traffic through
an owned Ethernet Bond and feth pair whose peer is added to the bridge created
for the VM's VZNAT attachment.

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
  app-local packet tunnel or packet relay.
- Linux VM assets are not bundled or built here. Published assets come from
  [Afcoo/ThruRNDIS_VM_Assets](https://github.com/Afcoo/ThruRNDIS_VM_Assets).

## Data Path

The IPv4 proof-of-concept data path is:

```text
macOS managed IPv4 Network Service
-> Ethernet Bond at 192.168.100.2/24
-> owned feth0 <-> feth1 pair
-> VM-created VZNAT bridge containing feth1
-> Linux guest eth0 at 192.168.100.1/24
-> IPv4 forwarding and nftables masquerade
-> Linux guest usb0
-> USB RNDIS upstream
```

- `VMConfigurationFactory` uses `VZNATNetworkDeviceAttachment`, an XHCI USB
  controller, optional user-managed raw scratch storage, and the interactive
  `hvc0` serial console. It does not create a second Virtio control port or a
  VirtioFS networking configuration share.
- The guest obtains `eth0` configuration from VZNAT DHCP. It prints these
  machine-readable serial-console markers:
  - `THRURNDIS_VZNAT_IPV4=<guest-ipv4>`
  - `THRURNDIS_VZNAT_CIDR=<connected-cidr>`
  - `THRURNDIS_VZNAT_GATEWAY=<vznat-gateway>`
  - `THRURNDIS_RNDIS_IPV4=<rndis-ipv4>` reports the canonical IPv4 address
    assigned to `usb0` immediately before readiness. An empty value clears a
    previously reported address during rebuild or teardown.
  - `THRURNDIS_RNDIS_ROUTE_READY=1` only after `usb0` forwarding and NAT are
    ready, and `THRURNDIS_RNDIS_ROUTE_READY=0` when they are not ready.
  - `THRURNDIS_PORT_FORWARD_STATE=inactive`,
    `pending:<ports>`, or `active:<ports>` reports the optional paired TCP/UDP
    DNAT state. `error:<code>` reports a rejected or failed boot configuration.
- `PortForwardingStore` persists one optional port set shared by TCP and UDP.
  The Settings field accepts comma-separated ports and inclusive hyphenated
  ranges such as `5050,6550-6557`, validates every port in `1...65535`, and
  canonicalizes sorted, overlapping, adjacent, and duplicate entries. Before
  VM construction,
  `VMConfigurationStore` removes any user-supplied value for the reserved
  setting and `PortForwardingStore` appends exactly one
  `thrurndis.port_forward=<ports>` kernel argument when the
  feature is enabled. The guest's sourced `port-forwarding` module parses that
  immutable boot value and validates the canonical port set again; the gateway
  remains the sole nftables mutator.
- When enabled and RNDIS forwarding is ready, the guest always DNATs matching
  TCP and UDP ingress on `usb0` to macOS `192.168.100.2` without translating
  the destination port. Both protocols reference one owned nftables interval
  set, are admitted toward `eth0`, and are SNATed to guest `192.168.100.1`.
  This is guest nftables state, not a new privileged-helper XPC operation.
- The guest also assigns `192.168.100.1/24` to `eth0`. The host Bond owns
  `192.168.100.2/24`; `feth1` remains unaddressed and carries Ethernet frames
  only after the helper adds it to the resolved VM bridge.
- The host must not activate its managed Network Service from the address
  marker alone. It waits for a valid guest VZNAT address, the matching VZNAT
  gateway marker, and the ready marker.
- `ConsoleSessionStore` parses console markers. `TetheringStore` forwards the
  VZNAT and RNDIS address/readiness changes into `NetworkRouteStore` and paired
  TCP/UDP port-forwarding markers into `PortForwardingStore`. Settings includes
  the RNDIS IPv4 address in the port forwarding status only while both the
  matching guest rules and managed host network are active.
- `NetworkRouteStore` reconciles desired networking state. It asks the helper
  to create the Bond/feth/bridge path and configure the owned Network Service
  only when the helper is current, the guest VZNAT address and gateway are
  known, and RNDIS is ready. It disables and removes that service and the owned
  interfaces when readiness is lost, the VM stops, app settings are reset, or
  the app terminates.
- Outside debug mode, a successful USB passthrough attachment arms one automatic
  managed-network start. In debug mode, only an attachment accepted through the
  detected-device prompt arms that start; remembered Auto Connect attachments
  and attachments requested from the Settings USB list or menu bar leave routing
  stopped for an explicit Start.
  Status refreshes from Settings, app activation, helper health, or the menu bar
  are read-only and must not retry a failed start. An eligible new USB attach or
  an explicit Start action may arm another attempt; Stop preserves current guest
  inputs so the user can start again without restarting the VM.
- The helper gives its owned Network Service a manual IPv4 address, subnet,
  router, and DNS configuration, and places that service first in the current
  network set. It does not configure `AdditionalRoutes`.
  SystemConfiguration/configd owns default-route synthesis, ranking,
  installation, and removal.
- IPv6 routing is out of scope. Do not claim that this PoC captures or blocks
  IPv6 traffic.

## Host Network Helper Contract

- All host network mutation belongs to `ThruRNDISPrivilegedHelper`. The
  unprivileged app must not execute `route`, `ifconfig`, `networksetup`, or
  another administrative networking tool.
- `NetworkRoutePrivilegedHelperRegistrationService` owns `SMAppService`
  registration. `NetworkRoutePrivilegedHelperClient` owns authenticated NSXPC.
  `NetworkRouteHelperStore` owns helper registration state and actions, while
  `NetworkRouteStore` owns Bond/feth/bridge/route state and reconciliation.
- A successful `start` keeps that XPC connection alive as the managed-network
  lease. The helper binds cleanup to that connection only after start succeeds,
  scopes
  invalidation cleanup to its controller lease token, and handles a disconnect
  racing start completion. Status and non-owning stop connections are
  transient. If the active lease breaks, the app clears its guest control path
  and makes one fresh authenticated stop attempt so a restarted helper can
  rediscover and remove the exactly recorded SystemConfiguration objects.
- The shared XPC surface contains only `status`,
  `start(guestIPv4Address:vznatGatewayIPv4Address:)`, and `stop`. Keep values
  Foundation/XPC-safe and validate every value again in the helper.
- `VZNATInterfaceResolver` accepts only canonical RFC 1918 guest and gateway
  addresses. It enumerates active host IPv4 interfaces and requires exactly
  one canonical `bridge<number>` whose link type is `IFT_BRIDGE`, whose address
  equals the reported gateway, and whose subnet contains the guest. Ambiguous
  or missing matches fail closed.
- The helper creates only the validated `feth0`/`feth1` pair, leaves `feth1`
  unaddressed, creates its recorded SCBond and Network Service, adds `feth1`
  to the resolved VM bridge with `/sbin/ifconfig`, and assigns the Bond
  `192.168.100.2/24` with router and DNS `192.168.100.1`. The Network Service
  is placed first in the current network set while the relative order of all
  other services is preserved.
- Runtime Bond inspection uses `ifconfig -b <bond>` so both the static mode and
  exact feth member are verified before the helper grants the network lease.
- Host routing uses only the owned SystemConfiguration Network Service. Do not
  add `AdditionalRoutes`, restore `/sbin/route`, `netstat` parsing,
  `networksetup`, a routing-socket mutator, per-route ownership flags, or
  private SystemConfiguration symbols.
- `NetworkRouteSystemConfigurationService` orchestrates the owned Bond and
  Network Service lifecycle and validates the persisted manual IPv4
  configuration. `SystemConfigurationPreferencesTransaction` owns preference
  locking, commit, and apply behavior.
- Readiness requires the recorded Network Service to be enabled and its
  persisted IPv4 protocol dictionary to contain the exact managed
  address, subnet, and router configuration. It does not inspect explicit
  routes or acknowledge the kernel route table; SystemConfiguration/configd
  remains responsible for default-route application, ranking, reconciliation,
  and conflict handling.
- Activation failure rolls back by disabling the owned Network Service through
  a fresh SCPreferences transaction. Do not add route-specific repair or
  rollback beside configd.
- Do not add an external ownership file. Store the allocated Bond, Network
  Service, and dynamic VZNAT bridge/guest values in one SystemConfiguration
  ownership value. The feth names and managed addresses are fixed constants
  and are not duplicated in metadata. The recorded Network Service ID is also
  stored as a private option on the owned Bond. Treat a Bond as owned only when
  its name and token match and the recorded service, when present, attaches to
  that same object; a same-named Bond alone is never proof of ownership. Keep
  that validation locked through runtime Bond mutation. After restart, remove
  only those exact recorded objects; never scan for or adopt same-named objects.
- Cleanup first disables the recorded Network Service so configd withdraws its
  IPv4 configuration. It then removes `feth1` from the recorded bridge when
  that bridge still exists, detaches and destroys the owned feth pair, and
  removes the recorded service, Bond, and ownership metadata in one
  SCPreferences transaction. A VM bridge that already disappeared is treated
  as an absent membership, not as authority to touch another bridge.
- The one-time 0.3 migration may remove objects recorded under
  `ThruRNDIS.DummyEthernet.Configuration` only after validating the exact
  Network Service, Bond identity, runtime member, and feth peer relationship.
  Ambiguous legacy state is retained and blocks migration completion.
- The helper authenticates the connecting app's signing identifier and team;
  the app authenticates the helper using the corresponding derived identifier
  and team. Keep `PeerCodeSigningRequirementBuilder` shared by both targets.

## App Architecture

- `AppDelegate` is the composition root. It constructs the VM, USB, VM Asset,
  event-log, and network-helper dependencies and injects them into one shared
  `TetheringStore`.
- `TetheringStore` is the app-facing facade for reset ordering, listener
  prerequisites, and cross-feature commands. Independently observable state
  remains in child stores.
- `TetheringWorkflowCoordinator` serializes USB approval, VM preparation, and
  passthrough. It does not create host networking directly.
- `VMCoordinator` owns Virtualization lifecycle and current-console generation
  safety. `USBAccessoryCoordinator` owns AccessoryAccess selection and USB
  passthrough policy.
- `EventLogStore` owns the bounded in-memory log. `EventLogFileStore` serially
  persists logs under Application Support with the established rotation and
  retention policy.
- `ConsoleSessionStore` owns serial-console text and structured marker
  scanning. `USBSessionStore` owns the atomic USB UI snapshot, prompt queue,
  de-duplication, and VM-asset deferral. `AppPreferencesStore` owns the persisted
  set of Auto Connect reconnect identities with other application preferences.
  `VMConfigurationStore` owns persisted VM settings and the optional scratch disk.
- Normal operation requires completed onboarding, valid VM Assets, and the
  current enabled network helper before AccessoryAccess monitoring starts or
  reloads. Debug mode may expose controls, but it does not bypass USB
  entitlement or listener-transition safety.
- App reset stops the managed network before unregistering the helper. If
  cleanup fails, do not unregister the helper or claim reset success.
- Application termination performs bounded best-effort network cleanup. Explicit
  user operations still surface failures normally.

## USB and VM Lifecycle

- USB passthrough must use an AccessoryAccess `AAUSBAccessory` with
  `VZUSBPassthroughDeviceConfiguration(device:)`.
- A newly available USB device normally requires approval before the app starts
  the VM and attaches it. The sole silent exception is a device whose unique,
  persisted `USBAccessoryReconnectIdentity` is enabled for Auto Connect. When
  multiple enabled devices are detected together, the first availability event
  wins one deferred-turn evaluation through the same serialized attachment
  workflow. Auto Connect proceeds only when no accessory owns the current VM
  session; an unavailable or ambiguous identity fails closed without a later
  automatic retry.
- One VM boot corresponds to one passthrough attachment lifetime. Manual
  detach, physical disconnect, or passthrough disconnect stops that VM session.
- Preserve VM-generation and USB-operation tokens so callbacks from old
  sessions cannot mutate current state.
- Reset network input state before each VM start. Ignore structured console
  markers from a stale VM generation.
- Freeze the persisted paired TCP/UDP port set before each VM start and encode
  its canonical comma/range expression into the boot command line. The controls
  remain read-only for the entire VM lifetime; changing the set requires
  stopping and starting the VM. Invalid input blocks VM start. A stopped VM
  retains the preference but never claims the mapping is active.
- Do not wait for `usb0` before booting the VM. The guest watcher is responsible
  for late USB attach, detach, and reconnect, and drives the readiness marker.

## VM Asset Installation

- App launch restores and validates local selection without a network request.
  Release-list lookup begins only after explicit user action.
- The app follows the VM Assets Release list pagination and selects the newest
  `created_at` value among published, non-prerelease Releases whose tag begins
  with `V1-`. It never falls back to `/releases/latest` or a legacy
  tag. From the selected Release it downloads exactly `vm_assets.zip` and
  `SHA256SUMS`, validates reported size and SHA-256, inspects ZIP entries,
  extracts to staging, and promotes atomically.
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
- Treat `CURRENT_PROJECT_VERSION` as the identity of a distinct installed or
  published app update, not as a build-invocation counter. Do not increment it
  for repeated local builds, unsigned Debug builds, or test retries for the
  same update. Increment it once when preparing a distinct signed app update
  for installation or distribution so a registered older helper is replaced.
  During same-build local signed iteration, manually Reinstall the Network
  Helper after changing it; increment the build number only when specifically
  validating automatic version-driven helper replacement.
- Runtime and distribution validators must reject any embedded
  `.systemextension` and any obsolete network/system-extension entitlement.

## Build and Release

Normal unsigned development:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

Signed Runtime build and installation for USB, Virtualization, helper, and real
Bond/feth/bridge validation:

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
- `ThruRNDISPrivilegedHelper`: network controller, SystemConfiguration owner,
  resolver, fixed command runners, authenticated XPC service, and executable
  entrypoint only.
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

Real end-to-end network validation additionally requires macOS 27 beta, approved
AccessoryAccess and Virtualization entitlements, the signed app installed in
`/Applications`, administrator approval for the helper, a real RNDIS device,
and Bond/feth/bridge inspection plus configd-managed Network Service behavior
on host and guest. This POC mutates
the implementation bridge created by VZNAT; that bridge identity and lifetime
are not a stable Virtualization framework API contract. Signing availability
must not block compile, UI, or documentation work.
