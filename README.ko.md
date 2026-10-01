# PiP

[English](README.md) | **한국어**

선택한 macOS 앱 창을 항상 위에 떠 있는 작은 PiP(화면 속 화면) 창으로 보여주는 네이티브 macOS 앱입니다.
ScreenCaptureKit으로 창을 캡처하고 Metal로 렌더링합니다.

웹사이트: <https://hanbong5938.github.io/pip/ko/>

> [!WARNING]
> 실험적 프리뷰입니다. 원본 앱이 다른 데스크톱(Space)에서 렌더링을 멈추면 PiP 화면도 멈춥니다. 자세한 내용은 [알려진 제한](#알려진-제한)을 참고하세요.

## 기능

- 앱 안의 창 목록(PiP 창 또는 메뉴 막대)이나 macOS 시스템 창 선택기(`SCContentSharingPicker`)로 창을 골라 실시간 표시
- 여러 PiP를 동시에 띄우고, 각 PiP마다 다른 창과 설정 사용
- PiP 창 위에서 직접 영역을 선택해 창의 일부만 표시
- PiP별 프레임 레이트: 1 / 5 / 15 / 30 / 60fps
- PiP별 불투명도
- 클릭 통과 모드: PiP 창이 클릭을 아래 창으로 넘김. 어느 앱에서든 ⌃⌥P로 전환
- PiP 화면을 90°씩 회전(표시 전용), 작게 / 보통 / 크게 크기 프리셋과 사용자 지정 크기
- 원본 창이 닫히면 PiP도 자동으로 닫는 옵션
- PiP 창에 마우스를 올리면 나타나는 컨트롤, 로그인 시 실행·새 PiP 기본값·단축키를 설정하는 설정 창
- PiP 창은 항상 위에 표시되며, 모든 데스크톱(Spaces)과 전체 화면 앱 위에서도 유지
- 메뉴 막대 전용 앱(Dock 아이콘 없음)
- 원본 비율 유지, 커서 미표시, PiP 창 크기에 맞춘 캡처 해상도
- 시스템 언어에 따라 한국어/영어 UI
- 캡처한 화면은 저장하거나 네트워크로 전송하지 않음

지원하지 않는 것: 오디오 캡처, PiP 창에서 원본 창으로의 클릭/키 입력 전달.

## 요구 사항

- Apple Silicon(arm64) Mac — 배포 바이너리는 arm64 전용
- macOS 15.2 이상
- 화면 기록 권한(창 캡처와 앱 안의 창 목록 표시에 필요)

## 설치

### Homebrew

개인 tap([hanbong5938/homebrew-tap](https://github.com/hanbong5938/homebrew-tap))으로 제공합니다.

```sh
brew install --cask hanbong5938/tap/pip
```

삭제:

```sh
brew uninstall --cask pip
```

### 직접 다운로드

1. [Releases](https://github.com/hanbong5938/pip/releases)에서 `PiP-v<버전>-macos-arm64.zip`을 받습니다.
2. 함께 올라간 `SHA256SUMS.txt`로 체크섬을 확인합니다.

   ```sh
   shasum -a 256 -c SHA256SUMS.txt
   ```

3. 압축을 풀고 `Pip.app`을 `/Applications`로 옮긴 뒤 실행합니다.

### 서명 및 Gatekeeper

앱은 ad-hoc 서명만 되어 있으며 Developer ID 서명·Apple 공증을 받지 않았습니다. macOS가 실행을 막으면 출처와 체크섬을 확인한 경우에만 **시스템 설정 → 개인정보 보호 및 보안**에서 **그래도 열기**를 선택하세요.

## 사용법

1. PiP를 실행하면 메뉴 막대에 PiP 아이콘이 나타나고, 창 목록이 표시된 PiP 창이 열립니다.
2. 표시할 창을 고릅니다.
   - **앱 안의 창 목록**: PiP 창의 목록에서 창을 클릭하거나 메뉴 막대의 **창 선택 ▸**에서 고릅니다. PiP 창 목록의 각 행에는 캡처를 시작하면서 바로 영역 선택으로 들어가는 **영역 선택** 버튼도 있고, 메뉴에서는 ⌥ 키를 누르고 있으면 같은 항목이 나타납니다. 창 목록에는 화면 기록 권한이 필요하며, 권한이 없으면 PiP 창에 **시스템 설정 열기** 버튼이 대신 표시됩니다.
   - **시스템 선택기**: **시스템 선택기 사용…**을 누르면 macOS 창 선택기가 열립니다. 창 목록에 필요한 권한 없이도 사용할 수 있습니다. 시스템 선택기는 한 번에 하나의 PiP에서만 열 수 있습니다.
3. 처음 실행 시 화면 기록 권한을 요청하면 허용합니다.
4. PiP 창은 배경을 드래그해 옮기고, 가장자리를 끌어 크기를 조절합니다(최소 320×220). 창을 캡처하는 동안에는 원본 창의 비율이 유지되며, PiP 창마다 크기와 위치가 다음 실행 때도 그대로 유지됩니다. 정확한 크기를 지정하려면 **크기 ▸ 사용자 지정…**을 선택하고 영상 영역의 너비 × 높이를 포인트 단위로 입력합니다. 창을 캡처하는 동안에는 한쪽 값을 바꾸면 다른 값이 원본 비율에 맞춰 바뀝니다. Enter로 적용하고 Esc로 취소합니다.
5. PiP 창에 마우스를 올리면 상태, 창 선택, 영역 선택, 닫기 컨트롤이 나타납니다.

### 여러 PiP

메뉴 막대에서 **새 PiP**(⌘N)를 선택하면 PiP 창이 하나 더 열립니다. 새 창은 가장 최근 PiP 창에서 조금 비켜난 위치에 창 목록과 함께 열립니다. PiP마다 창, 영역, 프레임 레이트, 불투명도, 회전, 크기를 따로 가집니다.

PiP 창을 닫으면 그 PiP의 캡처가 중지되고 PiP가 제거됩니다. 마지막으로 남은 PiP는 숨겨지기만 하므로 **PiP 보이기**로 다시 띄울 수 있습니다. **모두 닫기**는 모든 PiP의 캡처를 중지하고 제거하며, 빈 PiP 하나를 숨긴 상태로 남겨 둡니다.

### 영역 선택

창을 캡처하는 동안 **영역 선택…**(또는 PiP 창의 영역 선택 버튼)을 누릅니다. 화면 위를 드래그해 영역을 그리고, 영역을 옮기거나 핸들로 크기를 조절합니다. Shift를 누르고 있으면 비율이 유지됩니다. Return(또는 영역 더블클릭)으로 적용하고, Esc로 취소하며, **전체 창**을 누르면 창 전체로 돌아갑니다. 메뉴의 **영역 초기화**로도 창 전체를 다시 표시할 수 있습니다.

### 클릭 통과

클릭 통과를 켜면 PiP 창이 마우스를 무시해 클릭이 아래 창으로 전달되고, 각 PiP 창 오른쪽 위에 클릭 통과 배지가 표시됩니다. 어느 앱에서든 ⌃⌥P를 누르거나 메뉴 막대의 **클릭 통과**로 전환합니다. 모든 PiP에 함께 적용됩니다. 단축키는 설정에서 끌 수 있습니다.

### 메뉴 막대

메뉴 이름은 시스템 언어를 따릅니다.

PiP가 하나일 때는 그 PiP의 항목이 메뉴에 바로 나열됩니다. 둘 이상이면 PiP마다 번호와 원본 창 이름이 붙은 하위 메뉴(예: `1. Safari`, `2. 비어 있음`)가 생기고, 그 안에 해당 PiP의 항목이 들어갑니다.

PiP별 항목:

| 메뉴 | 동작 |
| --- | --- |
| 창 선택 ▸ | 목록에서 창 선택(⌥를 누르면 영역 선택까지), 또는 **시스템 선택기 사용…** |
| PiP 보이기 | 닫았거나 가려진 PiP 창을 다시 표시 |
| 영역 선택… | 표시할 창 영역 선택 |
| 영역 초기화 | 창 전체를 다시 표시 |
| 프레임 레이트 ▸ | 1 / 5 / 15 / 30 / 60fps, 즉시 적용 |
| 불투명도 ▸ | 100% / 75% / 50% / 25% |
| 화면 회전 | 누를 때마다 PiP 화면을 시계 방향으로 90° 회전(항목에 현재 각도 표시), PiP 창의 화면 영역 가로·세로가 바뀜. 앱을 다시 실행하면 초기화 |
| 크기 ▸ | PiP 창 크기 변경: 작게 / 보통 / 크게 / 사용자 지정… |
| 중지 | 캡처 중지 |
| PiP 닫기 | 이 PiP 닫기(PiP가 둘 이상일 때 표시) |

공통 항목:

| 메뉴 | 동작 |
| --- | --- |
| 새 PiP ⌘N | PiP 창을 하나 더 열기 |
| 클릭 통과 ⌃⌥P | 모든 PiP의 클릭 통과 전환 |
| 모두 닫기 | 모든 PiP의 캡처를 중지하고 닫기, 빈 PiP 하나는 숨긴 상태로 유지 |
| 설정… ⌘, | 설정 창 열기 |
| 종료 | 앱 종료 |

### 설정

- **로그인 시 실행**
- **원본 창이 닫히면 PiP 닫기**: 끄면 PiP 창이 열린 채로 원본 창이 닫혔다고 표시
- 새 PiP에 적용할 **기본 프레임 레이트**와 **기본 불투명도**(20–100%)
- **클릭 통과 전환** 단축키(⌃⌥P) 켜기/끄기
- 앱 버전

## 소스에서 빌드

Swift 6 이상 툴체인(Xcode 16 이상 또는 Command Line Tools)이 필요합니다.

```sh
git clone https://github.com/hanbong5938/pip.git
cd pip
bash scripts/build-app.sh release   # 또는 debug
open build/Pip.app
```

스크립트는 SwiftPM으로 빌드한 실행 파일, Metal 셰이더 리소스 번들, 앱 아이콘을 `build/Pip.app`으로 묶고 ad-hoc 서명합니다. `scripts/make-icon.swift`를 고친 뒤 아이콘을 다시 만들려면 `swift scripts/make-icon.swift Resources/AppIcon.icns`를 실행하세요.

## 프로젝트 구조

```
Sources/Pip/
├── Main.swift                      # 앱 진입점
├── AppController.swift             # 앱 수명주기, 메뉴 막대 항목과 메뉴
├── PiPManager.swift                # 여러 PiP 관리: 생성, 계단식 배치, 프레임 슬롯, 모두 닫기
├── PiPSession.swift                # PiP 하나: 렌더러, 패널, 캡처 세션
├── FloatingPanelController.swift   # 항상 위 PiP 패널, 호버 컨트롤, 클릭 통과 배지
├── CropSelectionView.swift         # 패널 위 영역 선택 오버레이
├── WindowListView.swift            # 패널에 표시되는 앱 안의 창 목록
├── WindowCatalog.swift             # SCShareableContent로 캡처 가능한 창 조회
├── CaptureSession.swift            # ScreenCaptureKit 선택기·스트림 관리, 복구
├── FrameRenderer.swift             # Metal 렌더러
├── CaptureFrame.swift / CaptureState.swift
├── VideoRotation.swift             # 화면 회전 상태(0/90/180/270°)
├── AppSettings.swift               # UserDefaults 기반 설정 값
├── SettingsWindowController.swift  # 설정 창(SwiftUI)
├── LoginItem.swift                 # 로그인 시 실행(SMAppService)
├── GlobalHotKey.swift              # ⌃⌥P 전역 단축키
├── ScreenCapturePermission.swift   # 화면 기록 권한 확인
├── L10n.swift                      # 현지화 문자열 조회
├── Localization/{en,ko}.lproj/     # Localizable.strings
└── Resources/Video.metal           # 셰이더
Resources/Info.plist                # 앱 번들 Info.plist
Resources/{en,ko}.lproj/            # 현지화된 InfoPlist.strings
Resources/AppIcon.icns              # 앱 아이콘(생성물)
scripts/build-app.sh                # .app 번들 빌드 스크립트
scripts/make-icon.swift             # 앱 아이콘 생성 스크립트
docs/                               # GitHub Pages 웹사이트 (en, ko/)
```

## 알려진 제한

- 원본 앱이 다른 데스크톱에서 렌더링을 멈추면 PiP에도 새 프레임이 들어오지 않습니다. 앱이 아니라 원본 앱/macOS 동작에 따른 제한입니다.
- Chrome 동영상은 다른 데스크톱으로 옮기면 같은 프레임이 반복되는 현상이 확인되었습니다.
- macOS 기본 시계 창처럼 백그라운드에서도 계속 그리는 앱은 다른 데스크톱에서도 갱신됩니다.
- 창별 허용만 있는 화면 기록 권한 상태에서의 동작은 검증되지 않았습니다.
- 앱 안의 창 목록은 열거나 새로 고칠 때마다, 그리고 창을 고를 때 ScreenCaptureKit에 현재 창 목록을 다시 조회하므로 화면 기록 권한이 필요합니다. 권한이 없으면 시스템 선택기를 사용하세요.
- 앱이 ad-hoc 서명이라 로그인 시 실행을 켜면 **시스템 설정 › 로그인 항목**에서 허용해야 할 수 있습니다. 허용이 필요하면 설정 창에 해당 화면을 여는 버튼이 표시됩니다.
- 영역은 원본 창의 포인트 단위로 캡처에 적용됩니다. 영역을 지정한 상태에서 원본 창 크기가 바뀌면 영역이 새 크기를 따라가지 않을 수 있으니 영역을 다시 선택하거나 **영역 초기화**를 사용하세요.
- PiP 창은 앱을 활성화하지 않기 때문에, 다른 앱이 활성 상태일 때는 가장자리에 마우스를 올려도 크기 조절 커서로 바뀌지 않습니다. 가장자리를 드래그하면 크기 조절은 됩니다. 백그라운드 앱이 커서를 바꾸는 공개 API는 없습니다.

## 라이선스

[MIT](LICENSE)
