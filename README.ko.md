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
  <a href="https://github.com/Afcoo/ThruRNDIS/releases/latest"><img src="https://img.shields.io/github/v/release/Afcoo/ThruRNDIS?display_name=tag&label=release&logo=github&style=flat" alt="최신 버전"></a>
  <a href="https://github.com/Afcoo/ThruRNDIS/stargazers"><img src="https://img.shields.io/github/stars/Afcoo/ThruRNDIS?style=social" alt="GitHub stars"></a>
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
- AccessoryAccess, Virtualization 및 LaunchDaemon 권한

## 설치 방법

### GitHub Releases

[최신 ThruRNDIS 릴리스](https://github.com/Afcoo/ThruRNDIS/releases/latest)

### Homebrew

```sh
brew install --cask afcoo/tap/thrurndis
```

## 사용 방법

1. **VM Assets 설치:** 온보딩 또는 설정에서 최신 호환 VM Assets를 설치합니다.
2. **USB 장치 전달:** 메뉴 막대의 **가상 머신 액세서리**에서 USB 장치를 **ThruRNDIS**로 전달합니다.

   ![가상 머신 액세서리에서 USB 장치를 ThruRNDIS로 전달하는 과정](./images/accessory-access-onboarding.gif)

3. **(선택 사항) 포트 포워딩:** 기기를 연결하기 전에 **설정 → 네트워크 라우팅**에서 RNDIS 장치로 공유할 TCP/UDP 포트를 설정합니다.
4. **USB 기기 연결 확인:** USB 기기 연결 팝업에서 연결을 승인합니다.

## 작동 원리

```text
macOS
-> Ethernet Bond 및 feth pair
-> VZNAT bridge를 통한 Linux VM
-> nftables masquerade
-> Linux VM usb0
-> RNDIS USB tethering device
```

*참조: [`Virtualization Framework: VZUSBPassthroughDevice`](https://developer.apple.com/documentation/virtualization/vzusbpassthroughdevice)*

ThruRNDIS는 경량 Linux VM을 실행하고 macOS에 연결된 RNDIS 장치를 USB passthrough로 VM에 전달합니다.

macOS는 VM의 VZNAT bridge에 연결된 Ethernet Bond와 feth pair를 통해 VM과 통신합니다. VM은 IPv4 트래픽을 USB RNDIS 인터페이스로 전달합니다.

TCP/UDP 포트 포워딩은 Linux VM의 nftables DNAT/SNAT 규칙으로 처리하며, 일치하는 RNDIS 트래픽을 목적지 포트 변경 없이 macOS로 전달합니다.

## 라이선스

ThruRNDIS 소스 코드는 [MIT License](./LICENSE.txt)에 따라 배포됩니다.
