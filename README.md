# ThruRNDIS: USB Tethering via VM USB Passthrough

[한국어](./README.md) | [English](./README.en.md)


> [!WARNING]
> 현재 WireGuard 연결은 **`wg-quick`으로만 정상 동작합니다.** 공식 WireGuard macOS 앱에서는 이 연결이 정상적으로 시작되지 않을 수 있습니다.
>
> 아직 ThruRNDIS는 WireGuard 터널을 직접 설치하거나 시작·중지·관리하지 않습니다.


<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./images/introduction-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./images/introduction-light.png">
  <img alt="ThruRNDIS — Bring Android USB tethering to your Mac" src="./images/introduction-light.png">
</picture>

## 소개

ThruRNDIS는 Virtualization Framework의 USB passthrough기능을 사용해 macOS에서 Android RNDIS USB 테더링을 사용할 수 있게 해 줍니다

## 요구 사항

- macOS 27 beta 2 이상
- RNDIS USB 테더링을 지원하는 Android 장치와 데이터 전송용 USB 케이블
- 첫 실행 시 VM Asset을 내려받기 위한 인터넷 연결
- 네트워크 연결용 [`wg-quick`](https://www.wireguard.com/quickstart/)

## 작동 원리

```text
macOS WireGuard client
-> VZNAT guest endpoint UDP/<ListenPort>
-> Linux VM wg0
-> nftables masquerade
-> Linux VM usb0
-> RNDIS USB tethering device
```

ThruRNDIS는 경량 Linux VM을 실행하고, macOS에 연결된 Android RNDIS 장치를 USB passthrough로 VM에 넘깁니다. VM은 이 장치를 일반 USB 네트워크 장치로 인식하고 Android의 USB 테더링을 인터넷 연결로 사용합니다.

macOS와 VM은 WireGuard를 통해 연결되 VM에 트래픽을 보내고, VM은 그 트래픽을 USB passthrough된 RNDIS 장치로 전달하여 게이트웨이 역할을 합니다.

## 다운로드

### ThruRNDIS

1. [ThruRNDIS 최신 Release](https://github.com/Afcoo/ThruRNDIS/releases/latest)에서 앱을 내려받습니다.
2. 압축을 풀고 `ThruRNDIS.app`을 `/Applications`로 옮긴 뒤 실행합니다. ThruRNDIS는 Dock이 아닌 메뉴 막대에서 동작합니다.

이전 버전과 Release note는 [전체 Releases](https://github.com/Afcoo/ThruRNDIS/releases)에서 확인할 수 있습니다.

### VM Assets

VM Assets는 Alpine Linux 기반의 커널과 게이트웨이 프로그램 실행을 위한 램디스크로 구성됩니다.

ThruRNDIS은 [VM Asset Releases](https://github.com/Afcoo/ThruRNDIS_VM_Assets)에서 미리 빌드된 VM Assets를 설치하고 활성화합니다.

직접 빌드한 커널과 램디스크를 사용할 수도 있습니다.

### WireGuard Connection

WireGuard tools를 설치합니다.

```sh
brew install wireguard-tools wireguard-go
```

Android에서 USB 테더링을 켜고 장치를 연결한 뒤, ThruRNDIS의 승인을 거쳐 VM을 시작합니다. VM endpoint가 표시되면 WireGuard 화면에서 호스트 `.conf`를 저장하고 `wg-quick`으로 연결합니다.

```sh
sudo wg-quick up ./thrurndis.conf
sudo wg show

# 연결 종료
sudo wg-quick down ./thrurndis.conf
```

## 라이센스

ThruRNDIS 소스 코드는 [MIT License](./LICENSE.txt)에 따라 배포됩니다.
