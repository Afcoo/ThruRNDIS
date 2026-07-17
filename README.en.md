# ThruRNDIS: USB Tethering via VM USB Passthrough

[한국어](./README.md) | [English](./README.en.md)


<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./images/introduction-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./images/introduction-light.png">
  <img alt="ThruRNDIS — Bring Android USB tethering to your Mac" src="./images/introduction-light.png">
</picture>

## Overview

ThruRNDIS is a Swift app based on the Virtualization framework that enables Android RNDIS USB tethering on macOS.

## Requirements

- macOS 27 beta 2 or later
- A device that supports RNDIS USB tethering (ex. an Android device)
- An internet connection to download the VM Assets on first launch

## How It Works

```text
ThruRNDIS WireGuard Network System Extension
-> VZNAT guest endpoint UDP/<ListenPort>
-> Linux VM wg0
-> nftables masquerade
-> Linux VM usb0
-> RNDIS USB tethering device
```

*Reference: [`Virtualization Framework: VZUSBPassthroughDevice`](https://developer.apple.com/documentation/virtualization/vzusbpassthroughdevice)*

ThruRNDIS runs a lightweight Linux VM and passes the RNDIS device connected to macOS through to the VM using USB passthrough.

macOS and the VM are connected by a WireGuard tunnel over VZNAT, and the VM forwards macOS traffic received through WireGuard to the recognized RNDIS device.

## How to Use

### ThruRNDIS

1. Download the app from the [latest ThruRNDIS release](https://github.com/Afcoo/ThruRNDIS/releases/latest).
2. Unzip it, move `ThruRNDIS.app` to `/Applications`, and launch it. ThruRNDIS runs in the menu bar rather than the Dock.

---

### VM Assets

VM Assets consist of an Alpine Linux-based kernel and a RAM disk for running the gateway program.

ThruRNDIS installs and activates prebuilt VM Assets from the [VM Assets releases](https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases).

You can also use a kernel and RAM disk that you built yourself.

---

### WireGuard

Enable USB tethering on the Android device and connect it, then approve the device in ThruRNDIS and start the VM.

Once the VM endpoint appears, choose **Connect WireGuard** in WireGuard Settings or the menu bar. Choose **Disconnect WireGuard** to end the connection. ThruRNDIS manages the WireGuard connection through its embedded Network System Extension.

## License

ThruRNDIS source code is distributed under the [MIT License](./LICENSE.txt).
