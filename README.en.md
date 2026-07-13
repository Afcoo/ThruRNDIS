# ThruRNDIS

[한국어](./README.md) | [English](./README.en.md)

A Swift app that lets macOS use the RNDIS protocol used by Android devices for USB tethering.

It uses Virtualization framework USB passthrough to connect an RNDIS device to a Linux VM. macOS then connects to the VM with WireGuard to use the tethering network.

## Requirements

- macOS 27 beta 2 or newer.

## Usage

1. Run `ThruRNDIS.app`.

   If macOS blocks launch, run:

```sh
sudo xattr -dr com.apple.quarantine "/Applications/ThruRNDIS.app"
```

2. Select `Download & Install Latest` during first-run onboarding. The app
   downloads the latest `vm_assets.zip` and `SHA256SUMS` from the
   [VM Asset releases](https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases),
   verifies the checksum and boot files, installs them in Application Support,
   and selects the installation immediately.

3. Connect the USB tethering device to the Mac, then select the VM to use the device from the menu bar.

   <video src="https://github.com/user-attachments/assets/d285ed13-9bf3-4030-ad34-f04cd9de4e34" width="120" controls></video>

4. Press `Start VM`, select the passthrough device in `USB Devices`, and press `Attach`.

   <video src="https://github.com/user-attachments/assets/4d10e732-7510-4555-84c5-1f16ef412a00" width="120" controls></video>

5. Copy or save the host `.conf` from `WireGuard`.

6. Install WireGuard tools.

```sh
brew install wireguard-tools wireguard-go
```

7. Configure WireGuard with the saved `.conf` file.

```sh
sudo wg-quick up ./thrurndis.conf
sudo wg show
# On exit
sudo wg-quick down ./thrurndis.conf
```

The official WireGuard app may currently fail to bring up this connection, so `wireguard-go` is recommended for macOS validation.

## Architecture

```text
macOS host WireGuard client
-> VZNAT UDP/51820
-> Alpine VM wg0
-> nftables masquerade
-> Alpine VM usb0
-> RNDIS USB tethering device
```

- `eth0`: VM VZNAT network used as the host-to-guest WireGuard endpoint path.
- `wg0`: WireGuard overlay. Defaults are guest `10.100.0.1/24` and host `10.100.0.2/24`.
- `usb0`: RNDIS tethering interface inside the VM.

The generated client configuration is an IPv4 full tunnel:

```text
AllowedIPs = 10.100.0.0/24, 0.0.0.0/1, 128.0.0.0/1
```

## VM Assets

The normal installation path is `Download & Install Latest` during onboarding,
or `VM Assets` > `Check & Install Latest` in Settings. The app checks for a
release only after an explicit button press; it does not update in the
background or retry automatically.

The app finds exactly one attachment named `vm_assets.zip` and one named
`SHA256SUMS` in the latest published `Afcoo/ThruRNDIS_VM_Assets` release. It
first stores both files in:

```text
~/Library/Application Support/<bundle-id>/VMAssets/.staging/<operation-id>/
```

It compares each downloaded size with the size reported by the GitHub release,
then compares the `vm_assets.zip` entry in `SHA256SUMS` with the SHA-256 it
calculates locally. Archive entries outside the `vm_assets/` root, path
traversal, duplicate paths, and symbolic links are rejected. After extraction,
the app requires regular `Image-lts` and `initramfs-thrurndis-lts` files and
atomically installs the release at:

```text
~/Library/Application Support/<bundle-id>/VMAssets/Releases/<release-id>-<asset-id>/
├── install.json
└── vm_assets/
    ├── Image-lts
    └── initramfs-thrurndis-lts
```

An already-installed release and asset are reused without another download.
The previous managed release is removed only after a new installation has been
activated. A failed or cancelled download, verification, extraction, or
activation cleans up staging and preserves the previous selection. `Clear`
clears only the selection; it does not delete managed release files.

If automatic installation is unavailable, download `vm_assets.zip` and
`SHA256SUMS` from the releases page, verify the checksum, extract the archive,
and select the extracted `vm_assets` folder with `Choose Asset Folder…` during
onboarding or `Choose Folder…` in Settings. `Asset Overrides` in Settings can
also replace the kernel or initramfs individually.

VM Asset releases contain no WireGuard keys or configuration. The app creates
and manages those separately under the Application Support `WireGuard/`
directory. The scratch disk in `Optional Storage` is also a separate,
user-selected file; updating or clearing the managed VM Asset selection does
not change it.

In the code, the app-wide `VMAssetController` owns installation state and the
UI workflow. Injected services separately own release lookup, download,
verification/installation, and selection persistence. `TetheringStore` receives
only validated boot files through `VMAssetProviding` immediately before VM
start, while continuing to own scratch-disk selection separately.

## Build

For a normal UI and compile check:

```sh
./script/build_and_run.sh
```

For runtime signing validation:

```sh
cp Configuration/LocalSigning.xcconfig.example Configuration/LocalSigning.xcconfig
./script/build_and_run.sh --runtime
```

Put your local `DEVELOPMENT_TEAM` and bundle identifier in `Configuration/LocalSigning.xcconfig`.

VM Asset production and GitHub Release publication belong to the separate
[`Afcoo/ThruRNDIS_VM_Assets`](https://github.com/Afcoo/ThruRNDIS_VM_Assets)
repository.

## Layout

- `ThruRNDIS/App`: app entrypoint and AppKit menu-bar/window integration.
- `ThruRNDIS/Controllers`: VM Asset UI state and installation workflow.
- `ThruRNDIS/Coordinators`: VM lifecycle and USB passthrough orchestration.
- `ThruRNDIS/Services`: VM Asset release/download/install, USB monitoring, and VM configuration.
- `ThruRNDIS/Stores`: app state and VM Asset selection persistence.
- `ThruRNDIS/Support`: VM Asset folder validation, WireGuard configuration storage,
  file picker, and runtime helpers.
- `ThruRNDIS/Views`: onboarding, Settings, and console UI.
- `script`: app build/run/debug and host WireGuard validation helpers.
- `Configuration`: signing configuration templates.
