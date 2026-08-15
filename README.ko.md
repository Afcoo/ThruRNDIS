<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./images/icon-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="./images/icon-light.png">
    <img alt="ThruRNDIS 앱 아이콘" src="./images/icon-light.png" width="128">
  </picture>
</p>

<h1 align="center">ThruRNDIS</h1>
<p align="center">RNDIS 테더링을 macOS로</p>

<p align="center">
  <a href="https://github.com/Afcoo/ThruRNDIS/releases/latest"><img src="https://img.shields.io/github/v/release/Afcoo/ThruRNDIS?display_name=tag&label=release&style=flat" alt="최신 버전"></a>
  <a href="https://github.com/Afcoo/ThruRNDIS/releases"><img src="https://img.shields.io/github/downloads/Afcoo/ThruRNDIS/total?label=downloads&style=flat" alt="다운로드 수"></a>
  <a href="./LICENSE.txt"><img src="https://img.shields.io/github/license/Afcoo/ThruRNDIS?style=flat" alt="라이선스"></a>
  <a href="#요구-사항"><img src="https://img.shields.io/badge/macOS-27%2B-000000?logo=apple&logoColor=white&style=flat" alt="지원 macOS: 27 이상"></a>
</p>

<p align="center">
  <a href="./README.md">English</a> | <a href="./README.ko.md">한국어</a>
</p>

## 소개

ThruRNDIS는 macOS에서 안드로이드의 RNDIS 방식 USB 테더링을 사용할 수 있게 해 주는 Virtualization Framework 기반 Swift 앱입니다.

## 요구 사항

- macOS 27 이상
- Network Extension 및 LaunchDaemon 권한

## 설치 방법

### GitHub Releases

[최신 ThruRNDIS 릴리스](https://github.com/Afcoo/ThruRNDIS/releases/latest)

### Homebrew

```sh
brew install --cask afcoo/tap/thrurndis
```

## 사용 방법

1. **VM Assets 설치:** 온보딩 또는 설정에서 최신 VM Assets를 설치합니다.
2. **USB 장치 전달:** 메뉴 막대의 **가상 머신 액세서리**에서 USB 장치를 **ThruRNDIS**로 전달합니다.

   ![가상 머신 액세서리에서 USB 장치를 ThruRNDIS로 전달하는 과정](./images/accessory-access-onboarding.gif)

3. **USB 기기 연결 확인:** USB 기기 연결 팝업에서 연결을 승인합니다.
4. **WireGuard 연결 확인:** WireGuard 연결 팝업에서 연결을 승인합니다.

## 작동 원리

```text
ThruRNDIS WireGuard Network System Extension
-> VZNAT guest endpoint UDP/<ListenPort>
-> Linux VM wg0
-> nftables masquerade
-> Linux VM usb0
-> RNDIS USB tethering device
```

*참조: [`Virtualization Framework: VZUSBPassthroughDevice`](https://developer.apple.com/documentation/virtualization/vzusbpassthroughdevice)*

ThruRNDIS는 경량 Linux VM을 실행하고 macOS에 연결된 RNDIS 장치를 USB passthrough로 VM에 전달합니다.

macOS와 VM은 VZNAT을 통해 WireGuard 터널로 연결되며, VM은 WireGuard를 통해 전달된 macOS의 트래픽을 인식된 RNDIS 장치에 전달합니다.

ThruRNDIS는 VZNAT을 통한 WireGuard 터널 연결을 위해 [`변형된 wireguard-apple 포크`](https://github.com/Afcoo/wireguard-apple/tree/thrurndis-vznat-bind)를 사용합니다.

## 라이선스

ThruRNDIS 소스 코드는 [MIT License](./LICENSE.txt)에 따라 배포됩니다.
