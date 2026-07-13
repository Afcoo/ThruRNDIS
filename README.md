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
   최신 `vm_assets.zip`과 `SHA256SUMS`를 다운로드하고, checksum과 부트 파일을
   검증한 뒤 Application Support에 설치해 바로 선택합니다.

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

앱은 `Afcoo/ThruRNDIS_VM_Assets`의 최신 공개 릴리스에서 이름이 정확히
`vm_assets.zip`과 `SHA256SUMS`인 attachment를 하나씩 찾습니다. 두 파일은 먼저
다음 staging 디렉터리에 저장됩니다.

```text
~/Library/Application Support/<bundle-id>/VMAssets/.staging/<operation-id>/
```

다운로드한 크기와 GitHub 릴리스에 표시된 크기를 비교한 뒤,
`SHA256SUMS`의 `vm_assets.zip` 항목과 앱이 계산한 SHA-256을 비교합니다. ZIP은
`vm_assets/` 루트 밖의 경로, path traversal, 중복 경로와 symbolic link를
거부합니다. 압축을 푼 뒤 `Image-lts`와 `initramfs-thrurndis-lts`가 정상 파일인지
확인하고 다음 위치에 원자적으로 설치합니다.

```text
~/Library/Application Support/<bundle-id>/VMAssets/Releases/<release-id>-<asset-id>/
├── install.json
└── vm_assets/
    ├── Image-lts
    └── initramfs-thrurndis-lts
```

같은 release와 asset이 이미 설치되어 있으면 다운로드하지 않고 재사용합니다.
새 설치는 활성화에 성공한 뒤에만 이전 managed release를 정리합니다. 다운로드,
검증, 압축 해제 또는 활성화가 실패하거나 취소되면 staging을 정리하고 이전 선택을
유지합니다. `Clear`는 선택만 해제하며 managed release 파일을 삭제하지 않습니다.

자동 설치를 사용할 수 없으면 릴리스 페이지에서 `vm_assets.zip`과
`SHA256SUMS`를 직접 내려받아 checksum을 검증하고 압축을 푼 뒤, 온보딩의
`Choose Asset Folder…` 또는 Settings의 `Choose Folder…`에서 추출된
`vm_assets` 폴더를 선택할 수 있습니다. Settings의 `Asset Overrides`에서는
kernel과 initramfs 파일을 개별적으로 바꿀 수도 있습니다.

VM Asset 릴리스에는 WireGuard key나 configuration이 포함되지 않습니다. 앱은
이를 별도의 Application Support `WireGuard/` 디렉터리에서 생성·관리합니다.
`Optional Storage`의 scratch disk도 VM Asset 설치와 분리된 사용자 선택 파일이며,
managed release를 갱신하거나 선택을 해제해도 변경되지 않습니다.

코드에서는 앱 전역 `VMAssetController`가 설치 상태와 UI workflow를 관리하고,
release 조회, 다운로드, 검증·설치, 선택 저장은 각각 주입된 service가 담당합니다.
`TetheringStore`는 `VMAssetProviding`을 통해 VM 시작 직전에 검증된 부트 파일만
받으며, scratch disk 선택은 계속 별도로 소유합니다.

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

- `ThruRNDIS/App`: 앱 진입점과 AppKit 메뉴바/윈도우 연결.
- `ThruRNDIS/Controllers`: VM Asset UI 상태와 설치 workflow.
- `ThruRNDIS/Coordinators`: VM lifecycle과 USB passthrough orchestration.
- `ThruRNDIS/Services`: VM Asset release/download/install, USB monitor, VM configuration.
- `ThruRNDIS/Stores`: 앱 상태와 VM Asset 선택 persistence.
- `ThruRNDIS/Support`: VM Asset 폴더 검사, WireGuard configuration storage,
  file picker와 runtime helper.
- `ThruRNDIS/Views`: 온보딩과 Settings/console UI.
- `script`: 앱 build/run/debug와 host WireGuard 검증 helper.
- `Configuration`: signing 설정 template.
