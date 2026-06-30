[中文](README.md)

# WindowMover

A macOS menu bar utility to move all windows to a chosen display in one click.

## Features

- Move all visible windows to a target display in one click
- Three move modes: keep aspect / fill / original size
- Launch at login

## Download & Installation

### Option 1: Download the DMG (recommended)

1. Go to this repo's Release page
2. Download the latest `WindowMover-<version>.dmg`
3. Open the DMG and drag WindowMover to Applications
4. If Gatekeeper blocks first launch, go to "System Settings → Privacy & Security" and click "Open Anyway"

### Option 2: Build from source

1. Clone this repository
2. Open `WindowMover.xcodeproj` in Xcode
3. Select the Release configuration, then build and run

## Usage

1. After launch, a display icon appears in the menu bar
2. Click the icon → under "Move all windows to", pick a target display → all visible windows move there
3. Switch between the three modes under "Move mode"; toggle "Launch at login" to start with the system
4. Accessibility permission is required on first use; if not granted, a "Accessibility permission required…" button appears at the top of the menu — click it to open System Settings

## Move Modes

- **Keep aspect (keepAspect):** scale the window proportionally to fit inside the target display, centered.
- **Fill (fill):** stretch the window to the target display's usable area (excluding Dock and menu bar).
- **Original size (originalSize):** keep the window's original size, centered; if it exceeds the target display, fall back to keep aspect.

## Known Limitations

- Due to macOS underlying API limits, fullscreen windows cannot be operated on: fullscreen windows are skipped and do not participate in the move.
- Only meaningful in multi-display setups; with a single display the menu shows "No multiple displays detected".

## License

MIT, see [LICENSE](LICENSE).
