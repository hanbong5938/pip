# PiP

**English** | [한국어](README.ko.md)

A native macOS app that shows selected app windows in small, always-on-top picture-in-picture panels.
Windows are captured with ScreenCaptureKit and rendered with Metal.

Website: <https://hanbong5938.github.io/pip/>

> [!WARNING]
> Experimental preview. If the source app stops rendering while it is on another desktop (Space), the PiP panel freezes too. See [Known limitations](#known-limitations).

## Features

- Pick a window from the in-app window list (in the panel or the menu bar), or with the macOS system content picker (`SCContentSharingPicker`), and mirror it live
- Multiple PiPs at once, each mirroring its own window with its own settings
- Show only part of a window: select a region directly on the PiP panel
- Frame rate per PiP: 1 / 5 / 15 / 30 / 60 fps
- Opacity per PiP
- Click-through mode: the panels let clicks pass to the windows underneath; toggle with ⌃⌥P from any app
- Rotate the mirrored video in 90° steps (display only); Small / Medium / Large size presets or a custom size
- Optionally close a PiP automatically when its source window closes
- Hover controls on the panel; a Settings window with launch at login, defaults for new PiPs, and the shortcut toggle
- The panels float above other windows and stay visible across all Spaces and over full-screen apps
- Menu bar–only app (no Dock icon)
- Aspect ratio preserved, cursor hidden; capture resolution follows the panel size
- English and Korean UI, following the system language
- Captured frames are never saved or sent over the network

Not supported: audio capture, forwarding clicks or keystrokes from the panel to the source window.

## Requirements

- Apple Silicon (arm64) Mac — release binaries are arm64 only
- macOS 15.2 or later
- Screen Recording permission (to capture windows and to list them in the app)

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

1. Launch PiP. A PiP icon appears in the menu bar, and the PiP panel opens with a list of windows.
2. Choose the window to mirror:
   - **In-app list**: click a window in the panel's list, or pick one from **Choose Window ▸** in the menu bar. Each row in the panel also has a **Select Region** button that starts the capture and goes straight to region selection; in the menu, hold ⌥ to get the same option. The list needs Screen Recording permission; until it is granted, the panel offers **Open System Settings** instead.
   - **System picker**: **Use System Picker…** opens the macOS window picker. It works without the permission needed for the list. Only one PiP can show the system picker at a time.
3. Grant Screen Recording permission when prompted on first use.
4. Drag the panel background to move it; drag its edges to resize (minimum 320×220). While a window is captured, the panel keeps the source window's aspect ratio. Each panel's size and position are remembered across launches. To set an exact size, choose **Size ▸ Custom…** and enter the video area width × height in points; while a window is captured, the other value follows the source aspect ratio. Press Enter to apply or Esc to cancel.
5. Hover over the panel to show its controls: status, Choose Window, Select Region, and Close.

### Multiple PiPs

Choose **New PiP** (⌘N) in the menu bar to open another panel. It opens slightly offset from the newest panel and shows the window list. Each PiP has its own window, region, frame rate, opacity, rotation, and size.

Closing a PiP panel stops its capture and removes that PiP. The last remaining PiP is only hidden, so **Show PiP** brings it back. **Close All** stops and removes every PiP, keeping one hidden empty PiP.

### Region selection

Choose **Select Region…** (or the crop button on the panel) while a window is captured. Drag on the video to draw a region, then move it or resize it with its handles; hold Shift to keep the aspect ratio. Press Return (or double-click the region) to apply, Esc to cancel, or **Full Window** to go back to the whole window. **Reset Region** in the menu also restores the full window.

### Click-through

With click-through on, the PiP panels ignore the mouse, so clicks go to the windows underneath, and each panel shows a small click-through badge in its top-right corner. Toggle it with ⌃⌥P from any app, or with **Click-Through** in the menu bar. It applies to all PiPs. The shortcut can be turned off in Settings.

### Menu bar

The menu labels follow the system language; Korean labels are shown in parentheses.

With one PiP, its items are listed directly in the menu. With two or more, each PiP gets a submenu titled with its number and source window (for example `1. Safari` or `2. Empty`) containing that PiP's items.

Per-PiP items:

| Menu | Action |
| --- | --- |
| Choose Window ▸ (창 선택) | Pick a window from the list (hold ⌥ to also select a region), or **Use System Picker…** (시스템 선택기 사용…) |
| Show PiP (PiP 보이기) | Bring back the PiP panel if it was closed or hidden |
| Select Region… (영역 선택…) | Select the part of the window to show |
| Reset Region (영역 초기화) | Show the whole window again |
| Frame Rate ▸ (프레임 레이트) | 1 / 5 / 15 / 30 / 60 fps; applies immediately |
| Opacity ▸ (불투명도) | 100% / 75% / 50% / 25% |
| Rotate Video (화면 회전) | Rotate the video 90° clockwise on each click (the item shows the current angle); the panel's video area swaps width and height. Not saved between launches |
| Size ▸ (크기) | Small (작게) / Medium (보통) / Large (크게) / Custom… (사용자 지정…) |
| Stop (중지) | Stop capturing |
| Close PiP (PiP 닫기) | Close this PiP (shown with two or more PiPs) |

Global items:

| Menu | Action |
| --- | --- |
| New PiP (새 PiP) ⌘N | Open another PiP panel |
| Click-Through (클릭 통과) ⌃⌥P | Toggle click-through for all PiPs |
| Close All (모두 닫기) | Stop and close every PiP, keeping one hidden empty PiP |
| Settings… (설정…) ⌘, | Open the Settings window |
| Quit (종료) | Quit the app |

### Settings

- **Launch at Login**
- **Close PiP when the source window closes**: otherwise the PiP stays open and shows that the source window closed
- **Default frame rate** and **Default opacity** (20–100%) for new PiPs
- **Toggle click-through** shortcut (⌃⌥P) on or off
- App version

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
├── Main.swift                      # Entry point
├── AppController.swift             # App lifecycle, menu bar item and menu
├── PiPManager.swift                # Multiple PiPs: creation, cascading, frame slots, close all
├── PiPSession.swift                # One PiP: renderer, panel, and capture session
├── FloatingPanelController.swift   # Always-on-top PiP panel, hover controls, click-through badge
├── CropSelectionView.swift         # Region selection overlay on the panel
├── WindowListView.swift            # In-app window list shown in the panel
├── WindowCatalog.swift             # Lists capturable windows via SCShareableContent
├── CaptureSession.swift            # ScreenCaptureKit picker/stream management, recovery
├── FrameRenderer.swift             # Metal renderer
├── CaptureFrame.swift / CaptureState.swift
├── VideoRotation.swift             # Display rotation state (0/90/180/270°)
├── AppSettings.swift               # UserDefaults-backed preferences
├── SettingsWindowController.swift  # Settings window (SwiftUI)
├── LoginItem.swift                 # Launch at login (SMAppService)
├── GlobalHotKey.swift              # ⌃⌥P global shortcut
├── ScreenCapturePermission.swift   # Screen Recording permission check
├── L10n.swift                      # Localized string lookup
├── Localization/{en,ko}.lproj/     # Localizable.strings
└── Resources/Video.metal           # Shaders
Resources/Info.plist                # App bundle Info.plist
Resources/{en,ko}.lproj/            # Localized InfoPlist.strings
Resources/AppIcon.icns              # App icon (generated)
scripts/build-app.sh                # .app bundle build script
scripts/make-icon.swift             # App icon generator
docs/                               # GitHub Pages site (en, ko/)
```

## Known limitations

- If the source app stops rendering while on another desktop, no new frames reach the PiP panel. This comes from the source app / macOS behavior, not from PiP.
- Chrome video has been observed repeating the same frame after being moved to another desktop.
- Apps that keep drawing in the background, such as the built-in macOS Clock window, continue to update from other desktops.
- Behavior with per-window-only Screen Recording permission has not been verified.
- The in-app window list asks ScreenCaptureKit for the current windows each time it is opened or refreshed, and again when you pick a window, so it requires Screen Recording permission. Without it, use the system picker.
- Launch at login may need your approval under **System Settings › Login Items** because the app is ad-hoc signed; the Settings window shows a button to open it when approval is pending.
- A region is applied to the capture in source-window points. If the source window is resized while a region is set, the region may not follow the window's new size; select it again or use **Reset Region**.
- The panel never activates the app, so macOS does not show resize cursors over its edges while another app is active. The edges are still draggable to resize; there is no public API for a background app to change the cursor.

## License

[MIT](LICENSE)
