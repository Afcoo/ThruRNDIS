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
- AccessoryAccess 및 LaunchDaemon 권한

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
4. **선택 사항 — TCP 및 UDP 포트 포워딩:** **설정 → VM 네트워크**에서
   **포트포워딩 활성화**를 켠 다음 `80,443,47980-48000`처럼 쉼표로 포트를
   구분하고 하이픈으로 범위를 지정합니다. TCP와 UDP는 항상 같은 포트
   집합을 사용하며 포트 번호는 변환하지 않습니다. 집합을 바꾸려면
   VM을 정지해야 합니다.

## 작동 원리

> 이 POC에는 VM Assets 저장소의 동일한 `poc/feth-vm-networking` 브랜치에서
> 빌드한 asset이 필요합니다. 최신 공개 VM Assets는 아직 이전 네트워크
> 계약을 사용할 수 있습니다.

```text
macOS 관리 IPv4 route 및 DNS
-> Ethernet Bond (192.168.100.2)
-> feth0 <-> feth1
-> VM이 생성한 VZNAT bridge
-> Linux VM eth0 (192.168.100.1)
-> policy routing 및 nftables masquerade
-> Linux VM usb0
-> RNDIS USB tethering device
```

*참조: [`Virtualization Framework: VZUSBPassthroughDevice`](https://developer.apple.com/documentation/virtualization/vzusbpassthroughdevice)*

ThruRNDIS는 경량 Linux VM을 실행하고 macOS에 연결된 RNDIS 장치를 USB passthrough로 VM에 전달합니다.

이 POC에서 privileged helper는 Ethernet Bond와 `feth0`/`feth1` 쌍을 만듭니다. VM이 VZNAT 주소를 보고하면 helper가 해당 VM용 bridge를 식별해 `feth1`을 bridge 멤버로 추가하고, guest를 통하는 두 개의 `/1` IPv4 route를 설치합니다.

guest는 `192.168.100.1` 주소를 소유하고 Bond에서 들어온 트래픽을 USB RNDIS 인터페이스로 전달하며, 실제 RNDIS DHCP lease의 DNS를 사용해 DNS도 전달합니다. WireGuardKit과 Network System Extension은 이 경로에 포함되지 않습니다.

선택적 포트 포워딩 값은 VM을 시작하기 전에 고정됩니다. 앱은 검증된
`thrurndis.port_forward=<포트 집합>` 커널 인자 하나를 전달합니다.
guest는 nftables interval set 하나를 만들고 TCP와 UDP의 DNAT, forward,
source-NAT 규칙이 이를 함께 참조하게 합니다. DNAT은 목적지 주소만
`192.168.100.2`로 바꾸고 원래 목적지 포트는 유지합니다. 집합 변경 또는
해제는 다음 VM 시작부터 적용됩니다.

## 라이선스

ThruRNDIS 소스 코드는 [MIT License](./LICENSE.txt)에 따라 배포됩니다.
