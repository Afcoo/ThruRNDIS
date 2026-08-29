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
  <a href="https://github.com/Afcoo/ThruRNDIS/releases/latest"><img src="https://img.shields.io/github/v/release/Afcoo/ThruRNDIS?display_name=tag&label=release&logo=github&style=flat" alt="Latest version"></a>
  <a href="https://github.com/Afcoo/ThruRNDIS/stargazers"><img src="https://img.shields.io/github/stars/Afcoo/ThruRNDIS?style=social" alt="GitHub stars"></a>
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

- macOS 27 or later
- AccessoryAccess, Virtualization, and LaunchDaemon permissions

## Installation

### GitHub Releases

[Latest ThruRNDIS release](https://github.com/Afcoo/ThruRNDIS/releases/latest)

### Homebrew

```sh
brew install --cask afcoo/tap/thrurndis
```

## How to Use

1. **Install VM Assets:** Install the latest compatible VM Assets during onboarding or in Settings.
2. **USB device passthrough:** In **Virtual Machine Accessories** in the menu bar, connect the USB device to **ThruRNDIS**.

   ![Passing a USB device to ThruRNDIS from Virtual Machine Accessories](./images/accessory-access-onboarding.gif)

3. **(Optional) Port forwarding:** Before connecting the device, configure the TCP/UDP ports to expose through the RNDIS device in **Settings → Network Routing**.
4. **Confirm the USB device connection:** Approve the connection in the USB device connection pop-up.

## How It Works

> [!WARNING]
> ThruRNDIS 0.4.0+ does not use WireGuard.

```text
[macOS]
IPv4 routes
→ Ethernet Bond
→ feth0 (Bond member) ↔ feth1 (VZNAT bridge member)
  ⌃
  │ VZNAT bridge
  ⌄
[Linux VM]
eth0
→ IPv4 forwarding + nftables masquerade
→ usb0
  ⌃
  │ USB passthrough
  ⌄
[RNDIS Device]
```

*Reference: [`Virtualization Framework: VZUSBPassthroughDevice`](https://developer.apple.com/documentation/virtualization/vzusbpassthroughdevice)*

ThruRNDIS runs a lightweight Linux VM and passes the RNDIS device connected to macOS through to the VM using USB passthrough.

ThruRNDIS's Network Helper configures an Ethernet Bond and feth pair and attaches the feth peer to the VM's VZNAT bridge so that macOS IPv4 traffic is routed through the VM. The VM forwards this traffic and applies NAT masquerade before sending it through the USB RNDIS interface.

TCP/UDP port forwarding is handled by nftables DNAT/SNAT rules in the Linux VM, which forward matching RNDIS traffic to macOS without changing the destination port.

## License

ThruRNDIS source code is distributed under the [MIT License](./LICENSE.txt).
