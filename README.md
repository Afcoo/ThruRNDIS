# ThruRNDIS: USB Tethering via VM USB Passthrough

[한국어](./README.md) | [English](./README.en.md)


<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./images/introduction-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./images/introduction-light.png">
  <img alt="ThruRNDIS — Bring Android USB tethering to your Mac" src="./images/introduction-light.png">
</picture>

## 소개

ThruRNDIS는 macOS에서 안드로이드의 RNDIS 방식 USB 테더링을 사용할 수 있게 해 주는 Virtualization Framework 기반 Swift 앱입니다.

## 요구 사항

- macOS 27 beta 2 이상
- RNDIS 방식 USB 테더링을 지원하는 장치(예: 안드로이드 기기)
- 첫 실행 시 VM Assets를 내려받기 위한 인터넷 연결

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

ThruRNDIS는 경량 Linux VM을 실행하고 macOS에 연결된 안드로이드 RNDIS 장치를 USB passthrough로 VM에 전달합니다. VM은 이 장치를 일반 USB 네트워크 장치로 인식하고 안드로이드의 USB 테더링을 인터넷 연결로 사용합니다.

macOS는 WireGuard를 통해 VM에 트래픽을 보내고, VM은 해당 트래픽을 USB passthrough로 연결된 RNDIS 장치에 전달하여 게이트웨이 역할을 합니다.

## 사용 방법

### ThruRNDIS

1. [최신 ThruRNDIS 릴리스](https://github.com/Afcoo/ThruRNDIS/releases/latest)에서 앱을 내려받습니다.
2. 압축을 풀고 `ThruRNDIS.app`을 `/Applications`로 옮긴 뒤 실행합니다. ThruRNDIS는 Dock이 아닌 메뉴 막대에서 동작합니다.

---

### VM Assets

VM Assets는 Alpine Linux 기반의 커널과 게이트웨이 프로그램 실행을 위한 램디스크로 구성됩니다.

ThruRNDIS는 [VM Assets 릴리스](https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases)에서 미리 빌드된 VM Assets를 설치하고 활성화합니다.

직접 빌드한 커널과 램디스크를 사용할 수도 있습니다.

---

### WireGuard

안드로이드에서 USB 테더링을 켜고 장치를 연결한 뒤, ThruRNDIS의 승인을 거쳐 VM을 시작합니다.

VM 엔드포인트가 표시되면 설정의 WireGuard 화면이나 메뉴 막대에서 **Connect WireGuard**를 선택합니다. 연결을 끝내려면 **Disconnect WireGuard**를 선택합니다. ThruRNDIS가 내장된 Network System Extension을 통해 WireGuard 연결을 관리합니다.

## 라이선스

ThruRNDIS 소스 코드는 [MIT License](./LICENSE.txt)에 따라 배포됩니다.
