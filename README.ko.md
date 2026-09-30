# PiP

[English](README.md) | **한국어**

선택한 macOS 앱 창을 항상 위에 떠 있는 작은 PiP(화면 속 화면) 창으로 보여주는 네이티브 macOS 앱입니다.
ScreenCaptureKit으로 창을 캡처하고 Metal로 렌더링합니다.

> [!WARNING]
> 실험적 프리뷰입니다. 원본 앱이 다른 데스크톱(Space)에서 렌더링을 멈추면 PiP 화면도 멈춥니다. 자세한 내용은 [알려진 제한](#알려진-제한)을 참고하세요.

## 기능

- macOS 시스템 창 선택기(`SCContentSharingPicker`)로 창 하나를 골라 PiP 창에 실시간 표시
- PiP 창은 항상 위에 표시되며, 모든 데스크톱(Spaces)과 전체 화면 앱 위에서도 유지
- 메뉴 막대 전용 앱(Dock 아이콘 없음)
- 최대 30fps, 원본 비율 유지, 커서 미표시
- 캡처한 화면은 저장하거나 네트워크로 전송하지 않음

지원하지 않는 것: 오디오 캡처, PiP 창에서 원본 창으로의 클릭/키 입력 전달.

## 요구 사항

- Apple Silicon(arm64) Mac — 배포 바이너리는 arm64 전용
- macOS 15.2 이상
- 화면 기록 권한

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

1. PiP를 실행하면 메뉴 막대에 `PiP` 항목과 PiP 창이 나타납니다.
2. PiP 창의 **창 선택** 버튼 또는 메뉴 막대의 **창 선택**을 눌러 표시할 창을 고릅니다.
3. 처음 실행 시 화면 기록 권한을 요청하면 허용합니다.
4. PiP 창은 배경을 드래그해 옮기고, 가장자리를 끌어 크기를 조절합니다(최소 320×220).

메뉴 막대 항목:

| 메뉴 | 동작 |
| --- | --- |
| 창 선택 | 시스템 창 선택기를 열어 캡처할 창을 선택/변경 |
| PiP 보이기 | 닫았거나 가려진 PiP 창을 다시 표시 |
| 중지 | 캡처 중지 |
| 종료 | 앱 종료 |

PiP 창을 닫으면 캡처도 함께 중지됩니다.

## 소스에서 빌드

Swift 6 이상 툴체인(Xcode 16 이상 또는 Command Line Tools)이 필요합니다.

```sh
git clone https://github.com/hanbong5938/pip.git
cd pip
bash scripts/build-app.sh release   # 또는 debug
open build/Pip.app
```

스크립트는 SwiftPM으로 빌드한 실행 파일과 Metal 셰이더 리소스 번들을 `build/Pip.app`으로 묶고 ad-hoc 서명합니다.

## 프로젝트 구조

```
Sources/Pip/
├── Main.swift                     # 앱 진입점
├── AppController.swift            # 앱 수명주기, 메뉴 막대 항목
├── FloatingPanelController.swift  # 항상 위 PiP 패널
├── CaptureSession.swift           # ScreenCaptureKit 선택기·스트림 관리, 복구
├── FrameRenderer.swift            # Metal 렌더러
├── CaptureFrame.swift / CaptureState.swift
└── Resources/Video.metal          # 셰이더
Resources/Info.plist               # 앱 번들 Info.plist
scripts/build-app.sh               # .app 번들 빌드 스크립트
```

## 알려진 제한

- 원본 앱이 다른 데스크톱에서 렌더링을 멈추면 PiP에도 새 프레임이 들어오지 않습니다. 앱이 아니라 원본 앱/macOS 동작에 따른 제한입니다.
- Chrome 동영상은 다른 데스크톱으로 옮기면 같은 프레임이 반복되는 현상이 확인되었습니다.
- macOS 기본 시계 창처럼 백그라운드에서도 계속 그리는 앱은 다른 데스크톱에서도 갱신됩니다.
- 창별 허용만 있는 화면 기록 권한 상태에서의 동작은 검증되지 않았습니다.

## 라이선스

[MIT](LICENSE)
