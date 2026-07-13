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
   downloads and installs the latest VM Asset from the
   [VM Asset releases](https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases),
   then selects the installation immediately.

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

VM Assets come from the
[Afcoo/ThruRNDIS_VM_Assets](https://github.com/Afcoo/ThruRNDIS_VM_Assets)
repository's [Releases](https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases).

You can also manually select a VM Asset folder containing your own kernel and
initramfs. With an existing VM Asset selected, Settings > `Asset Overrides`
lets you choose the kernel and initramfs files individually.

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
