import AppKit
import SwiftUI
import CoreAudio
import IOKit.graphics
import Darwin
import ServiceManagement

private enum NotchDockMetrics {
    static let panelWidth: CGFloat = 1200
    static let panelHeight: CGFloat = 620
    static let collapsedHeight: CGFloat = 40
    static let timerWidth: CGFloat = 300
    static let musicWidth: CGFloat = 300
}

let notchDockPanelWidth: CGFloat = NotchDockMetrics.panelWidth
let notchDockPanelHeight: CGFloat = NotchDockMetrics.panelHeight
let notchDockCollapsedHeight: CGFloat = NotchDockMetrics.collapsedHeight
let notchDockTimerWidth: CGFloat = NotchDockMetrics.timerWidth
let notchDockMusicWidth: CGFloat = NotchDockMetrics.musicWidth

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var detector: NSPanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var closeTask: Task<Void, Never>?
    private var closeAnimationTask: Task<Void, Never>?
    private var pointerTimer: Timer?
    private var eventMonitors: [Any] = []
    private var capsLockOn = false
    private var volumeLevel = 0.5
    private var brightnessLevel = 0.5
    private var lastSystemKeyCode = -1
    private var lastSystemEventTime = 0.0
    private var hudGeneration = 0
    private var lastCapsChangeTime = 0.0
    private var capsSuppressionUntil = 0.0
    private var mediaEventTap: CFMachPort?
    private var mediaRunLoopSource: CFRunLoopSource?
    private let model = NotchModel()

    private var indicatorMode: String {
        UserDefaults.standard.string(forKey: "notchdock.indicatorMode") ?? "both"
    }

    private var capsLockHUDEnabled: Bool {
        UserDefaults.standard.object(forKey: "notchdock.capsLockHUDEnabled") as? Bool ?? true
    }

    private var systemHUDsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notchdock.systemHUDsEnabled") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.onHUDVisibilityChanged = { [weak self] visible in self?.setHUDMode(visible) }
        model.onRequestKeyboardFocus = { [weak self] in self?.focusCustomTimerField() }
        model.onTimerVisibilityChanged = { [weak self] running in self?.setTimerStripVisibility(running) }
        model.onMusicVisibilityChanged = { [weak self] playing in self?.setMusicStripVisibility(playing) }
        makeMenuBarItem()
        makeDetector()
        makePanel()
        if model.showingUpdateNotice {
            DispatchQueue.main.async { [weak self] in self?.showPanel() }
        }
        volumeLevel = readOutputVolume() ?? 0.5
        brightnessLevel = readDisplayBrightness() ?? 0.5
        installSystemHUDMonitors()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPointerLocation() }
        }
        if UserDefaults.standard.bool(forKey: "notchdock.launchAtLogin") {
            if #available(macOS 13.0, *) {
                if SMAppService.mainApp.status != .enabled {
                    try? SMAppService.mainApp.register()
                }
            }
        }
    }

    private func makeMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchDock")
        item.button?.toolTip = "NotchDock — show the notch controls"
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open NotchDock", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchDock", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func physicalNotchWidth(on screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let gap = right.minX - left.maxX
            if gap > 50 { return gap }
        }
        return 180
    }

    private func makeDetector() {
        guard let screen = targetScreen() else { return }
        let width = physicalNotchWidth(on: screen)
        let height: CGFloat = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 36
        let detector = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        detector.isOpaque = false
        detector.backgroundColor = .clear
        detector.hasShadow = false
        detector.level = .statusBar
        detector.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        detector.ignoresMouseEvents = false
        detector.contentView = HoverDetectorView(
            onEnter: { [weak self] in self?.showPanel() },
            onExit: { [weak self] in self?.scheduleClose() }
        )
        detector.setFrame(notchAnchoredFrame(on: screen, width: width, height: height), display: false)
        detector.orderFrontRegardless()
        self.detector = detector
    }

    private func makePanel() {
        guard let screen = targetScreen() else { return }
        let panel = NotchDockPanel(
            contentRect: CGRect(x: 0, y: 0, width: notchDockPanelWidth, height: notchDockCollapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        let hostingView = NSHostingView(rootView: NotchPanelView(
            model: model,
            onHoverChanged: { [weak self] inside in
                guard let self else { return }
                if inside {
                    if !self.model.isExpanded && !self.model.hudActive {
                        self.showPanel()
                    } else {
                        self.cancelClose()
                    }
                } else {
                    self.scheduleClose()
                }
            },
            onDismiss: { [weak self] in self?.hidePanel() }
        ))
        // Keep the AppKit hosting layer transparent. Otherwise macOS can draw
        // its default backing color into the rounded corners outside SwiftUI's
        // notch silhouette.
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        hostingView.layer?.masksToBounds = false
        panel.contentView = hostingView
        panel.setFrame(notchAnchoredFrame(on: screen, width: notchDockPanelWidth, height: notchDockCollapsedHeight), display: false)
        panel.orderOut(nil)
        self.panel = panel
    }

    private func focusCustomTimerField() {
        // Hovering should remain passive, but typing a custom duration needs a
        // real key window. Activate only after the user explicitly opens the
        // custom timer editor, then let SwiftUI focus its TextField.
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func targetScreen() -> NSScreen? {
        // A MacBook notch creates a top safe-area inset. Prefer that display,
        // then fall back to the current main display for notchless Macs.
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func positionPanel(on screen: NSScreen) {
        panel?.setFrame(notchAnchoredFrame(on: screen, width: notchDockPanelWidth, height: notchDockPanelHeight), display: false)
    }

    private var collapsedPanelWidth: CGFloat {
        if model.isTimerRunning { return notchDockTimerWidth }
        if model.musicIsPlaying { return notchDockMusicWidth }
        return notchDockPanelWidth
    }

    /// Uses the actual menu-bar regions reported by macOS. The gap between the
    /// left and right auxiliary areas is the physical camera notch, so this
    /// remains correct on different MacBook sizes and display scales.
    private func notchCenterX(on screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let candidate = (left.maxX + right.minX) / 2
            if screen.frame.minX...screen.frame.maxX ~= candidate { return candidate }
        }
        return screen.frame.midX
    }

    private func notchAnchoredFrame(on screen: NSScreen, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: notchCenterX(on: screen) - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func showPanel() {
        guard let panel else { return }
        cancelClose()
        closeAnimationTask?.cancel()
        guard !model.isExpanded else {
            panel.orderFrontRegardless()
            return
        }
        model.isExpanded = true
        if let screen = targetScreen() {
            let frame = notchAnchoredFrame(on: screen, width: notchDockPanelWidth, height: notchDockPanelHeight)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
        panel.orderFrontRegardless()
    }

    private func setHUDMode(_ visible: Bool) {
        guard let panel, let screen = targetScreen() else { return }
        if visible {
            cancelClose()
            let compactHUD = model.hudMode == "caps" || model.hudMode == "completion"
            let hudWidth: CGFloat = compactHUD ? 300 : 380
            let hudHeight: CGFloat = compactHUD ? 92 : 114
            panel.setFrame(notchAnchoredFrame(on: screen, width: hudWidth, height: hudHeight), display: true, animate: true)
            panel.orderFrontRegardless()
        } else if !model.isExpanded {
            if model.isTimerRunning || model.musicIsPlaying { ensureCompactStripVisible(panel: panel, screen: screen, animated: true) }
            else { panel.orderOut(nil) }
        } else {
            panel.setFrame(notchAnchoredFrame(on: screen, width: notchDockPanelWidth, height: notchDockPanelHeight), display: true, animate: true)
        }
    }

    private func setTimerStripVisibility(_ running: Bool) {
        guard let panel, let screen = targetScreen(), !model.hudActive else { return }
        if running {
            cancelClose()
            // The active timer is intentionally represented by the compact
            // strip immediately, even if the dashboard was open. Hovering the
            // notch can still expand the dashboard again.
            model.isExpanded = false
            ensureCompactStripVisible(panel: panel, screen: screen, animated: true)
        } else if model.musicIsPlaying {
            ensureCompactStripVisible(panel: panel, screen: screen, animated: true)
        } else {
            panel.orderOut(nil)
        }
    }

    private func setMusicStripVisibility(_ playing: Bool) {
        guard let panel, let screen = targetScreen(), !model.hudActive else { return }
        if playing {
            cancelClose()
            guard !model.isExpanded, !model.isTimerRunning else { return }
            model.isExpanded = false
            ensureCompactStripVisible(panel: panel, screen: screen, animated: true)
        } else if !model.isExpanded && !model.isTimerRunning {
            panel.orderOut(nil)
        }
    }

    private func ensureCompactStripVisible(panel: NSPanel, screen: NSScreen, animated: Bool = false) {
        let width = model.isTimerRunning ? notchDockTimerWidth : notchDockMusicWidth
        let frame = notchAnchoredFrame(on: screen, width: width, height: notchDockCollapsedHeight)
        if !panel.isVisible || abs(panel.frame.width - width) > 1 || abs(panel.frame.height - notchDockCollapsedHeight) > 1 {
            panel.setFrame(frame, display: true, animate: animated)
        }
        panel.orderFrontRegardless()
    }


    private func checkPointerLocation() {
        checkCapsLockState()
        guard let panel else { return }
        if model.showingUpdateNotice {
            panel.orderFrontRegardless()
            return
        }
        if !model.isExpanded {
            if let detector, detector.frame.contains(NSEvent.mouseLocation) {
                showPanel()
                return
            }
            if (model.isTimerRunning || model.musicIsPlaying) && !model.hudActive, let screen = targetScreen() {
                ensureCompactStripVisible(panel: panel, screen: screen)
            }
            return
        }
        if pointerIsInsidePanelSurface(panel) { cancelClose() } else { scheduleClose() }
    }

    private func pointerIsInsidePanelSurface(_ panel: NSPanel) -> Bool {
        let frame = panel.frame
        let point = NSPoint(x: NSEvent.mouseLocation.x - frame.minX,
                            y: NSEvent.mouseLocation.y - frame.minY)
        // Use the same continuous rounded silhouette as the SwiftUI surface,
        // with a small tolerance for the edge of the shadow.
        let hitFrame = NSRect(origin: .zero, size: frame.size).insetBy(dx: -2, dy: -2)
        return NSBezierPath(roundedRect: hitFrame, xRadius: 26, yRadius: 26).contains(point)
    }

    private func checkCapsLockState() {
        let isOn = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        guard isOn != capsLockOn else { return }
        capsLockOn = isOn
        lastCapsChangeTime = ProcessInfo.processInfo.systemUptime
        if capsLockHUDEnabled { showCapsLockHUD(isOn: isOn) }
    }

    private func installSystemHUDMonitors() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .systemDefined], handler: { [weak self] event in self?.handleSystemEvent(event) }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .systemDefined], handler: { [weak self] event in self?.handleSystemEvent(event); return event }) { eventMonitors.append(monitor) }
        installMediaEventTap()
    }

    private func installMediaEventTap() {
        let mask = (CGEventMask(1) << 14) // systemDefined
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = app.mediaEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if app.indicatorMode == "notchdock", let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 {
                let keyCode = (nsEvent.data1 >> 16) & 0xFF
                let keyFlags = nsEvent.data1 & 0xFFFF
                let keyState = (keyFlags & 0xFF00) >> 8
                if keyState == 0xA || keyState == 0x1 {
                    switch keyCode {
                    case 0:
                        Task { @MainActor in app.stepVolume(up: true) }
                        return nil
                    case 1:
                        Task { @MainActor in app.stepVolume(up: false) }
                        return nil
                    case 2:
                        Task { @MainActor in app.stepBrightness(up: true) }
                        return nil
                    case 3:
                        Task { @MainActor in app.stepBrightness(up: false) }
                        return nil
                    case 7:
                        Task { @MainActor in app.toggleMute() }
                        return nil
                    default:
                        break
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: pointer
        ) else { return }

        mediaEventTap = tap
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            mediaRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleSystemEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            guard capsLockHUDEnabled else { return }
            let isOn = event.modifierFlags.contains(.capsLock)
            guard isOn != capsLockOn else { return }
            capsLockOn = isOn
            lastCapsChangeTime = ProcessInfo.processInfo.systemUptime
            showCapsLockHUD(isOn: isOn)
            return
        }
        guard event.type == .systemDefined else { return }
        guard event.subtype.rawValue == 8 else { return }
        if indicatorMode == "macos" { return }

        let keyCode = (event.data1 >> 16) & 0xFF
        let now = ProcessInfo.processInfo.systemUptime
        guard keyCode != lastSystemKeyCode || now - lastSystemEventTime > 0.08 else { return }
        lastSystemKeyCode = keyCode
        lastSystemEventTime = now
        switch keyCode {
        case 0:
            showLiveVolumeHUD(symbol: "speaker.wave.3.fill")
        case 1:
            showLiveVolumeHUD(symbol: "speaker.wave.1.fill")
        case 2:
            showLiveBrightnessHUD(symbol: "sun.max.fill")
        case 3:
            showLiveBrightnessHUD(symbol: "sun.min.fill")
        case 7:
            showLiveVolumeHUD(symbol: "speaker.slash.fill")
        case 21: model.showSystemHUD(title: "Keyboard Light", symbol: "lightbulb.max.fill", value: "↑")
        case 22: model.showSystemHUD(title: "Keyboard Light", symbol: "lightbulb.min.fill", value: "↓")
        default: break
        }
    }

    func stepVolume(up: Bool) {
        let current = readOutputVolume() ?? 0.5
        let newLevel = min(max(up ? current + 0.0625 : current - 0.0625, 0), 1)
        setOutputVolume(newLevel)
        volumeLevel = newLevel
        let percent = Int((newLevel * 100).rounded())
        model.showSystemHUD(
            title: "Volume",
            symbol: newLevel == 0 ? "speaker.slash.fill" : (up ? "speaker.wave.3.fill" : "speaker.wave.1.fill"),
            value: "\(percent)%",
            progress: newLevel,
            mode: "volume"
        )
    }

    func toggleMute() {
        let current = readOutputVolume() ?? 0.5
        let newLevel = current > 0 ? 0.0 : 0.25
        setOutputVolume(newLevel)
        volumeLevel = newLevel
        let percent = Int((newLevel * 100).rounded())
        model.showSystemHUD(
            title: "Volume",
            symbol: newLevel == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
            value: newLevel == 0 ? "Mute" : "\(percent)%",
            progress: newLevel,
            mode: "volume"
        )
    }

    func stepBrightness(up: Bool) {
        let current = readDisplayBrightness() ?? 0.5
        let newLevel = min(max(up ? current + 0.0625 : current - 0.0625, 0), 1)
        setDisplayBrightness(newLevel)
        brightnessLevel = newLevel
        let percent = Int((newLevel * 100).rounded())
        model.showSystemHUD(
            title: "Brightness",
            symbol: up ? "sun.max.fill" : "sun.min.fill",
            value: "\(percent)%",
            progress: newLevel,
            mode: "brightness"
        )
    }

    private func setOutputVolume(_ level: Double) {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else { return }
        var vol = Float32(level)
        size = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            volumeAddress.mElement = element
            if AudioObjectSetPropertyData(deviceID, &volumeAddress, 0, nil, size, &vol) == noErr {
                break
            }
        }
    }

    private func setDisplayBrightness(_ level: Double) {
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
           let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
            typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
            let setBrightness = unsafeBitCast(symbol, to: SetBrightness.self)
            _ = setBrightness(CGMainDisplayID(), Float(level))
            return
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, Float(level))
            IOObjectRelease(service)
        }
    }

    private func showCapsLockHUD(isOn: Bool) {
        hudGeneration += 1
        let now = ProcessInfo.processInfo.systemUptime
        lastCapsChangeTime = now
        capsSuppressionUntil = now + 1.5
        model.showSystemHUD(
            title: "Caps Lock",
            symbol: isOn ? "capslock.fill" : "capslock",
            value: isOn ? "ON" : "OFF",
            mode: "caps"
        )
    }

    private func showLiveVolumeHUD(symbol: String) {
        hudGeneration += 1
        let generation = hudGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self else { return }
            guard generation == self.hudGeneration else { return }
            guard ProcessInfo.processInfo.systemUptime >= self.capsSuppressionUntil else { return }
            if let level = self.readOutputVolume() { self.volumeLevel = level }
            let percent = Int((self.volumeLevel * 100).rounded())
            self.model.showSystemHUD(title: "Volume", symbol: symbol, value: "\(percent)%", progress: self.volumeLevel, mode: "volume")
        }
    }

    private func showLiveBrightnessHUD(symbol: String) {
        hudGeneration += 1
        let generation = hudGeneration
        Task { @MainActor [weak self] in
            let configuredDelay = UserDefaults.standard.double(forKey: "notchdock.closeDelay")
            let delay = configuredDelay > 0 ? configuredDelay : 0.12
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self else { return }
            guard generation == self.hudGeneration else { return }
            guard ProcessInfo.processInfo.systemUptime >= self.capsSuppressionUntil else { return }
            if let level = self.readDisplayBrightness() { self.brightnessLevel = level }
            let percent = Int((self.brightnessLevel * 100).rounded())
            self.model.showSystemHUD(title: "Brightness", symbol: symbol, value: "\(percent)%", progress: self.brightnessLevel, mode: "brightness")
        }
    }

    private func readOutputVolume() -> Double? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &deviceID) == noErr else { return nil }
        var volume = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            volumeAddress.mElement = element
            if AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &size, &volume) == noErr {
                return min(max(Double(volume), 0), 1)
            }
        }
        return nil
    }

    private func readDisplayBrightness() -> Double? {
        // DisplayServices is the accurate path for the built-in MacBook panel.
        // It is loaded dynamically so the app still runs when the symbol is not
        // present on a particular macOS release.
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
           let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
            let getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
            var level = Float(0)
            if getBrightness(CGMainDisplayID(), &level) == 0 {
                return min(max(Double(level), 0), 1)
            }
        }

        // Public IOKit fallback for systems that expose IODisplayConnect.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            var level = Float(0)
            let result = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &level)
            IOObjectRelease(service)
            if result == KERN_SUCCESS { return min(max(Double(level), 0), 1) }
        }
        return nil
    }

    private func scheduleClose() {
        // The pointer poll runs several times per second. Do not restart the
        // same countdown on every poll, or it can never reach its deadline
        // while the cursor remains outside the panel.
        guard closeTask == nil, !model.hudActive else { return }
        closeTask = Task { @MainActor [weak self] in
            // Keep the leave delay very short so the dock feels immediate,
            // while still filtering out tiny cursor jitters at the edge.
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            guard let panel = self.panel, !self.pointerIsInsidePanelSurface(panel) else {
                self.closeTask = nil
                return
            }
            self.closeTask = nil
            self.beginAnimatedClose()
        }
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
        closeAnimationTask?.cancel()
        closeAnimationTask = nil
    }

    private func beginAnimatedClose() {
        guard !model.hudActive else { return }
        model.isExpanded = false
        if let screen = targetScreen(), let panel {
            let frame = notchAnchoredFrame(on: screen, width: collapsedPanelWidth, height: notchDockCollapsedHeight)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(frame, display: true)
            }
        }
        closeAnimationTask?.cancel()
        closeAnimationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(360))
            guard let self, !Task.isCancelled, !self.model.isExpanded else { return }
            if self.model.isTimerRunning || self.model.musicIsPlaying {
                self.panel?.orderFrontRegardless()
            } else {
                self.panel?.orderOut(nil)
            }
            self.closeAnimationTask = nil
        }
    }

    private func hidePanel() {
        guard !model.hudActive else { return }
        closeTask?.cancel()
        closeAnimationTask?.cancel()
        closeTask = nil
        closeAnimationTask = nil
        model.isExpanded = false
        if let screen = targetScreen() {
            panel?.setFrame(notchAnchoredFrame(on: screen, width: collapsedPanelWidth, height: notchDockCollapsedHeight), display: false)
        }
        if model.isTimerRunning || model.musicIsPlaying {
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    @objc private func togglePanel() {
        if model.isExpanded { hidePanel() } else { showPanel() }
    }

    @objc private func openFromMenu() { showPanel() }

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchDock Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 620, height: 430)
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    deinit {
        pointerTimer?.invalidate()
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        if let source = mediaRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = mediaEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }
}

/// The dashboard is normally non-activating so it can sit over the menu bar
/// without interrupting the current app. It must still be allowed to become
/// key when the user opens the custom timer field.
final class NotchDockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HoverDetectorView: NSView {
    private let onEnter: () -> Void
    private let onExit: () -> Void
    private var tracking: NSTrackingArea?

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
    override func mouseMoved(with event: NSEvent) { onEnter() }
    override func mouseDown(with event: NSEvent) { onEnter() }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
}

@MainActor
@main
struct NotchDockApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
