# NotchDock

NotchDock is a native SwiftUI macOS notch companion and workspace that drops down seamlessly from the MacBook camera notch. It features smooth outward-curving top fillets that merge directly into the display bezel, intuitive media controls, and productivity tools right at your fingertips.

---

## Installation

### Method 1: Download Pre-built Release (Recommended)

1. Head over to the latest release on GitHub: [NotchDock Releases](https://github.com/aaravbasketball-del/NotchDock/releases).
2. Download **`NotchDock.dmg`** (or `NotchDock.zip`).
3. Open `NotchDock.dmg` and drag **NotchDock** into your **Applications** folder (`/Applications`).
4. Launch **NotchDock** from Launchpad, Spotlight, or your Applications folder.

> **First Launch on macOS**: If macOS Gatekeeper displays an unidentified developer prompt on the first launch:
> 1. Control-click (or right-click) **NotchDock.app** in Finder.
> 2. Click **Open** from the context menu.
> 3. Click **Open** in the confirmation dialog.

---

### Built-in Auto Updates

NotchDock checks GitHub Releases automatically on launch and in the background. When a new update is published:
- An **Update** button will appear in the top-right corner of the notch rail.
- Click **Update** to automatically download, install to `/Applications`, and restart the app.
- A **What's New** notice card will pop up after each update with release highlights.

---

### Permissions & Integrations

Depending on the features you want to use, macOS may prompt you for optional permissions:

- **Automation / Apple Events**:
  - **Apple Notes**: Required to automatically save Quick Notes to the native Notes app when you press Enter.
  - **Spotify & Apple Music**: Required to read now-playing track information and send play, pause, and skip commands.
- **Accessibility**:
  - Required if you choose the **"Only NotchDock"** volume and brightness indicator mode (which suppresses the stock macOS on-screen overlay).
  - Required for the **Keyboard Lock** utility tool.

You can manage these anytime in **System Settings → Privacy & Security**.

---

### Method 2: Build from Source

**Requirements**:
- macOS 13.0 or later (Sonoma, Sequoia, etc.)
- Xcode 15+ or Command Line Tools (`xcrun`, `swiftc`)

1. Clone the repository:
   ```bash
   git clone https://github.com/aaravbasketball-del/NotchDock.git
   cd NotchDock
   ```

2. Run directly with SwiftPM:
   ```bash
   swift run
   ```

3. Or compile a release binary and bundle:
   ```bash
   mkdir -p .build/release .release/NotchDock.app/Contents/MacOS .release/NotchDock.app/Contents/Resources
   xcrun --sdk macosx swiftc -parse-as-library -module-cache-path .build/module-cache \
     -target arm64-apple-macosx13.0 \
     -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers \
     -framework IOKit -framework CoreAudio -framework AVFoundation -framework ApplicationServices \
     Sources/NotchDock/*.swift -o .build/release/NotchDock-arm64
   cp .build/release/NotchDock-arm64 .release/NotchDock.app/Contents/MacOS/NotchDock
   cp Packaging/Info.plist .release/NotchDock.app/Contents/Info.plist
   cp Assets/NotchDock.icns .release/NotchDock.app/Contents/Resources/NotchDock.icns
   codesign --force --deep --sign - .release/NotchDock.app
   ```

---

## Key Features

- **Hardware Notch Alignment**: Custom notch silhouette featuring top outward curves (concave fillets) that merge into the display bezel, and bottom inward rounded corners.
- **Compact Media & Timer Strip**: Shows remaining timer countdown or Spotify / Apple Music track progress in a mini strip. Hovering over it instantly expands the dock.
- **Two-Way Apple Notes Sync**: Automatically displays your recent notes and quick notes right in the notch feed with live timestamps and click-to-open directly in Apple Notes.
- **Simulated Fake Notch & Dynamic Island**: Perfect for external monitors or notchless Macs. Choose between a classic MacBook notch or a floating Dynamic Island pill with customizable width, height, and camera reflection.
- **Trigger Bump Indicator**: Adds a subtle tactile bump at the top edge of your screen as a dedicated hover target with adaptive trigger dimensions.
- **Launch at Login**: Easily toggle automatic startup on login/restart in Settings via macOS `ServiceManagement` (`SMAppService`).
- **Volume & Brightness Display Modes**: Choose in Settings whether you want both macOS and NotchDock indicators, only macOS, or only NotchDock (suppressing the stock system overlay).
- **Clipboard History**: Search, pin, and copy past clipboard clips with keyboard shortcuts.
- **Drag & Drop File Shelf**: Stage files in the notch for quick drag-out access and AirDrop sharing.
- **Focus & Stopwatch**: Custom focus timer with countdown, three-tone completion sound, and system HUD alert.
- **Tools**: Keep Awake assertion (prevents Mac sleep) and a 60-second Keyboard Lock mode for quick laptop cleaning.
