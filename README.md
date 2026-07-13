# ThruRNDIS

[한국어](./README.md) | [English](./README.en.md)

안드로이드 장치의 USB 테더링에 사용되는 RNDIS 프로토콜을 macOS에서도 사용할 수 있게 해주는 Swift 앱입니다.

Virtualization 프레임워크의 USB passthrough로 RNDIS 장치를 Linux VM에 연결하고, macOS는 WireGuard로 VM에 연결해 테더링 네트워크를 사용합니다.

## 요구 사항

- macOS 27 beta 2 이상.

## 사용법

1. `ThruRNDIS.app`을 실행합니다.

   macOS가 경고로 실행을 막으면 다음 명령을 실행하세요.

```sh
sudo xattr -dr com.apple.quarantine "/Applications/ThruRNDIS.app"
```

2. 첫 실행 온보딩에서 `Download & Install Latest`를 누릅니다. 앱이
   [VM Asset 릴리스](https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases)의
   최신 VM Asset을 다운로드하고 설치해 바로 선택합니다.

3. USB 테더링 장치를 Mac에 연결하고, 메뉴바에서 VM이 장치를 사용하도록 선택합니다.

   <video src="https://github.com/user-attachments/assets/d285ed13-9bf3-4030-ad34-f04cd9de4e34" width="120" controls></video>

4. `Start VM`을 누른 뒤 `USB Devices`에서 passthrough할 장치를 선택하고 `Attach`를 누릅니다.

   <video src="https://github.com/user-attachments/assets/4d10e732-7510-4555-84c5-1f16ef412a00" width="120" controls></video>

5. `WireGuard` 화면에서 host `.conf`를 복사하거나 저장합니다.

6. WireGuard 도구를 설치합니다.

```sh
brew install wireguard-tools wireguard-go
```

7. 저장한 `.conf` 파일로 WireGuard를 설정합니다.

```sh
sudo wg-quick up ./thrurndis.conf
sudo wg show
# 종료 시
sudo wg-quick down ./thrurndis.conf
```

공식 WireGuard 앱에서는 현재 연결이 정상적으로 올라오지 않을 수 있으므로 macOS 검증에는 `wireguard-go`를 권장합니다.

## 구조

```text
macOS host WireGuard client
-> VZNAT UDP/51820
-> Alpine VM wg0
-> nftables masquerade
-> Alpine VM usb0
-> RNDIS USB tethering device
```

- `eth0`: VM의 VZNAT network. host가 WireGuard endpoint로 접속하는 통로입니다.
- `wg0`: WireGuard overlay. 기본 주소는 guest `10.100.0.1/24`, host `10.100.0.2/24`입니다.
- `usb0`: VM 안의 RNDIS tethering interface입니다.

생성된 client config는 IPv4 full tunnel용입니다.

```text
AllowedIPs = 10.100.0.0/24, 0.0.0.0/1, 128.0.0.0/1
```

## VM Assets

온보딩의 `Download & Install Latest` 또는 Settings의 `VM Assets` >
`Check & Install Latest`가 기본 설치 경로입니다. 최신 확인은 사용자가 버튼을
눌렀을 때만 실행되며, 백그라운드 업데이트나 자동 재시도는 하지 않습니다.

VM Asset은 [Afcoo/ThruRNDIS_VM_Assets](https://github.com/Afcoo/ThruRNDIS_VM_Assets)
저장소의 [Releases](https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases)에서
받아옵니다.

직접 준비한 kernel과 initramfs가 포함된 VM Asset 폴더를 수동으로 선택할 수도
있습니다. 기존 VM Asset을 선택한 상태에서는 Settings의 `Asset Overrides`에서
kernel과 initramfs 파일을 각각 지정할 수 있습니다.

## 빌드 방법

일반 UI/컴파일 확인:

```sh
./script/build_and_run.sh
```

runtime signing 확인:

```sh
cp Configuration/LocalSigning.xcconfig.example Configuration/LocalSigning.xcconfig
./script/build_and_run.sh --runtime
```

`Configuration/LocalSigning.xcconfig`에 로컬 `DEVELOPMENT_TEAM`과 bundle identifier를 넣습니다.

VM Asset 제작과 GitHub Release 배포는 별도
[`Afcoo/ThruRNDIS_VM_Assets`](https://github.com/Afcoo/ThruRNDIS_VM_Assets)
저장소에서 담당합니다.

## 디렉터리

- `ThruRNDIS/App`: 앱 진입점과 의존성 조립.
- `ThruRNDIS/Presentation`: AppKit 메뉴바와 SwiftUI 호스팅 윈도우.
- `ThruRNDIS/Models`: 계층 간에 공유하는 값 타입과 protocol 경계.
- `ThruRNDIS/Coordinators`: VM lifecycle, USB passthrough, VM Asset 설치/선택 workflow.
- `ThruRNDIS/Services`: VM Asset release/download/install, USB monitor, VM configuration.
- `ThruRNDIS/Stores`: SwiftUI에 제공되는 observable 앱/세션/VM 설정 상태.
- `ThruRNDIS/Persistence`: VM Asset 선택, 저장 경로, WireGuard 파일 persistence.
- `ThruRNDIS/Support`: VM Asset 폴더 검사, WireGuard configuration rendering,
  file picker와 stateless runtime helper.
- `ThruRNDIS/Views`: 온보딩과 Settings/console UI.
- `Configuration`: signing 설정 template.
