# PiP

**English** | [한국어](README.ko.md)

Keep logs and build progress in view while you work. PiP is a read-only, always-on-top view of a selected app window; ScreenCaptureKit captures it and Metal displays it.
It is useful for observing build output, dashboards, and similar changing windows while working elsewhere, subject to the source app continuing to render.

Website: <https://hanbong5938.github.io/pip/>

Detailed documentation: [Korean Wiki](https://github.com/hanbong5938/pip/wiki) — installation, usage, settings, troubleshooting, building, and architecture

> [!WARNING]
> Experimental, ad-hoc-signed preview. A panel visible on another desktop (Space) does not guarantee that its source keeps rendering. See [Known limitations](#known-limitations).

**Published preview.6:** The pinned download below includes the hide/resume, source-return, and saved-setup controls described here. A source build may differ from the published binary; live capture and restore still require manual validation on an unlocked Mac.

## Features

- Choose a window with the macOS system picker (`SCContentSharingPicker`) first; the in-app window list (panel or menu bar) is an optional route requiring broader Screen Recording permission
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
- The system picker provides a user-selected capture route without the broader permission required for the optional in-app window catalog. macOS may ask for capture consent; grant broader Screen Recording permission only if you want the list.

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

1. Download [PiP-v1.0.0-preview.6-macos-arm64.zip](https://github.com/hanbong5938/pip/releases/download/v1.0.0-preview.6/PiP-v1.0.0-preview.6-macos-arm64.zip) and [SHA256SUMS.txt](https://github.com/hanbong5938/pip/releases/download/v1.0.0-preview.6/SHA256SUMS.txt) from the **same preview.6 release**. Keep the manifest and ZIP together in one folder (for example, Downloads).
2. In Terminal, go to that folder and check this exact ZIP entry:

   ```sh
   cd ~/Downloads
   shasum -a 256 -c SHA256SUMS.txt
   ```

   Proceed only when `PiP-v1.0.0-preview.6-macos-arm64.zip: OK` appears. If the manifest or ZIP cannot be found, the command fails, or the ZIP reports `FAILED`, stop; re-download both files from that same release rather than opening the app. The checksum detects a mismatch against the downloaded manifest; it does **not** authenticate the publisher or make the ad-hoc-signed app safe.
3. Unzip, move `Pip.app` to `/Applications`, and launch it.

### Signing and Gatekeeper

The app has an ad-hoc signature, not a Developer ID signature or Apple notarization. There is no paid enrollment or security bypass in this installation process. If macOS blocks launch, only after independently trusting the release source and checking the checksum, use **System Settings → Privacy & Security → Open Anyway** if you accept that risk. Do not disable Gatekeeper or remove quarantine.

## Usage

1. Launch PiP. Its menu bar icon and an empty PiP panel appear.
2. In **preview.6 or a current source build**, choose **Choose with System Picker…** to select a window with macOS's picker; it needs no broader catalog permission and only one PiP can use it at a time. Alternatively, grant Screen Recording access in System Settings if you want the optional **Choose Window ▸** in-app list (panel or menu bar). The list may be unavailable rather than empty; permission is not requested automatically merely by opening the panel. List rows also offer **Select Region**, and holding ⌥ in the menu exposes region selection.
3. Grant only the capture consent macOS requests for your chosen route. A source that disappears before selection must be chosen again.
4. Drag the panel background to move it; drag its edges to resize (minimum **video area** 240×160 points, plus panel chrome; not a fixed 320×220 outer frame). While a window is captured, the panel keeps the source window's aspect ratio. Each panel's size and position are remembered across launches. For an exact size, choose **Size ▸ Custom…** and enter the video area width × height in points; during capture the other value follows the source aspect ratio. Press Enter to apply or Esc to cancel.
5. Hover over the panel to show its controls: status, Choose Window, Select Region, and Close.

### Multiple PiPs

Choose **New PiP** (⌘N) in the menu bar to open another panel. It opens slightly offset from the newest panel and shows the window list. Each PiP has its own window, region, frame rate, opacity, rotation, and size.

In **preview.6 and current source builds**, hiding a PiP immediately gates capture and clears its displayed pixels, then stops the stream asynchronously; hiding does **not** mean the stream has already been released. The running session retains its source and settings. **Show PiP** only shows the paused panel; it never resumes capture automatically. Choose **Resume Capture** explicitly: if the same running app and window can be verified with list permission, PiP resolves it again; otherwise select a source again through the system picker. If source geometry changed, resume starts with a full-window preview; **Apply Previous Region…** opens an **Apply Previous Region?** confirmation before applying the old crop. Closing a non-last PiP removes it; **Close All** also stops hidden sessions and leaves one empty PiP hidden.

### Return to source and saved setup

**Open Source App** activates the verified running source application, not a particular window; if it is unavailable, PiP does not launch an arbitrary replacement. **Remember Current Setup** optionally saves one local recipe: app name/bundle hint, normalized crop, source dimensions, frame rate, opacity, and rotation. It saves no source pixels, title, window ID, PID, or authorization. **Forget Saved Setup** deletes it. To restore after a later launch, explicitly choose **Restore Saved Setup…**, select a fresh window with the system picker or optional list, inspect its full-window preview, then choose **Apply Saved Region/Settings** and confirm. A changed app or source geometry is disclosed before applying; crop content may differ. Canceling a fresh selection starts no capture; canceling confirmation leaves the preview without applying the saved settings. Saved setup never auto-matches or starts capture.

### Region selection

Choose **Select Region…** (or the crop button on the panel) while a window is captured. Drag on the video to draw a region, then move it or resize it with its handles; hold Shift to keep the aspect ratio. Press Return (or double-click the region) to apply, Esc to cancel, or **Full Window** to go back to the whole window. **Reset Region** in the menu also restores the full window.

The selection overlay requires at least 16 points per side when its video content area allows it; capture rejects a normalized crop narrower or shorter than 1% of the source. Crop coordinates are normalized relative to the displayed source window and mapped to that window's actual current dimensions for capture. Resizing can make a saved region show different content or no longer fit; preview the full window before explicitly reapplying a previous/saved region, or select a new region.

### Click-through

With click-through on, the PiP panels ignore the mouse, so clicks go to the windows underneath, and each panel shows a small click-through badge in its top-right corner. Toggle it with ⌃⌥P from any app, or with **Click-Through** in the menu bar. It applies to all PiPs. The shortcut can be turned off in Settings.

### Menu bar

The menu labels follow the system language; Korean labels are shown in parentheses.

With one PiP, its items are listed directly in the menu. With two or more, each PiP gets a submenu titled with its number and source window (for example `1. Safari` or `2. Empty`) containing that PiP's items.

Per-PiP items:

| Menu | Action |
| --- | --- |
| Choose Window ▸ (창 선택) | Optional window list (hold ⌥ to also select a region); the primary action is **Choose with System Picker…** (시스템 선택기로 창 선택…) |
| Hide PiP (PiP 숨기기) / Show PiP (PiP 보이기) | Hide gates and clears pixels immediately while stream teardown completes asynchronously; show the paused panel without restarting capture |
| Select Region… (영역 선택…) | Select the part of the window to show |
| Reset Region (영역 초기화) | Show the whole window again |
| Frame Rate ▸ (프레임 레이트) | 1 / 5 / 15 / 30 / 60 fps; applies immediately |
| Opacity ▸ (불투명도) | 100% / 75% / 50% / 25% |
| Rotate Video (화면 회전) | Rotate the video 90° clockwise on each click (the item shows the current angle); the panel's video area swaps width and height. Only an explicitly remembered setup persists rotation between launches |
| Size ▸ (크기) | Small (작게) / Medium (보통) / Large (크게) / Custom… (사용자 지정…) |
| Resume Capture (캡처 재개) / Open Source App (원본 앱으로 이동) | Explicitly resume after a pause / activate the verified running source application, not an exact window |
| Stop (중지) | Stop capturing; do not automatically resume |
| Close PiP (PiP 닫기) | Close this PiP (shown with two or more PiPs) |

Global items:

| Menu | Action |
| --- | --- |
| New PiP (새 PiP) ⌘N | Open another PiP panel |
| Click-Through (클릭 통과) ⌃⌥P | Toggle click-through for all PiPs |
| Close All (모두 닫기) | Stop and close every PiP, keeping one hidden empty PiP |
| Settings… (설정…) ⌘, | Open the Settings window |
| Quit (종료) | Quit the app |

**Remember Current Setup** (현재 설정 기억) and **Forget Saved Setup** (저장된 설정 삭제) manage the optional local recipe. **Restore Saved Setup…** (저장된 설정 복원…) begins fresh source selection and full-window preview; **Apply Saved Region/Settings** (저장된 영역/설정 적용) requests confirmation before applying. After a changed-geometry same-process resume, **Apply Previous Region…** (이전 영역 적용…) separately requests confirmation.

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

To run the portable saved-setup regression against actual `SavedSetupStore` behavior with isolated `UserDefaults`, from the repository root run:

```sh
bash scripts/check-saved-setup.sh
```

This requires Swift 6+ (Command Line Tools are sufficient); it does not depend on XCTest or the Swift Testing framework. It does not replace native UI acceptance on a Mac with capture consent.

For the native off-state lifecycle smoke on an unlocked Mac with a graphical AppKit session, first build the debug app and then run:

```sh
bash scripts/build-app.sh debug
bash scripts/check-native-state.sh
```

This exercises actual AppKit panels, sessions, and manager hide/show/Close All/shutdown transitions with capture off. It does not synthesize a source or stream, open a picker or permission prompt, or prove live capture; a locked session can prevent source-dependent checks. Manual picker, capture, and saved-setup restore acceptance below still requires an unlocked GUI and actual user consent.

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
├── SourceIdentity.swift            # Running source identity and selection issues
├── SavedSetupStore.swift           # Opt-in local saved setup, no captured pixels
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
scripts/check-saved-setup.sh        # Portable isolated saved-setup regression
scripts/check-native-state.sh       # Native off-state lifecycle smoke; requires debug build
scripts/make-icon.swift             # App icon generator
docs/                               # GitHub Pages site (en, ko/)
```

## Known limitations

- A panel may stay visible across Spaces without receiving new source frames. If the source app stops rendering on another desktop, PiP cannot force it to keep drawing.
- Chrome video has been observed repeating the same frame after moving to another desktop; apps that keep drawing in the background, such as the built-in macOS Clock, may continue updating. Neither behavior is promised for every source.
- Per-window-only Screen Recording permission behavior has not been verified. The optional window list refreshes its ScreenCaptureKit catalog on opening/refresh and selection; use the system picker if the catalog is unavailable.
- Launch at login may need your approval under **System Settings › Login Items** because the app is ad-hoc signed; the Settings window shows a button to open it when approval is pending.
- A crop is stored as normalized source-window coordinates and mapped to the actual source-window dimensions for capture. Resizing the source can shift the intended content or make a previous region invalid; preview the whole window before using **Apply Previous Region…** or **Apply Saved Region/Settings**, or select a region again.
- The panel never activates the app, so macOS does not show resize cursors over its edges while another app is active. The edges are still draggable to resize; there is no public API for a background app to change the cursor.

## Manual acceptance and seven-day observation

For **preview.6 and current source-build UI acceptance** on an Apple Silicon Mac with macOS 15.2+, record the release URL and verify both pinned files above show `OK` for the download, or build using the instructions above and record the source revision. Record OS version, Gatekeeper outcome, and capture permissions. With a real log/build window and dashboard, start from **Choose with System Picker…** without granting catalog permission; verify selection, visible frame updates only where the source renders, stop, hide (pixels clear promptly; wait for asynchronous stream stop), show (no automatic resume), explicit resume, and **Open Source App** (app activation, not exact-window focus). Optionally grant broader Screen Recording permission and repeat via the list, including an unavailable catalog or a source closed before selection. Test picker cancellation, a busy picker, a source resized between pauses (full-window preview and **Apply Previous Region…** confirmation), click-through, multiple panels, Close All, and quit/relaunch without automatic capture. Choose **Remember Current Setup**, relaunch, choose **Restore Saved Setup…**, select a fresh source, inspect the full-window preview and any app/geometry mismatch, confirm **Apply Saved Region/Settings**, then choose **Forget Saved Setup**. Log actual results and failures; a visible panel does not prove fresh frames.

For a seven-day manual observation, ask actual consenting users to run their ordinary log/build or dashboard workflow daily. Record date, macOS version, source app, selection route and permission state, whether the source continued rendering across Spaces, capture/hide/resume outcomes, any mismatch prompts, and user-reported friction in a private manual log. Do not collect screenshots, source contents, or automated analytics. Summarize only observations actually made and the number of participating users/days; if no external participants are available, say so instead of claiming a pilot or measured reliability.

## License

[MIT](LICENSE)
