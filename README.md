<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./images/icon-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="./images/icon-light.png">
    <img alt="ThruRNDIS app icon" src="./images/icon-light.png" width="128">
  </picture>
</p>

<h1 align="center">ThruRNDIS</h1>
<p align="center">Bring RNDIS Tethering to macOS</p>

<p align="center">
  <a href="https://github.com/Afcoo/ThruRNDIS/releases/latest"><img src="https://img.shields.io/github/v/release/Afcoo/ThruRNDIS?display_name=tag&label=latest&style=flat" alt="Latest version"></a>
  <a href="https://github.com/Afcoo/ThruRNDIS/releases"><img src="https://img.shields.io/github/downloads/Afcoo/ThruRNDIS/total?label=downloads&style=flat" alt="Downloads"></a>
  <a href="./LICENSE.txt"><img src="https://img.shields.io/github/license/Afcoo/ThruRNDIS?style=flat" alt="License"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/macOS-27%2B-000000?logo=apple&logoColor=white&style=flat" alt="Supported macOS: 27 or later"></a>
</p>

<p align="center">
  <a href="./README.md">English</a> | <a href="./README.ko.md">한국어</a>
</p>

## Overview

ThruRNDIS is a Swift app based on the Virtualization framework that enables Android RNDIS USB tethering on macOS.

## Requirements

- macOS 27 beta 2 or later
- A device that supports RNDIS USB tethering (ex. an Android device)
- An internet connection to download the VM Assets on first launch

## Installation

### GitHub Releases

[Latest ThruRNDIS release](https://github.com/Afcoo/ThruRNDIS/releases/latest)

### Homebrew

```sh
brew install --cask afcoo/tap/thrurndis
```

## How to Use

1. **Install VM Assets:** Install the latest VM Assets during onboarding or in Settings.
2. **Pass through the USB device:** In **Virtual Machine Accessories** in the menu bar, connect the USB device to **ThruRNDIS**.

   ![Passing a USB device to ThruRNDIS from Virtual Machine Accessories](./images/accessory-access-onboarding.gif)

3. **Confirm the USB device connection:** Approve the connection in the USB device connection pop-up.
4. **Confirm the WireGuard connection:** Approve the connection in the WireGuard connection pop-up.

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

ThruRNDIS uses a [modified `wireguard-apple` fork](https://github.com/Afcoo/wireguard-apple/tree/thrurndis-vznat-bind) to establish the WireGuard tunnel over VZNAT.

## License

ThruRNDIS source code is distributed under the [MIT License](./LICENSE.txt).
