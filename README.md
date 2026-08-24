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
- AccessoryAccess and LaunchDaemon permissions

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
4. **Optional TCP and UDP port forwarding:** In **Settings → Network**,
   turn on **Enable Port Forwarding**, then enter comma-separated ports and
   hyphenated ranges such as `80,443,47980-48000`. TCP and UDP always use the same
   ports, with no port-number translation. Once forwarding and the managed
   network are active, the Status row shows the RNDIS IPv4 address listening
   for forwarded traffic. Stop the VM to change the set.

## How It Works

> This POC requires VM Assets built from the matching
> `poc/feth-vm-networking` branch; the latest published VM Assets may still use
> the previous network contract.

```text
macOS managed IPv4 routes and DNS
-> Ethernet Bond (192.168.100.2)
-> feth0 <-> feth1
-> VM-created VZNAT bridge
-> Linux VM eth0 (192.168.100.1)
-> policy routing and nftables masquerade
-> Linux VM usb0
-> RNDIS USB tethering device
```

*Reference: [`Virtualization Framework: VZUSBPassthroughDevice`](https://developer.apple.com/documentation/virtualization/vzusbpassthroughdevice)*

ThruRNDIS runs a lightweight Linux VM and passes the RNDIS device connected to macOS through to the VM using USB passthrough.

For this proof of concept, the privileged helper creates an Ethernet Bond and a paired `feth0`/`feth1` link. After the VM reports its VZNAT address, the helper resolves the bridge created for that VM, adds `feth1` as a bridge member, and installs the two managed `/1` IPv4 routes through the guest.

The guest owns `192.168.100.1`, forwards traffic arriving from the Bond through the USB RNDIS interface, and provides DNS forwarding using the live RNDIS lease. WireGuardKit and the Network System Extension are not part of this path.

Optional port forwarding is fixed before each VM start. The app passes one
validated `thrurndis.port_forward=<ports>` kernel argument. The guest creates
one nftables interval set and uses it for matching TCP and UDP DNAT, forward,
and source-NAT rules. DNAT changes only the destination address to
`192.168.100.2`, preserving each original destination port. Changing or
disabling the set takes effect on the next VM start.

## License

ThruRNDIS source code is distributed under the [MIT License](./LICENSE.txt).
