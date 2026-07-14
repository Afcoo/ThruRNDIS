# ThruRNDIS: USB Tethering via VM USB Passthrough

[한국어](./README.md) | [English](./README.en.md)


> [!WARNING]
> The current WireGuard connection works correctly **only with `wg-quick`.** The official WireGuard macOS app may fail to bring up this connection.
>
> ThruRNDIS does not yet install, start, stop, or manage the WireGuard tunnel itself.


<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./images/introduction-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./images/introduction-light.png">
  <img alt="ThruRNDIS — Bring Android USB tethering to your Mac" src="./images/introduction-light.png">
</picture>

## Overview

ThruRNDIS is a Swift app that uses the Virtualization framework's USB passthrough feature to enable Android RNDIS USB tethering on macOS.

## Requirements

- macOS 27 beta 2 or later
- An Android device that supports RNDIS USB tethering and a data-capable USB cable
- An internet connection to download the VM Assets on first launch
- [`wg-quick`](https://www.wireguard.com/quickstart/) for the network connection

## How It Works

```text
macOS WireGuard client
-> VZNAT guest endpoint UDP/<ListenPort>
-> Linux VM wg0
-> nftables masquerade
-> Linux VM usb0
-> RNDIS USB tethering device
```

ThruRNDIS runs a lightweight Linux VM and passes the Android RNDIS device connected to macOS through to the VM using USB passthrough. The VM recognizes it as a standard USB network device and uses Android USB tethering as its internet connection.

macOS connects to the VM over WireGuard and sends traffic to it. The VM forwards that traffic through the passed-through RNDIS device, acting as a gateway.

## Download

### ThruRNDIS

1. Download the app from the [latest ThruRNDIS Release](https://github.com/Afcoo/ThruRNDIS/releases/latest).
2. Unzip it, move `ThruRNDIS.app` to `/Applications`, and launch it. ThruRNDIS runs in the menu bar rather than the Dock.

Older versions and release notes are available on the [Releases page](https://github.com/Afcoo/ThruRNDIS/releases).

### VM Assets

VM Assets consist of an Alpine Linux-based kernel and a RAM disk for running the gateway program.

ThruRNDIS installs and activates prebuilt VM Assets from [VM Asset Releases](https://github.com/Afcoo/ThruRNDIS_VM_Assets).

You can also use a kernel and RAM disk that you built yourself.

### WireGuard Connection

Install the WireGuard tools.

```sh
brew install wireguard-tools wireguard-go
```

Enable USB tethering on the Android device and connect it, then approve the device in ThruRNDIS and start the VM. Once the VM endpoint appears, save the host `.conf` from the WireGuard screen and connect with `wg-quick`.

```sh
sudo wg-quick up ./thrurndis.conf
sudo wg show

# Disconnect
sudo wg-quick down ./thrurndis.conf
```

## License

ThruRNDIS source code is distributed under the [MIT License](./LICENSE.txt).
