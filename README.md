# NotchDock

NotchDock is a native SwiftUI macOS notch workspace. It uses a black surface that grows down from and around the built-in notch on hover; it has no detached pill or Liquid Glass styling.

## Working features

- Hover activation and notch-anchored panel
- Locally saved quick note
- Clipboard history with search, pinning, and copy actions
- Drag-and-drop file shelf that remembers staged file locations
- Focus countdown, presets, reset, completion sound, and stopwatch
- Keep Awake power assertion
- Apple Music play, pause, next, and previous controls
- Feature map documenting additional Notchy capabilities for follow-on implementation

## Run

Requires macOS 13 or later and Xcode's Swift tools. Open `Package.swift` in Xcode and run the NotchDock scheme, or run `swift run` from this folder.

The app currently uses the primary built-in notch display. Integrations that need additional permissions or services are identified in the app's Tools feature map; they are not represented as working controls until implemented.

## Releases and updates

Push a version tag such as `v0.3` to the public GitHub repository. The release workflow builds universal Apple-silicon and Intel apps, publishes a DMG and ZIP, and creates a GitHub Release. NotchDock checks that release feed from Settings and shows a blue update button when a newer version is available.
