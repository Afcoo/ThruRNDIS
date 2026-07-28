# Contributing to ThruRNDIS

Thank you for helping improve ThruRNDIS. The project is a macOS 27+ menu-bar
app that uses a WireGuard Network System Extension, a Virtualization framework
Linux VM, and public AccessoryAccess USB passthrough APIs.

Before making a substantial change, read [AGENTS.md](AGENTS.md). It documents
the current architecture, ownership boundaries, build paths, signing
requirements, and verification expectations.

## Before opening an issue

- Use the Bug Report form for a reproducible defect.
- Use the Feature Request form to describe a user problem and desired outcome.
- Use [GitHub Discussions](https://github.com/Afcoo/ThruRNDIS/discussions)
  for installation, usage, or troubleshooting help.
- Search existing issues before opening a new one.
- Report guest kernel, initramfs, or published VM Asset problems in
  [Afcoo/ThruRNDIS_VM_Assets](https://github.com/Afcoo/ThruRNDIS_VM_Assets/issues).
- Report suspected security vulnerabilities privately according to
  [SECURITY.md](SECURITY.md). Do not open a public issue.

Never attach WireGuard private keys, complete client configurations,
provisioning profiles, signing credentials, notary credentials, or other
secrets. Redact personal paths and device identifiers from logs when they are
not needed to reproduce a problem.

## Architecture boundaries

The supported data path is:

```text
ThruRNDIS WireGuardKit Network System Extension
-> VZNAT guest endpoint
-> guest WireGuard interface
-> guest nftables masquerade
-> USB RNDIS upstream
```

Changes that replace this path with an app-local packet relay, vmnet, bridged
networking, or route-command UI are outside the current architecture. Propose
an architecture change in an issue before implementing it.

Keep these boundaries intact:

- USB passthrough uses an AccessoryAccess `AAUSBAccessory` with the public
  `VZUSBPassthroughDeviceConfiguration(device:)` API.
- The app does not inspect or relay packet payloads.
- Client private keys are not persisted in tunnel-provider configuration or
  shared with the guest.
- Guest VM scripts, dependency locking, and VM Asset release tooling belong in
  `Afcoo/ThruRNDIS_VM_Assets`, not this repository.
- Personal signing values and `Configuration/LocalSigning.xcconfig` must not be
  committed.

## Development setup

Use Xcode beta and the project-local unsigned workflow for normal development:

```sh
./script/build_and_run.sh
```

The normal minimum verification after a code change is:

```sh
./script/build_and_run.sh --verify
```

Run relevant XCTest coverage for the code you change. Real USB passthrough,
Virtualization, Network System Extension activation, and WireGuard runtime
validation require the signed Runtime build, approved entitlements, and
appropriate hardware:

```sh
./script/build_and_install.sh
```

Do not treat unavailable signing as a blocker for compile, UI, documentation,
or unit-test work. Clearly state which checks were run and which runtime paths
were not verified.

The full Developer ID, notarization, and DMG workflow is required only for a
public release:

```sh
./script/package_app.sh
```

## Code organization

Follow the layer ownership and Swift naming conventions in `AGENTS.md`.
Observable UI state belongs in stores, long-running workflows in coordinators,
external operations in services, and stateless transformations in focused
helpers.

The Xcode project uses explicit groups. When adding, moving, renaming, or
deleting Swift files, update the matching Xcode group, target membership, and
build phase.

## Commits and pull requests

Keep each pull request focused on one concern. Small documentation and
maintenance pull requests do not need a separate issue; behavior changes and
larger designs should link one with `Closes #123` when applicable.

Pull request titles use Conventional Commits syntax:

```text
feat(wireguard): validate endpoint overrides
fix(usb): serialize detach handling
docs: clarify Runtime signing
```

Allowed types are `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`,
`chore`, `perf`, and `revert`. Use a short lowercase scope when it adds useful
context. Add `!` before the colon for an intentional breaking change.

Complete the pull request template, describe architecture and security impact,
and include:

- tests and commands that were run;
- untested runtime paths and the reason they were not tested;
- screenshots for visible UI changes;
- documentation updates for user-facing or operational changes.

The intended merge strategy is squash merge so that the validated pull request
title becomes the commit on `main`.
