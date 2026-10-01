# PiP

**English** | [한국어](README.ko.md)

A native macOS app that shows a selected app window in a small, always-on-top picture-in-picture panel.
Windows are captured with ScreenCaptureKit and rendered with Metal.

> [!WARNING]
> Experimental preview. If the source app stops rendering while it is on another desktop (Space), the PiP panel freezes too. See [Known limitations](#known-limitations).

## Features

- Pick a single window with the macOS system content picker (`SCContentSharingPicker`) and mirror it live
- The panel floats above other windows and stays visible across all Spaces and over full-screen apps
- Menu bar–only app (no Dock icon)
- Up to 30 fps, aspect ratio preserved, cursor hidden
- Rotate the mirrored video in 90° steps from the menu bar (display only)
- Captured frames are never saved or sent over the network

Not supported: audio capture, forwarding clicks or keystrokes from the panel to the source window.

## Requirements

- Apple Silicon (arm64) Mac — release binaries are arm64 only
- macOS 15.2 or later
- Screen Recording permission

## Installation

### Homebrew

Available from a personal tap ([hanbong5938/homebrew-tap](https://github.com/hanbong5938/homebrew-tap)).

```sh
brew install --cask hanbong5938/tap/pip
```

Uninstall:

```sh
brew uninstall --cask pip
```

### Manual download

1. Download `PiP-v<version>-macos-arm64.zip` from [Releases](https://github.com/hanbong5938/pip/releases).
2. Verify it against the accompanying `SHA256SUMS.txt`:

   ```sh
   shasum -a 256 -c SHA256SUMS.txt
   ```

3. Unzip, move `Pip.app` to `/Applications`, and launch it.

### Signing and Gatekeeper

The app is ad-hoc signed only; it has no Developer ID signature and is not notarized by Apple. If macOS blocks it, and only after you have verified the source and checksum, allow it under **System Settings → Privacy & Security → Open Anyway**.

## Usage

1. Launch PiP. A `PiP` menu bar item and the PiP panel appear.
2. Click **창 선택** (Choose Window) in the panel or the menu bar and pick the window to mirror.
3. Grant Screen Recording permission when prompted on first use.
4. Drag the panel background to move it; drag its edges to resize (minimum 320×220).

Menu bar items (the UI is in Korean):

| Menu | Action |
| --- | --- |
| 창 선택 (Choose Window) | Open the system picker to select or change the captured window |
| PiP 보이기 (Show PiP) | Bring back the PiP panel if it was closed or hidden |
| 화면 회전 (Rotate) | Rotate the PiP video 90° clockwise on each click (the item shows the current angle); the panel's video area swaps width and height. Not saved between launches |
| 중지 (Stop) | Stop capturing |
| 종료 (Quit) | Quit the app |

Closing the PiP panel also stops the capture.

## Building from source

Requires a Swift 6+ toolchain (Xcode 16+ or Command Line Tools).

```sh
git clone https://github.com/hanbong5938/pip.git
cd pip
bash scripts/build-app.sh release   # or debug
open build/Pip.app
```

The script bundles the SwiftPM executable, the Metal shader resource bundle, and the app icon into `build/Pip.app` and ad-hoc signs it. To regenerate the icon after editing `scripts/make-icon.swift`, run `swift scripts/make-icon.swift Resources/AppIcon.icns`.

## Project structure

```
Sources/Pip/
├── Main.swift                     # Entry point
├── AppController.swift            # App lifecycle, menu bar item
├── FloatingPanelController.swift  # Always-on-top PiP panel
├── CaptureSession.swift           # ScreenCaptureKit picker/stream management, recovery
├── FrameRenderer.swift            # Metal renderer
├── CaptureFrame.swift / CaptureState.swift
├── VideoRotation.swift            # Display rotation state (0/90/180/270°)
└── Resources/Video.metal          # Shaders
Resources/Info.plist               # App bundle Info.plist
Resources/AppIcon.icns             # App icon (generated)
scripts/build-app.sh               # .app bundle build script
scripts/make-icon.swift            # App icon generator
```

## Known limitations

- If the source app stops rendering while on another desktop, no new frames reach the PiP panel. This comes from the source app / macOS behavior, not from PiP.
- Chrome video has been observed repeating the same frame after being moved to another desktop.
- Apps that keep drawing in the background, such as the built-in macOS Clock window, continue to update from other desktops.
- Behavior with per-window-only Screen Recording permission has not been verified.

## License

[MIT](LICENSE)
