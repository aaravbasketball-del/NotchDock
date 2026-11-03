import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import IOKit.pwr_mgt
import AVFoundation
import ApplicationServices
import ServiceManagement

struct AppleNoteItem: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let snippet: String
    let date: String
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var isExpanded = false
    @Published var selectedTab: NotchTab = .home
    @Published var note = "" { didSet { UserDefaults.standard.set(note, forKey: "notchdock.quickNote") } }
    @Published var quickNoteDraft = ""
    @Published var recentNotes: [String] = []
    @Published var appleNotes: [AppleNoteItem] = []
    @Published var isSyncingNotes = false
    @Published var clips: [Clip] = []
    @Published var pinnedIDs: Set<UUID> = []
    @Published var shelfURLs: [URL] = []
    @Published var clipSearch = ""
    @Published var timerSeconds = 25 * 60
    @Published var timerDuration = 25
    @Published var customTimerDraft = "30"
    @Published var isEditingCustomTimer = false
    @Published var isTimerRunning = false
    @Published var isStopwatchRunning = false
    @Published var stopwatchStart: Date?
    @Published var stopwatchElapsed: TimeInterval = 0
    @Published var keepAwake = false
    @Published var statusMessage = ""
    @Published var hudActive = false
    @Published var hudTitle = ""
    @Published var hudSymbol = "speaker.wave.2.fill"
    @Published var hudValue = ""
    @Published var hudProgress = 0.5
    @Published var hudMode = "caps"
    @Published var cameraActive = false
    @Published var cameraMirrored = true
    @Published var musicTrackTitle = ""
    @Published var musicTrackArtist = ""
    @Published var musicTrackAlbum = ""
    @Published var musicIsPlaying = false
    @Published var musicElapsed: TimeInterval = 0
    @Published var musicDuration: TimeInterval = 0
    @Published var keyboardLockRemaining = 0
    @Published var showingUpdateNotice = false
    @Published var updateNoticeVersion = ""
    @Published var updateNoticeMessage = ""
    var onHUDVisibilityChanged: ((Bool) -> Void)?
    var onTimerVisibilityChanged: ((Bool) -> Void)?
    var onMusicVisibilityChanged: ((Bool) -> Void)?
    /// The notch panel is normally non-activating so hovering never steals
    /// focus from the app underneath. Custom timer entry is the one case where
    /// we intentionally make it keyboard-focused.
    var onRequestKeyboardFocus: (() -> Void)?
    private var focusTimer: Timer?
    private var hudTask: Task<Void, Never>?
    private var poller: AnyCancellable?
    private var musicPoller: AnyCancellable?
    private var lastPasteboardChange = -1
    private var powerAssertion: IOPMAssertionID = 0
    private let keyboardLock = KeyboardLockController()
    private var keyboardLockTask: Task<Void, Never>?
    private var musicLaunchTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let version = defaults.string(forKey: "notchdock.pendingUpdateVersion"), !version.isEmpty {
            updateNoticeVersion = version
            var message = defaults.string(forKey: "notchdock.pendingUpdateMessage") ?? ""
            if message.contains("NotchDock 1.0 includes") || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = NotchUpdater.defaultReleaseNotes(for: version)
            }
            updateNoticeMessage = message
            showingUpdateNotice = true
            defaults.removeObject(forKey: "notchdock.pendingUpdateVersion")
            defaults.removeObject(forKey: "notchdock.pendingUpdateMessage")
        }
        note = defaults.string(forKey: "notchdock.quickNote") ?? ""
        recentNotes = defaults.stringArray(forKey: "notchdock.recentNotes") ?? []
        if let data = defaults.data(forKey: "notchdock.syncedAppleNotes"),
           let saved = try? JSONDecoder().decode([AppleNoteItem].self, from: data) {
            appleNotes = saved
        }
        shelfURLs = (defaults.stringArray(forKey: "notchdock.shelf") ?? []).compactMap(URL.init(string:))
        if let data = defaults.data(forKey: "notchdock.clipData"),
           let saved = try? JSONDecoder().decode([Clip].self, from: data) {
            clips = saved
            pinnedIDs = Set(saved.filter(\.isPinned).map(\.id))
        }
        lastPasteboardChange = NSPasteboard.general.changeCount
        poller = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.readPasteboard() }
        musicPoller = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refreshNowPlaying() }
        refreshNowPlaying()
        syncAppleNotes()
    }

    func dismissUpdateNotice() {
        showingUpdateNotice = false
    }

    func submitQuickNote() {
        let text = quickNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        saveNoteToAppleNotes(text)
        recentNotes.insert(text, at: 0)
        recentNotes = Array(recentNotes.prefix(30))
        UserDefaults.standard.set(recentNotes, forKey: "notchdock.recentNotes")
        quickNoteDraft = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.syncAppleNotes()
        }
    }

    static func requestAutomationPermission(for bundleID: String) -> Bool {
        var target = AEAddressDesc()
        guard let data = bundleID.data(using: .utf8) else { return false }
        let status = data.withUnsafeBytes { rawBuffer in
            AECreateDesc(typeApplicationBundleID, rawBuffer.baseAddress, rawBuffer.count, &target)
        }
        guard status == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        let permStatus = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
        return permStatus == noErr
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func saveNoteToAppleNotes(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let isNotesRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Notes" }
        if !isNotesRunning {
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))
        }

        let escapedHTML = trimmed
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let scriptSource = """
        tell application "Notes"
            activate
            make new note with properties {body:"<div>\(escapedHTML)</div>"}
        end tell
        """

        Task {
            if let script = NSAppleScript(source: scriptSource) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                await MainActor.run {
                    if let error {
                        let errNum = error[NSAppleScript.errorNumber] as? Int ?? 0
                        if errNum == -1743 || errNum == -1744 {
                            self.statusMessage = "Allow NotchDock in System Settings → Automation"
                            NotchModel.openAutomationSettings()
                        } else {
                            self.statusMessage = "Could not save to Notes"
                        }
                    } else {
                        self.statusMessage = "Saved to Apple Notes"
                    }
                }
            }
        }
    }

    func syncAppleNotes() {
        guard !isSyncingNotes else { return }
        isSyncingNotes = true

        let script = """
        tell application "Notes"
            try
                set outText to ""
                set theNotes to notes
                set totalCount to count of theNotes
                if totalCount > 15 then set totalCount to 15
                repeat with i from 1 to totalCount
                    set aNote to item i of theNotes
                    set nId to id of aNote
                    set nName to name of aNote
                    set nDate to (modification date of aNote) as string
                    set nBody to ""
                    try
                        set nBody to paragraph 2 of (plaintext of aNote)
                    on error
                        try
                            set nBody to plaintext of aNote
                        end try
                    end try
                    set outText to outText & nId & "<!SEP!>" & nName & "<!SEP!>" & nBody & "<!SEP!>" & nDate & "<!ROW!>"
                end repeat
                return outText
            on error
                return ""
            end try
        end tell
        """

        Task {
            guard let scriptObj = NSAppleScript(source: script) else {
                self.isSyncingNotes = false
                return
            }
            var error: NSDictionary?
            let descriptor = scriptObj.executeAndReturnError(&error)
            let resultString = descriptor.stringValue ?? ""

            var items: [AppleNoteItem] = []
            if !resultString.isEmpty && error == nil {
                let rows = resultString.components(separatedBy: "<!ROW!>")
                for row in rows where !row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let parts = row.components(separatedBy: "<!SEP!>")
                    if parts.count >= 4 {
                        let id = parts[0]
                        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        let snippet = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        let date = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !title.isEmpty {
                            items.append(AppleNoteItem(id: id, title: title, snippet: snippet, date: date))
                        }
                    }
                }
            }

            if !items.isEmpty {
                self.appleNotes = items
                if let encoded = try? JSONEncoder().encode(items) {
                    UserDefaults.standard.set(encoded, forKey: "notchdock.syncedAppleNotes")
                }
            }
            self.isSyncingNotes = false
        }
    }

    func openNoteInAppleNotes(id: String) {
        let script = """
        tell application "Notes"
            try
                show note id "\(id)"
                activate
            on error
                activate
            end try
        end tell
        """
        Task {
            if let s = NSAppleScript(source: script) {
                var err: NSDictionary?
                s.executeAndReturnError(&err)
            }
        }
    }

    func readPasteboard() {
        let board = NSPasteboard.general
        guard board.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = board.changeCount
        guard let text = board.string(forType: .string), !text.isEmpty,
              clips.first?.text != text else { return }
        clips.insert(Clip(text: text), at: 0)
        clips = Array(clips.prefix(80))
        saveClips()
    }

    func copy(_ clip: Clip) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clip.text, forType: .string)
        statusMessage = "Copied to clipboard"
    }

    func togglePin(_ clip: Clip) {
        if pinnedIDs.contains(clip.id) { pinnedIDs.remove(clip.id) } else { pinnedIDs.insert(clip.id) }
        saveClips()
    }

    func clearClips() { clips.removeAll { !pinnedIDs.contains($0.id) }; saveClips() }
    private func saveClips() {
        let saved = clips.map { Clip(id: $0.id, text: $0.text, isPinned: pinnedIDs.contains($0.id)) }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "notchdock.clipData")
    }

    func addFiles(_ urls: [URL]) {
        for url in urls where !shelfURLs.contains(url) { shelfURLs.insert(url, at: 0) }
        UserDefaults.standard.set(shelfURLs.map(\.absoluteString), forKey: "notchdock.shelf")
        statusMessage = urls.count == 1 ? "Added 1 file to Shelf" : "Added \(urls.count) files to Shelf"
    }
    func removeFile(_ url: URL) {
        shelfURLs.removeAll { $0 == url }
        UserDefaults.standard.set(shelfURLs.map(\.absoluteString), forKey: "notchdock.shelf")
    }

    func airDropShelfFiles() {
        guard !shelfURLs.isEmpty else {
            statusMessage = "Add files to Shelf first"
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            statusMessage = "AirDrop is unavailable on this Mac"
            return
        }
        service.perform(withItems: shelfURLs)
        statusMessage = shelfURLs.count == 1 ? "Choose a device in AirDrop" : "Choose a device for \(shelfURLs.count) files"
    }

    func startTimer(minutes: Int? = nil) {
        if let minutes { timerDuration = minutes; timerSeconds = minutes * 60 }
        guard !isTimerRunning else {
            isTimerRunning = false
            focusTimer?.invalidate()
            focusTimer = nil
            onTimerVisibilityChanged?(false)
            return
        }
        if timerSeconds == 0 { timerSeconds = timerDuration * 60 }
        isTimerRunning = true
        onTimerVisibilityChanged?(true)
        focusTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                guard self.isTimerRunning else { timer.invalidate(); return }
                self.timerSeconds = max(0, self.timerSeconds - 1)
                if self.timerSeconds == 0 {
                    timer.invalidate()
                    self.focusTimer = nil
                    self.finishTimer()
                }
            }
        }
        focusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func resetTimer() {
        isTimerRunning = false
        focusTimer?.invalidate()
        focusTimer = nil
        onTimerVisibilityChanged?(false)
        timerSeconds = timerDuration * 60
    }

    private func finishTimer() {
        isTimerRunning = false
        onTimerVisibilityChanged?(false)
        statusMessage = "Focus session complete"
        // Use the same compact HUD treatment as Caps Lock, with a more
        // noticeable completion sound so the finished session is clear even
        // when the dock is collapsed.
        showSystemHUD(title: "Focus complete", symbol: "checkmark.circle.fill", value: "DONE", mode: "completion")
        playCompletionAlert()
    }

    func beginCustomTimer() {
        // Start with an empty field so the next keystroke replaces the old
        // duration naturally. The current duration is shown as the hint in
        // the field itself.
        customTimerDraft = ""
        isEditingCustomTimer = true
        onRequestKeyboardFocus?()
    }

    func applyCustomTimer() {
        let minutes = min(max(Int(customTimerDraft) ?? timerDuration, 1), 240)
        customTimerDraft = "\(minutes)"
        timerDuration = minutes
        timerSeconds = minutes * 60
        isTimerRunning = false
        focusTimer?.invalidate()
        focusTimer = nil
        onTimerVisibilityChanged?(false)
        isEditingCustomTimer = false
    }

    func applyCustomTimerAndStart() {
        applyCustomTimer()
        startTimer()
    }

    private func playCompletionAlert() {
        // A short three-tone alert is much harder to miss than a single HUD
        // click, while still staying brief and non-intrusive.
        Task { @MainActor in
            for _ in 0..<3 {
                if let sound = NSSound(named: "Basso") ?? NSSound(named: "Funk") ?? NSSound(named: "Glass") {
                    sound.volume = 1.0
                    sound.play()
                }
                // Keep the system alert tone as a guaranteed audible backup.
                NSSound.beep()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func toggleStopwatch() {
        if isStopwatchRunning {
            stopwatchElapsed += Date().timeIntervalSince(stopwatchStart ?? .now)
            stopwatchStart = nil
        } else { stopwatchStart = .now }
        isStopwatchRunning.toggle()
    }
    var currentStopwatch: TimeInterval { stopwatchElapsed + (isStopwatchRunning ? Date().timeIntervalSince(stopwatchStart ?? .now) : 0) }

    func toggleKeepAwake() {
        if keepAwake {
            IOPMAssertionRelease(powerAssertion); powerAssertion = 0; keepAwake = false
        } else {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "NotchDock Keep Awake" as CFString, &powerAssertion)
            keepAwake = result == kIOReturnSuccess
            statusMessage = keepAwake ? "Mac will stay awake" : "Could not enable Keep Awake"
        }
    }

    private var selectedMusicAppName: String {
        UserDefaults.standard.bool(forKey: "notchdock.spotifyConnected") ? "Spotify" : "Music"
    }

    private var selectedMusicBundleID: String {
        selectedMusicAppName == "Spotify" ? "com.spotify.client" : "com.apple.Music"
    }

    private var selectedMusicAppIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == selectedMusicBundleID }
    }

    func runMusicCommand(_ command: String) {
        let appName = selectedMusicAppName
        guard selectedMusicAppIsRunning else {
            let url = URL(string: appName == "Spotify" ? "spotify:" : "music:")!
            guard NSWorkspace.shared.open(url) else {
                statusMessage = "Install \(appName) to use music controls"
                return
            }
            statusMessage = "Opening \(appName)…"
            musicLaunchTask?.cancel()
            musicLaunchTask = Task { @MainActor [weak self] in
                for _ in 0..<24 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    if self?.selectedMusicAppIsRunning == true {
                        self?.executeMusicCommand(command)
                        return
                    }
                }
                self?.statusMessage = "Open \(appName) and allow NotchDock to control it"
            }
            return
        }
        executeMusicCommand(command)
    }

    private func executeMusicCommand(_ command: String) {
        let appName = selectedMusicAppName
        _ = NotchModel.requestAutomationPermission(for: selectedMusicBundleID)
        let source = "tell application \"\(appName)\" to " + command
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error {
                let errNum = error[NSAppleScript.errorNumber] as? Int ?? 0
                if errNum == -1743 || errNum == -1744 {
                    statusMessage = "Allow \(appName) in System Settings → Automation"
                    NotchModel.openAutomationSettings()
                } else {
                    statusMessage = "Allow NotchDock to control \(appName) in System Settings"
                }
            } else {
                statusMessage = "Sent to \(appName)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.refreshNowPlaying()
                }
            }
        }
    }

    func toggleMusicPlayback() {
        // Explicit play/pause is more reliable than `playpause`; runMusicCommand
        // waits for Spotify or Music to finish launching on a fresh install.
        runMusicCommand(musicIsPlaying ? "pause" : "play")
    }

    static func openMusicAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshNowPlaying() {
        let appName = selectedMusicAppName
        guard selectedMusicAppIsRunning else {
            clearNowPlaying()
            return
        }

        let source = """
        tell application "\(appName)"
            try
                set stateText to (player state as text)
                set trackTitle to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track as real
                set trackPosition to player position as real
                return stateText & "||" & trackTitle & "||" & trackArtist & "||" & trackAlbum & "||" & (trackDuration as text) & "||" & (trackPosition as text)
            on error
                return "stopped||||||||0"
            end try
        end tell
        """

        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        guard error == nil, let value = descriptor.stringValue else { return }
        let parts = value.components(separatedBy: "||")
        guard parts.count >= 6 else { return }

        let state = parts[0].lowercased()
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDuration = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        // Spotify's AppleScript dictionary reports track duration in milliseconds
        // (e.g. 210000 for a 3.5-minute song), whereas Apple Music reports seconds.
        let duration = rawDuration > 1000 ? rawDuration / 1000.0 : rawDuration
        let position = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        let hasTrack = !title.isEmpty && state != "stopped"
        let wasPlaying = musicIsPlaying

        musicTrackTitle = hasTrack ? title : ""
        musicTrackArtist = hasTrack ? artist : ""
        musicTrackAlbum = hasTrack ? album : ""
        musicIsPlaying = hasTrack && state == "playing"
        musicDuration = hasTrack ? max(0, duration) : 0
        musicElapsed = hasTrack ? max(0, min(position, max(duration, position))) : 0

        if wasPlaying != musicIsPlaying {
            onMusicVisibilityChanged?(musicIsPlaying)
        }
    }

    private func clearNowPlaying() {
        let wasPlaying = musicIsPlaying
        musicTrackTitle = ""
        musicTrackArtist = ""
        musicTrackAlbum = ""
        musicIsPlaying = false
        musicElapsed = 0
        musicDuration = 0
        if wasPlaying { onMusicVisibilityChanged?(false) }
    }

    func toggleCamera() { cameraActive.toggle() }
    func toggleCameraMirror() { cameraMirrored.toggle() }

    var keyboardLocked: Bool { keyboardLockRemaining > 0 }

    func toggleKeyboardLock() {
        if keyboardLocked {
            keyboardLock.stop()
            keyboardLockTask?.cancel()
            keyboardLockTask = nil
            keyboardLockRemaining = 0
            statusMessage = "Keyboard unlocked"
            return
        }

        guard keyboardLock.start() else {
            statusMessage = "Allow Accessibility access to lock the keyboard"
            return
        }
        keyboardLockRemaining = 60
        statusMessage = "Keyboard locked for 60 seconds"
        keyboardLockTask?.cancel()
        keyboardLockTask = Task { @MainActor [weak self] in
            while let self, self.keyboardLockRemaining > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.keyboardLockRemaining -= 1
            }
            if let self, self.keyboardLockRemaining == 0 {
                self.keyboardLock.stop()
                self.statusMessage = "Keyboard unlocked"
            }
        }
    }

    func showSystemHUD(title: String, symbol: String, value: String, progress: Double? = nil, mode: String = "caps") {
        hudTask?.cancel()
        hudTitle = title
        hudSymbol = symbol
        hudValue = value
        hudProgress = min(max(progress ?? 0.5, 0), 1)
        hudMode = mode
        if !hudActive { hudActive = true }
        // Re-apply the panel frame even when another HUD is already visible;
        // this guarantees a completion popup replaces an older volume HUD.
        onHUDVisibilityChanged?(true)
        hudTask = Task { @MainActor [weak self] in
            let displayMilliseconds = mode == "completion" ? 5000 : 1150
            try? await Task.sleep(for: .milliseconds(displayMilliseconds))
            guard let self, !Task.isCancelled else { return }
            self.hudActive = false
            self.onHUDVisibilityChanged?(false)
        }
    }

}

struct Clip: Identifiable, Codable {
    let id: UUID
    let text: String
    var isPinned: Bool
    init(id: UUID = UUID(), text: String, isPinned: Bool = false) { self.id = id; self.text = text; self.isPinned = isPinned }
}

enum NotchTab: String, CaseIterable, Identifiable {
    case home = "Home", music = "Music", focus = "Focus", clipboard = "Clipboard", shelf = "Shelf", notes = "Notes", tools = "Tools"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: "square.grid.2x2.fill"; case .music: "waveform"; case .focus: "timer"
        case .clipboard: "doc.on.clipboard"; case .shelf: "tray.full"; case .notes: "note.text"; case .tools: "slider.horizontal.3"
        }
    }
}

@MainActor
private final class ShelfViewState: ObservableObject {
    @Published var showingFileImporter = false
}

struct NotchPanelView: View {
    @ObservedObject var model: NotchModel
    let onHoverChanged: (Bool) -> Void
    let onDismiss: () -> Void
    @AppStorage("notchdock.theme") private var themeName = "black"
    @AppStorage("notchdock.spotifyConnected") private var spotifyConnected = false
    @FocusState private var customTimerFieldFocused: Bool
    @StateObject private var shelfState = ShelfViewState()
    @StateObject private var updater = NotchUpdater()

    private var isLightTheme: Bool { themeName == "white" }
    private var ink: Color { isLightTheme ? .black : .white }
    private var surface: Color { isLightTheme ? .white : .black }
    private var isCompactHUD: Bool { model.hudMode == "caps" || model.hudMode == "completion" }
    private var collapsedPanelWidth: CGFloat {
        if model.isTimerRunning { return notchDockTimerWidth }
        if model.musicIsPlaying { return notchDockTimerWidth }
        return notchDockPanelWidth
    }

    var body: some View {
        Group {
            if model.hudActive {
                hudView
            } else {
                VStack(spacing: 0) {
                    notchRail
                    if model.isExpanded { expandedContent.transition(.move(edge: .top).combined(with: .opacity)) }
                }
            }
        }
        .frame(width: model.hudActive ? (isCompactHUD ? 300 : 380) : (model.isExpanded ? notchDockPanelWidth : collapsedPanelWidth), height: model.hudActive ? (isCompactHUD ? 92 : 114) : (model.isExpanded ? notchDockPanelHeight : notchDockCollapsedHeight), alignment: .top)
        .background(surface.opacity(0.99), in: panelShape)
        .overlay(alignment: .top) {
            // A small, borderless bridge makes the surface feel continuous
            // with the physical notch instead of stopping abruptly at it.
            Capsule()
                .fill(surface)
                .frame(width: 360, height: 14)
                .offset(y: -4)
                .allowsHitTesting(false)
        }
        .clipShape(panelShape)
        .contentShape(panelShape)
        .onHover(perform: onHoverChanged)
        .preferredColorScheme(isLightTheme ? .light : .dark)
        .onAppear { updater.checkForUpdates() }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.isExpanded)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: model.hudActive)
        .animation(.easeInOut(duration: 0.2), value: model.selectedTab)
    }

    private var hudView: some View {
        Group {
            VStack(spacing: 0) {
                // The physical notch occupies the top portion of the panel.
                Color.clear.frame(height: 32)
                HStack(spacing: 12) {
                    Image(systemName: model.hudSymbol).font(.system(size: isCompactHUD ? 18 : 16, weight: .semibold)).foregroundStyle(ink.opacity(0.92)).frame(width: 30)
                    Text(model.hudTitle).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(ink.opacity(0.78))
                    Spacer(minLength: 8)
                    Text(model.hudValue).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(ink)
                }.frame(height: 40)
                if !isCompactHUD {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ink.opacity(0.13))
                            Capsule().fill(levelColor).frame(width: max(8, proxy.size.width * model.hudProgress))
                        }
                    }.frame(height: 7).padding(.top, 9)
                    }
                }
        }
        .padding(.horizontal, 22).padding(.bottom, isCompactHUD ? 10 : 17)
        .frame(width: isCompactHUD ? 300 : 380, height: isCompactHUD ? 92 : 114)
        .background(surface.opacity(0.99), in: hudShape)
        .clipShape(hudShape)
        .overlay(alignment: .top) {
            Capsule()
                .fill(surface)
                .frame(width: isCompactHUD ? 230 : 300, height: 12)
                .offset(y: -3)
                .allowsHitTesting(false)
        }
        .transition(.asymmetric(insertion: .scale(scale: 0.72, anchor: .center).combined(with: .opacity), removal: .scale(scale: 0.9).combined(with: .opacity)))
    }

    private var levelColor: Color {
        if model.hudMode == "brightness" { return Color(hue: 0.52 - (0.38 * model.hudProgress), saturation: 0.78, brightness: 1) }
        return Color(hue: 0.34 - (0.34 * model.hudProgress), saturation: 0.8, brightness: 1)
    }

    private var panelShape: NotchSilhouette {
        NotchSilhouette(topRadius: 16, bottomRadius: 26)
    }

    private var hudShape: NotchSilhouette {
        NotchSilhouette(topRadius: 14, bottomRadius: 24)
    }

struct NotchSilhouette: Shape {
    var topRadius: CGFloat = 16
    var bottomRadius: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let tr = min(topRadius, min(w / 4, h / 2))
        let br = min(bottomRadius, min((w - 2 * tr) / 2, h - tr))

        path.move(to: CGPoint(x: 0, y: 0))

        // Top-left outward curve: from (0, 0) curving down to (tr, tr)
        path.addArc(
            center: CGPoint(x: 0, y: tr),
            radius: tr,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        // Left vertical edge down to (tr, h - br)
        path.addLine(to: CGPoint(x: tr, y: h - br))

        // Bottom-left inward curve: from (tr, h - br) to (tr + br, h)
        path.addArc(
            center: CGPoint(x: tr + br, y: h - br),
            radius: br,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )

        // Bottom horizontal edge
        path.addLine(to: CGPoint(x: w - tr - br, y: h))

        // Bottom-right inward curve: from (w - tr - br, h) to (w - tr, h - br)
        path.addArc(
            center: CGPoint(x: w - tr - br, y: h - br),
            radius: br,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )

        // Right vertical edge up to (w - tr, tr)
        path.addLine(to: CGPoint(x: w - tr, y: tr))

        // Top-right outward curve: from (w - tr, tr) curving up and out to (w, 0)
        path.addArc(
            center: CGPoint(x: w, y: tr),
            radius: tr,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        // Top edge flush with display bezel
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.closeSubpath()
        return path
    }
}

    @ViewBuilder private var notchRail: some View {
        if model.isTimerRunning && !model.isExpanded {
            timerStrip
        } else if model.musicIsPlaying && !model.isExpanded {
            musicStrip
        } else {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path").foregroundStyle(ink.opacity(0.72))
                Text("NOTCHDOCK").tracking(0.8).foregroundStyle(ink.opacity(0.55))
            }.font(.system(size: 8, weight: .bold, design: .rounded)).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 420, height: 1)
            HStack(spacing: 9) {
                if model.isTimerRunning { Text(timerString).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit() }
                Button {
                    if updater.updateAvailable { updater.installLatest() } else { updater.checkForUpdates() }
                } label: {
                    Label(updater.updateAvailable ? "Update" : "Check", systemImage: updater.updateAvailable ? "arrow.down.circle.fill" : "arrow.clockwise")
                }
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .buttonStyle(UpdateButtonStyle())
                .disabled(updater.isChecking || updater.isInstalling)
                Button { onDismiss() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(ink.opacity(0.62)).frame(width: 22, height: 22).background(ink.opacity(0.09), in: Circle()) }.buttonStyle(.plain)
            }.foregroundStyle(ink).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(.horizontal, 32).frame(height: 40)
        }
    }

    private var timerStrip: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(ink.opacity(0.18), lineWidth: 2).padding(2)
                Circle()
                    .trim(from: 0, to: timerProgress)
                    .stroke(ink.opacity(0.92), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(2)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "timer")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.76))
            }
            .frame(width: 24, height: 24)
            Spacer(minLength: 8)
            Text(timerString)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ink)
        }
        .offset(y: 6)
        .padding(.horizontal, 18)
        .frame(width: notchDockTimerWidth, height: notchDockCollapsedHeight)
        .background(ink.opacity(0.1), in: Capsule())
        .overlay(Capsule().stroke(ink.opacity(0.13), lineWidth: 1))
    }

    private var musicStrip: some View {
        HStack(spacing: 12) {
            Text(musicElapsedString)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ink)
            Spacer(minLength: 8)
            ZStack {
                Circle().stroke(ink.opacity(0.18), lineWidth: 2).padding(2)
                Circle()
                    .trim(from: 0, to: musicProgress)
                    .stroke(ink.opacity(0.92), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(2)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "music.note")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.76))
            }
            .frame(width: 24, height: 24)
        }
        .offset(y: 6)
        .padding(.horizontal, 18)
        .frame(width: notchDockTimerWidth, height: notchDockCollapsedHeight)
        .background(ink.opacity(0.1), in: Capsule())
        .overlay(Capsule().stroke(ink.opacity(0.13), lineWidth: 1))
    }

    private var expandedContent: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.selectedTab.rawValue).font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("A useful little space in your notch").font(.system(size: 11)).foregroundStyle(ink.opacity(0.48))
                    }
                    Spacer()
                    if model.selectedTab == .tools {
                        Button(model.keyboardLocked ? "Unlock \(model.keyboardLockRemaining)s" : "Lock keyboard 60s") {
                            model.toggleKeyboardLock()
                        }
                        .buttonStyle(AccentButton())
                    }
                    if model.selectedTab == .focus {
                        Button("Custom timer") { model.beginCustomTimer() }
                            .buttonStyle(AccentButton())
                    }
                    if !model.statusMessage.isEmpty { Text(model.statusMessage).font(.system(size: 10)).foregroundStyle(ink.opacity(0.5)).lineLimit(1) }
                }.padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(NotchTab.allCases) { tab in
                            Button { model.selectedTab = tab } label: {
                                Label(tab.rawValue, systemImage: tab.symbol).font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(model.selectedTab == tab ? ink.opacity(0.17) : ink.opacity(0.055), in: Capsule())
                                    .foregroundStyle(ink.opacity(model.selectedTab == tab ? 1 : 0.64))
                            }.buttonStyle(.plain)
                        }
                        Button("Custom timer") {
                            model.selectedTab = .focus
                            model.beginCustomTimer()
                        }
                        .buttonStyle(AccentButton())
                    }.padding(.horizontal, 28)
                }.padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    Group {
                        switch model.selectedTab {
                        case .home: home; case .music: music; case .focus: focus
                        case .clipboard: clipboard; case .shelf: shelf; case .notes: notes; case .tools: tools
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 16)
                }
            }
            if model.showingUpdateNotice {
                ZStack {
                    Color.black.opacity(0.72)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture {
                            model.dismissUpdateNotice()
                        }

                    updateNoticeCard
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .frame(width: notchDockPanelWidth, height: notchDockPanelHeight - 40, alignment: .top)
    }

    private var updateNoticeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        LinearGradient(colors: [Color(red: 1.0, green: 0.45, blue: 0.1), Color(red: 0.95, green: 0.22, blue: 0.15)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New in NotchDock")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if !model.updateNoticeVersion.isEmpty {
                        Text("Version \(model.updateNoticeVersion)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.15))
                    }
                }
                Spacer()
                Button {
                    model.dismissUpdateNotice()
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                let lines = model.updateNoticeMessage.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(lines, id: \.self) { line in
                            if line == "WHAT'S NEW" {
                                Label("What’s New", systemImage: "sparkles")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.15))
                                    .padding(.top, 2)
                            } else if line == "WHAT'S FIXED" {
                                Label("What’s Fixed", systemImage: "wrench.and.screwdriver.fill")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
                                    .padding(.top, 6)
                            } else if line == "IMPROVEMENTS" {
                                Label("Improvements", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.green)
                                    .padding(.top, 6)
                            } else {
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Color.white.opacity(0.4))
                                        .frame(width: 4, height: 4)
                                        .padding(.top, 6)
                                    Text(line.replacingOccurrences(of: "^[•\\-*]\\s*", with: "", options: .regularExpression))
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.9))
                                        .lineSpacing(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack {
                Spacer()
                Button {
                    model.dismissUpdateNotice()
                } label: {
                    Text("Got it")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(colors: [Color(red: 1.0, green: 0.45, blue: 0.1), Color(red: 0.95, green: 0.25, blue: 0.15)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(maxWidth: 520)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 30, y: 15)
    }

    private var home: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                nowPlayingDashboard
                    .frame(maxWidth: .infinity, minHeight: 245, maxHeight: 245, alignment: .topLeading)
                focusDashboard
                    .frame(maxWidth: .infinity, minHeight: 245, maxHeight: 245, alignment: .topLeading)
                upNextDashboard
                    .frame(maxWidth: .infinity, minHeight: 245, maxHeight: 245, alignment: .topLeading)
            }
            HStack(alignment: .top, spacing: 14) {
                quickNoteDashboard
                    .frame(maxWidth: .infinity, minHeight: 145, maxHeight: 145, alignment: .topLeading)
                systemDashboard
                    .frame(maxWidth: .infinity, minHeight: 145, maxHeight: 145, alignment: .topLeading)
                cameraDashboard
                    .frame(maxWidth: .infinity, minHeight: 145, maxHeight: 145, alignment: .topLeading)
                shelfDashboard
                    .frame(maxWidth: .infinity, minHeight: 145, maxHeight: 145, alignment: .topLeading)
            }
        }
    }

    private var nowPlayingDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            dashboardHeader(spotifyConnected ? "Spotify" : "Now Playing", symbol: "music.note")
            if model.musicTrackTitle.isEmpty {
                Text(spotifyConnected ? "Spotify controls" : "Apple Music controls")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.82))
                Text("Nothing playing")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ink.opacity(0.48))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.musicTrackTitle)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.opacity(0.9))
                        .lineLimit(2)
                    Text(model.musicTrackArtist.isEmpty ? "Unknown artist" : model.musicTrackArtist)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink.opacity(0.62))
                        .lineLimit(1)
                    if !model.musicTrackAlbum.isEmpty {
                        Text(model.musicTrackAlbum)
                            .font(.system(size: 11))
                            .foregroundStyle(ink.opacity(0.42))
                            .lineLimit(1)
                    }
                    if !model.musicIsPlaying {
                        Text("Paused")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.42))
                    }
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 9) {
                transport("backward.end.fill", command: "previous track")
                transport("playpause.fill", command: "playpause")
                transport("forward.end.fill", command: "next track")
                Spacer()
                Button(spotifyConnected ? "Open Spotify" : "Open Music") {
                    let url = URL(string: spotifyConnected ? "spotify:" : "music:")!
                    NSWorkspace.shared.open(url)
                }.buttonStyle(ChipButton())
            }
        }
        .dashboardSurface(ink: ink)
    }

    private var focusDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            dashboardHeader("Focus", symbol: "timer")
            Spacer(minLength: 2)
            Text(model.isTimerRunning ? timerString : "25:00")
                .font(.system(size: 48, weight: .light, design: .rounded))
                .monospacedDigit()
            Text(model.isTimerRunning ? "Session in progress" : "Ready when you are")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink.opacity(0.48))
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                Button(model.isTimerRunning ? "Pause" : "Start") { model.startTimer(minutes: 25) }.buttonStyle(AccentButton())
                Button("45 min") { model.startTimer(minutes: 45) }.buttonStyle(ChipButton())
                Button("60 min") { model.startTimer(minutes: 60) }.buttonStyle(ChipButton())
            }
        }
        .dashboardSurface(ink: ink)
    }

    private var upNextDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            dashboardHeader("Up Next", symbol: "calendar.badge.clock")
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .medium)).foregroundStyle(ink.opacity(0.48))
                Text("All clear").font(.system(size: 15, weight: .semibold)).foregroundStyle(ink.opacity(0.68))
                Text("No upcoming focus sessions").font(.system(size: 11)).foregroundStyle(ink.opacity(0.42))
            }.frame(maxWidth: .infinity)
            Spacer()
        }
        .dashboardSurface(ink: ink)
    }

    private var quickNoteDashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            dashboardHeader("Quick Note", symbol: "note.text")
            TextField("Type a note & press Return…", text: $model.quickNoteDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink)
                .padding(9)
                .background(ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                .onSubmit {
                    model.submitQuickNote()
                }
                .onTapGesture {
                    model.onRequestKeyboardFocus?()
                }
            HStack {
                Text(model.statusMessage.isEmpty ? "Press ↵ to save to Apple Notes" : model.statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(ink.opacity(0.48))
                    .lineLimit(1)
                Spacer()
                Button("Open notes") { model.selectedTab = .notes }.buttonStyle(ChipButton())
            }
        }
        .dashboardSurface(ink: ink)
    }

    private var systemDashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            dashboardHeader("System", symbol: "gauge.with.dots.needle.67percent")
            HStack(spacing: 24) {
                dashboardMetric("Clipboard", value: "\(model.clips.count)", symbol: "doc.on.clipboard")
                dashboardMetric("Shelf", value: "\(model.shelfURLs.count)", symbol: "tray.full")
                dashboardMetric("HUDs", value: "Ready", symbol: "sparkles")
            }
            Spacer()
            Text("System indicators are available from the notch.").font(.system(size: 11)).foregroundStyle(ink.opacity(0.42))
        }
        .dashboardSurface(ink: ink)
    }

    private var shelfDashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            dashboardHeader("File Shelf", symbol: "tray.full")
            Text(model.shelfURLs.isEmpty ? "Nothing staged" : "\(model.shelfURLs.count) item\(model.shelfURLs.count == 1 ? "" : "s") ready")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.76))
            Spacer()
            Button("Open shelf") { model.selectedTab = .shelf }.buttonStyle(ChipButton())
        }
        .dashboardSurface(ink: ink)
    }

    private var cameraDashboard: some View {
        ZStack(alignment: .topLeading) {
            Group {
                GeometryReader { proxy in
                    Group {
                        if model.cameraActive {
                            CameraPreview(isActive: true, isMirrored: model.cameraMirrored)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "camera").font(.system(size: 28)).foregroundStyle(ink.opacity(0.46))
                                Text("Click to start camera").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.52))
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleCamera() }

            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 54)
                .allowsHitTesting(false)

            HStack {
                dashboardHeader("Camera", symbol: "camera")
                    .foregroundStyle(.white)
                Spacer()
                if model.cameraActive {
                    HStack(spacing: 6) {
                        Button { model.toggleCamera() } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 25, height: 25)
                                .background(.black.opacity(0.62), in: Circle())
                        }
                        .buttonStyle(.plain)
                        Button { model.toggleCameraMirror() } label: {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 25, height: 25)
                                .background(.black.opacity(0.62), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, minHeight: 145, maxHeight: 145)
        .background(ink.opacity(0.075), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(ink.opacity(0.1), lineWidth: 1) }
    }

    private func dashboardHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(ink.opacity(0.82))
    }

    private func dashboardMetric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(ink.opacity(0.56))
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 10)).foregroundStyle(ink.opacity(0.42))
        }
    }

    private var music: some View {
        VStack(spacing: 12) {
            HStack(spacing: 13) {
                Image(systemName: "music.note").font(.system(size: 21)).foregroundStyle(ink).frame(width: 54, height: 54).background(LinearGradient(colors: [.purple.opacity(0.8), .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.musicTrackTitle.isEmpty ? (spotifyConnected ? "Spotify" : "Apple Music") : model.musicTrackTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(model.musicTrackTitle.isEmpty ? "Nothing playing" : (model.musicTrackArtist.isEmpty ? "Unknown artist" : model.musicTrackArtist))
                        .font(.system(size: 10))
                        .foregroundStyle(ink.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
                transport("backward.end.fill", command: "previous track"); transport("playpause.fill", command: "playpause"); transport("forward.end.fill", command: "next track")
            }.card()
            Label(spotifyConnected ? "Spotify controls are active for this notch." : "Media controls target Apple Music.", systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(ink.opacity(0.48)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }
    }
    private var focus: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "timer").font(.system(size: 17, weight: .semibold)).frame(width: 38, height: 38).background(ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Custom timer").font(.system(size: 12, weight: .semibold))
                    Text("Choose any duration from 1 to 240 minutes").font(.system(size: 10)).foregroundStyle(ink.opacity(0.48))
                }
                Spacer()
                Button("Set custom minutes") { model.beginCustomTimer() }.buttonStyle(AccentButton())
            }.card()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) { Text("Focus session").font(.system(size: 13, weight: .semibold)); Text("Choose a pace, then get into it").font(.system(size: 10)).foregroundStyle(ink.opacity(0.5)) }
                Spacer()
                Text(timerString).font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
            }.card()
            HStack(spacing: 8) {
                ForEach([25, 45, 60], id: \.self) { mins in Button("\(mins) min") { model.startTimer(minutes: mins) }.buttonStyle(ChipButton()) }
                Button("Custom timer") { model.beginCustomTimer() }.buttonStyle(AccentButton())
                Spacer()
                Button { model.startTimer() } label: { Label(model.isTimerRunning ? "Pause" : "Start", systemImage: model.isTimerRunning ? "pause.fill" : "play.fill") }.buttonStyle(AccentButton())
                Button { model.resetTimer() } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(ChipButton())
            }
            if model.isEditingCustomTimer {
                HStack(spacing: 8) {
                    Label("Custom minutes", systemImage: "timer")
                    TextField("\(model.timerDuration)", text: $model.customTimerDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 78)
                        .focused($customTimerFieldFocused)
                        .onSubmit { model.applyCustomTimerAndStart() }
                        .onChange(of: model.customTimerDraft) { value in
                            let filtered = value.filter(\.isNumber)
                            if filtered != value { model.customTimerDraft = filtered }
                        }
                    Button("Set & start") { model.applyCustomTimerAndStart() }.buttonStyle(AccentButton())
                    Button("Cancel") { model.isEditingCustomTimer = false }.buttonStyle(ChipButton())
                    Spacer()
                }
                .card()
                .onAppear { customTimerFieldFocused = true }
                .onChange(of: model.isEditingCustomTimer) { editing in
                    customTimerFieldFocused = editing
                }
            }
            HStack {
                Label("Stopwatch", systemImage: "stopwatch").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(stopwatchString).font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
                Button(model.isStopwatchRunning ? "Pause" : "Start") { model.toggleStopwatch() }.buttonStyle(ChipButton())
            }.card()
            Button { model.toggleKeepAwake() } label: { Label(model.keepAwake ? "Keep Awake is on" : "Keep Mac Awake", systemImage: model.keepAwake ? "sun.max.fill" : "moon.zzz") }.buttonStyle(ChipButton()).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var clipboard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { TextField("Search copied text", text: $model.clipSearch).textFieldStyle(.plain).padding(10).background(ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)); Button("Clear") { model.clearClips() }.buttonStyle(ChipButton()) }
            let filtered = model.clips.filter { model.clipSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(model.clipSearch) }
            if filtered.isEmpty { emptyState("Copied text will appear here", symbol: "doc.on.clipboard") }
            ForEach(filtered) { clip in
                HStack(spacing: 8) {
                    Text(clip.text).font(.system(size: 11)).lineLimit(2).foregroundStyle(ink.opacity(0.82)).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.copy(clip) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(IconButton())
                    Button { model.togglePin(clip) } label: { Image(systemName: model.pinnedIDs.contains(clip.id) ? "pin.fill" : "pin") }.buttonStyle(IconButton())
                }.padding(10).background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Clipboard monitoring stays on this Mac. Copies are kept locally.").font(.system(size: 9)).foregroundStyle(ink.opacity(0.4))
        }
    }
    private var shelf: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 14).fill(ink.opacity(0.035)).overlay {
                VStack(spacing: 8) { Image(systemName: "arrow.down.doc").font(.system(size: 23)).foregroundStyle(ink.opacity(0.7)); Text("Drop files here to keep them handy").font(.system(size: 11)).foregroundStyle(ink.opacity(0.58)); Text("Files stay in their original folders").font(.system(size: 9)).foregroundStyle(ink.opacity(0.37)) }
            }.frame(height: 100).overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ink.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                    for provider in providers { _ = provider.loadObject(ofClass: NSURL.self) { object, _ in if let nsurl = object as? NSURL { let url = nsurl as URL; Task { @MainActor in model.addFiles([url]) } } } }
                    return !providers.isEmpty
                }
            HStack(spacing: 8) {
                Button { shelfState.showingFileImporter = true } label: { Label("Choose files", systemImage: "plus") }.buttonStyle(ChipButton())
                Button { model.airDropShelfFiles() } label: { Label("AirDrop all", systemImage: "antenna.radiowaves.left.and.right") }.buttonStyle(AccentButton()).disabled(model.shelfURLs.isEmpty)
                Spacer()
                if !model.shelfURLs.isEmpty {
                    Text("\(model.shelfURLs.count) staged")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.48))
                }
            }
            if model.shelfURLs.isEmpty { emptyState("Your staged files appear here", symbol: "tray") }
            ForEach(model.shelfURLs, id: \.absoluteString) { url in
                HStack(spacing: 9) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 27, height: 27)
                    VStack(alignment: .leading, spacing: 3) { Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1); Text(url.deletingLastPathComponent().path).font(.system(size: 9)).foregroundStyle(ink.opacity(0.4)).lineLimit(1) }
                    Spacer()
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(IconButton())
                    Button { model.removeFile(url) } label: { Image(systemName: "xmark") }.buttonStyle(IconButton())
                }.padding(9).background(ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 10)).draggable(url)
            }
        }
        .fileImporter(isPresented: $shelfState.showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
    }
    private var notes: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Notes").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Type a quick note and press Enter to save to Apple Notes. Synced with Notes.app.")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.48))
                }
                Spacer()
                Button {
                    model.syncAppleNotes()
                } label: {
                    Label(model.isSyncingNotes ? "Syncing…" : "Sync", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ChipButton())
                .disabled(model.isSyncingNotes)

                Button {
                    NSWorkspace.shared.open(URL(string: "notes:") ?? URL(fileURLWithPath: "/System/Applications/Notes.app"))
                } label: {
                    Label("Open Notes.app", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(AccentButton())
            }

            HStack(spacing: 8) {
                TextField("Write a note and press Enter…", text: $model.quickNoteDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ink)
                    .padding(12)
                    .background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                    .onSubmit {
                        model.submitQuickNote()
                    }
                    .onTapGesture {
                        model.onRequestKeyboardFocus?()
                    }

                Button {
                    model.submitQuickNote()
                } label: {
                    Label("Save (↵)", systemImage: "arrow.turn.down.left")
                }
                .buttonStyle(AccentButton())
                .disabled(model.quickNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Apple Notes Feed").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(ink.opacity(0.55))
                    Spacer()
                    if !model.statusMessage.isEmpty {
                        Text(model.statusMessage).font(.system(size: 10)).foregroundStyle(.green.opacity(0.8))
                    }
                }

                if !model.appleNotes.isEmpty {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.appleNotes) { item in
                                Button {
                                    model.openNoteInAppleNotes(id: item.id)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "note.text")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.15))
                                            .padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(item.title)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(ink)
                                                    .lineLimit(1)
                                                Spacer()
                                                if !item.date.isEmpty {
                                                    Text(item.date)
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(ink.opacity(0.35))
                                                }
                                            }
                                            if !item.snippet.isEmpty && item.snippet != item.title {
                                                Text(item.snippet)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(ink.opacity(0.65))
                                                    .lineLimit(2)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(10)
                                    .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                } else if !model.recentNotes.isEmpty {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.recentNotes, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "note.text").font(.system(size: 11)).foregroundStyle(ink.opacity(0.45)).padding(.top, 2)
                                    Text(item).font(.system(size: 12)).foregroundStyle(ink.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                } else {
                    Text("No notes yet. Type a note above and press Enter to save to Apple Notes.")
                        .font(.system(size: 11))
                        .foregroundStyle(ink.opacity(0.42))
                        .padding(.vertical, 8)
                }
            }
        }
        .onAppear {
            model.syncAppleNotes()
        }
    }
    private var tools: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: model.keyboardLocked ? "lock.fill" : "keyboard")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard Lock").font(.system(size: 12, weight: .semibold))
                    Text(model.keyboardLocked ? "Unlocks in \(model.keyboardLockRemaining)s" : "Disable keyboard input for 60 seconds")
                        .font(.system(size: 10)).foregroundStyle(ink.opacity(0.48))
                }
                Spacer()
                Button(model.keyboardLocked ? "Unlock" : "Lock 60s") { model.toggleKeyboardLock() }.buttonStyle(AccentButton())
            }.card()
            Text("Available now").font(.system(size: 12, weight: .semibold))
            HStack { toolRow("Keep Awake", detail: "Prevent sleep while enabled", symbol: "moon.zzz") { model.toggleKeepAwake() }; Spacer(); Toggle("", isOn: Binding(get: { model.keepAwake }, set: { _ in model.toggleKeepAwake() })).labelsHidden().toggleStyle(.switch) }.card()
        }
    }

    private var musicCard: some View { HStack(spacing: 12) {
        Image(systemName: "music.note").font(.system(size: 17)).foregroundStyle(ink).frame(width: 42, height: 42).background(ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
        VStack(alignment: .leading, spacing: 3) {
            Text(model.musicTrackTitle.isEmpty ? "Music controls" : model.musicTrackTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(model.musicTrackTitle.isEmpty ? (spotifyConnected ? "Control Spotify from the notch" : "Control Apple Music from the notch") : (model.musicTrackArtist.isEmpty ? "Unknown artist" : model.musicTrackArtist))
                .font(.system(size: 10))
                .foregroundStyle(ink.opacity(0.47))
                .lineLimit(1)
        }
        Spacer(); transport("backward.end.fill", command: "previous track"); transport("playpause.fill", command: "playpause"); transport("forward.end.fill", command: "next track")
    }.card() }
    private var focusMini: some View { VStack(alignment: .leading, spacing: 7) { Label("FOCUS TIMER", systemImage: "timer").font(.system(size: 9, weight: .bold)).foregroundStyle(ink.opacity(0.52)); Text(model.isTimerRunning ? timerString : "25:00").font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit(); Button(model.isTimerRunning ? "Pause" : "Start 25 min") { model.startTimer(minutes: 25) }.buttonStyle(ChipButton()) }.frame(maxWidth: .infinity, alignment: .leading).card() }
    private var noteMini: some View { VStack(alignment: .leading, spacing: 7) { Label("QUICK NOTE", systemImage: "note.text").font(.system(size: 9, weight: .bold)).foregroundStyle(ink.opacity(0.52)); Text(model.note.isEmpty ? "Capture a thought" : model.note).font(.system(size: 11)).lineLimit(2).foregroundStyle(ink.opacity(0.76)); Button("Open notes") { model.selectedTab = .notes }.buttonStyle(ChipButton()) }.frame(maxWidth: .infinity, alignment: .leading).card() }
    private var timerString: String { String(format: "%02d:%02d", model.timerSeconds / 60, model.timerSeconds % 60) }
    private var musicElapsedString: String {
        let elapsed = max(0, Int(model.musicElapsed))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
    private var timerProgress: Double {
        let total = max(model.timerDuration * 60, 1)
        return min(max(Double(model.timerSeconds) / Double(total), 0), 1)
    }
    private var musicProgress: Double {
        guard model.musicDuration > 0 else { return 0 }
        return min(max(model.musicElapsed / model.musicDuration, 0), 1)
    }
    private var stopwatchString: String { let s = Int(model.currentStopwatch); return String(format: "%02d:%02d", s / 60, s % 60) }
    private func transport(_ symbol: String, command: String) -> some View { Button {
        if command == "playpause" { model.toggleMusicPlayback() } else { model.runMusicCommand(command) }
    } label: {
        Image(systemName: command == "playpause" && model.musicIsPlaying ? "pause.fill" : (command == "playpause" ? "play.fill" : symbol))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: 31, height: 31)
            .background(ink.opacity(0.09), in: Circle())
    }.buttonStyle(.plain) }
    private func metricCard(_ title: String, value: String, symbol: String, action: @escaping () -> Void) -> some View { Button(action: action) { VStack(alignment: .leading, spacing: 8) { Image(systemName: symbol).foregroundStyle(ink.opacity(0.62)); Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)); Text(title).font(.system(size: 9)).foregroundStyle(ink.opacity(0.48)) }.frame(maxWidth: .infinity, alignment: .leading).card() }.buttonStyle(.plain) }
    private func toolRow(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View { Button(action: action) { Label { VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 11, weight: .medium)); Text(detail).font(.system(size: 9)).foregroundStyle(ink.opacity(0.43)) } } icon: { Image(systemName: symbol).foregroundStyle(ink.opacity(0.65)) } }.buttonStyle(.plain) }
    private func emptyState(_ title: String, symbol: String) -> some View { VStack(spacing: 8) { Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(ink.opacity(0.34)); Text(title).font(.system(size: 10)).foregroundStyle(ink.opacity(0.42)) }.frame(maxWidth: .infinity).padding(.vertical, 25) }
}

private struct ChipButton: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var ink: Color { colorScheme == .light ? .black : .white }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(configuration.isPressed ? 0.55 : 0.8)).padding(.horizontal, 10).padding(.vertical, 7).background(ink.opacity(configuration.isPressed ? 0.12 : 0.07), in: Capsule())
    }
}
private struct AccentButton: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var ink: Color { colorScheme == .light ? .white : .black }
    var fill: Color { colorScheme == .light ? .black : .white }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .semibold)).foregroundStyle(ink).padding(.horizontal, 13).padding(.vertical, 8).background(fill.opacity(configuration.isPressed ? 0.7 : 0.95), in: Capsule())
    }
}
private struct IconButton: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var ink: Color { colorScheme == .light ? .black : .white }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10)).foregroundStyle(ink.opacity(0.65)).frame(width: 26, height: 26).background(ink.opacity(configuration.isPressed ? 0.13 : 0.06), in: Circle())
    }
}
private struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var ink: Color { colorScheme == .light ? .black : .white }
    func body(content: Content) -> some View {
        content.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(ink.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }
}
private struct DashboardSurfaceModifier: ViewModifier {
    let ink: Color
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ink.opacity(0.075), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }
}
private extension View {
    func card() -> some View { modifier(CardModifier()) }
    func dashboardSurface(ink: Color) -> some View { modifier(DashboardSurfaceModifier(ink: ink)) }
}

struct CameraPreview: NSViewRepresentable {
    let isActive: Bool
    let isMirrored: Bool

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.setActive(isActive)
        view.setMirrored(isMirrored)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        nsView.setActive(isActive)
        nsView.setMirrored(isMirrored)
        nsView.updatePreviewFrame()
    }
}

final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "notchdock.camera.session")
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var configured = false
    private var active = false
    private var mirrored = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updatePreviewFrame()
    }

    func updatePreviewFrame() { previewLayer.frame = bounds }

    func setActive(_ active: Bool) {
        self.active = active
        if active {
            requestAccessAndConfigure()
        } else {
            sessionQueue.async { [weak self] in self?.session.stopRunning() }
        }
    }

    func setMirrored(_ mirrored: Bool) {
        self.mirrored = mirrored
        DispatchQueue.main.async { [weak self] in
            guard let self, let connection = self.previewLayer.connection, connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                self?.configureSession()
            }
        default:
            break
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.configured else { return }
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  self.session.canAddInput(input) else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            self.session.addInput(input)
            self.session.commitConfiguration()
            self.configured = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.previewLayer.session = self.session
                self.setMirrored(self.mirrored)
                if self.active { self.sessionQueue.async { [weak self] in self?.session.startRunning() } }
            }
        }
    }

    deinit {
        sessionQueue.async { [session] in session.stopRunning() }
    }
}

final class KeyboardLockController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isLocked = false

    func start() -> Bool {
        guard eventTap == nil else { return true }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<KeyboardLockController>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return controller.isLocked ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: pointer
        ) else { return false }

        eventTap = tap
        isLocked = true
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        isLocked = false
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
    }
}

struct SettingsView: View {
    @AppStorage("notchdock.closeDelay") private var closeDelay = 0.12
    @AppStorage("notchdock.indicatorMode") private var indicatorMode = "both"
    @AppStorage("notchdock.capsLockHUDEnabled") private var capsLockHUDEnabled = true
    @AppStorage("notchdock.systemHUDsEnabled") private var systemHUDsEnabled = true
    @AppStorage("notchdock.spotifyConnected") private var spotifyConnected = false
    @AppStorage("notchdock.theme") private var themeName = "black"
    @AppStorage("notchdock.launchAtLogin") private var launchAtLogin = false
    @AppStorage("notchdock.fakeNotchEnabled") private var fakeNotchEnabled = false
    @AppStorage("notchdock.fakeNotchStyle") private var fakeNotchStyle = "notch"
    @AppStorage("notchdock.fakeNotchWidth") private var fakeNotchWidth = 180.0
    @AppStorage("notchdock.fakeNotchHeight") private var fakeNotchHeight = 32.0
    @AppStorage("notchdock.fakeNotchOnlyWithoutPhysicalNotch") private var fakeNotchOnlyWithoutPhysicalNotch = false
    @AppStorage("notchdock.fakeNotchShowCamera") private var fakeNotchShowCamera = true
    @AppStorage("notchdock.showTriggerBump") private var showTriggerBump = false
    @StateObject private var updater = NotchUpdater()

    private var isLightTheme: Bool { themeName == "white" }
    private var ink: Color { isLightTheme ? .black : .white }
    private var surface: Color { isLightTheme ? .white : Color(red: 0.08, green: 0.08, blue: 0.09) }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            integrationsTab
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .padding(.top, 8)
        .frame(minWidth: 620, minHeight: 430)
        .background(surface)
        .preferredColorScheme(isLightTheme ? .light : .dark)
        .onAppear { updater.checkForUpdates() }
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader("General", subtitle: "Make NotchDock feel right on your Mac.")
                updateBanner
                settingsSection("Startup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: {
                                if #available(macOS 13.0, *) {
                                    return SMAppService.mainApp.status == .enabled || launchAtLogin
                                }
                                return launchAtLogin
                            },
                            set: { enabled in
                                launchAtLogin = enabled
                                if #available(macOS 13.0, *) {
                                    do {
                                        if enabled {
                                            if SMAppService.mainApp.status != .enabled {
                                                try SMAppService.mainApp.register()
                                            }
                                        } else {
                                            if SMAppService.mainApp.status == .enabled {
                                                try SMAppService.mainApp.unregister()
                                            }
                                        }
                                    } catch {
                                        print("LaunchAtLogin SMAppService error:", error)
                                    }
                                }
                            }
                        )) {
                            Label("Open NotchDock on startup", systemImage: "power")
                        }
                        .toggleStyle(.switch)

                        Text("Automatically launch NotchDock whenever you log in or restart your Mac.")
                            .font(.system(size: 11))
                            .foregroundStyle(ink.opacity(0.48))
                    }
                }
                settingsSection("Screen Notch & Trigger") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $fakeNotchEnabled) {
                            Label("Enable fake notch", systemImage: "sparkles.rectangle.stack")
                        }
                        .toggleStyle(.switch)

                        Text("Simulates a visual notch or island at the top of your screen. Perfect for external displays and Macs without a physical notch.")
                            .font(.system(size: 11))
                            .foregroundStyle(ink.opacity(0.48))

                        if fakeNotchEnabled {
                            VStack(alignment: .leading, spacing: 14) {
                                Divider().opacity(0.15)

                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Shape", systemImage: "rectangle.topthird.inset.filled")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(ink.opacity(0.8))

                                    Picker("Notch Shape", selection: $fakeNotchStyle) {
                                        Text("MacBook Notch").tag("notch")
                                        Text("Dynamic Island").tag("island")
                                    }
                                    .pickerStyle(.segmented)

                                    Text(fakeNotchStyle == "island" ? "A floating pill inspired by the Dynamic Island." : "Classic MacBook notch sitting flush with the top display bezel.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(ink.opacity(0.48))
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Label("Width", systemImage: "arrow.left.and.right")
                                        Spacer()
                                        Text("\(Int(fakeNotchWidth)) px")
                                            .font(.system(size: 11))
                                            .foregroundStyle(ink.opacity(0.56))
                                            .monospacedDigit()
                                    }
                                    Slider(value: $fakeNotchWidth, in: 120...260, step: 2)
                                        .tint(ink)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Label("Height", systemImage: "arrow.up.and.down")
                                        Spacer()
                                        Text("\(Int(fakeNotchHeight)) px")
                                            .font(.system(size: 11))
                                            .foregroundStyle(ink.opacity(0.56))
                                            .monospacedDigit()
                                    }
                                    Slider(value: $fakeNotchHeight, in: 24...38, step: 1)
                                        .tint(ink)
                                }

                                Toggle(isOn: $fakeNotchShowCamera) {
                                    Label("Show camera lens reflection", systemImage: "camera.circle")
                                }
                                .toggleStyle(.switch)

                                Toggle(isOn: $fakeNotchOnlyWithoutPhysicalNotch) {
                                    Label("Only show on notchless displays", systemImage: "display.2")
                                }
                                .toggleStyle(.switch)

                                Text("Automatically hides the simulated notch when running on a MacBook with a built-in physical notch.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ink.opacity(0.48))
                            }
                            .padding(12)
                            .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }

                        Divider().opacity(0.15)

                        Toggle(isOn: $showTriggerBump) {
                            Label("Show small trigger bump", systemImage: "capsule.portrait")
                        }
                        .toggleStyle(.switch)

                        Text("Displays a minimal, discreet bump at the top edge of your screen as a tactile hover target for NotchDock.")
                            .font(.system(size: 11))
                            .foregroundStyle(ink.opacity(0.48))

                        if fakeNotchEnabled && showTriggerBump {
                            Label("The fake notch takes visual precedence over the small bump when both are enabled.", systemImage: "info.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(ink.opacity(0.45))
                        }
                    }
                }
                settingsSection("Hover behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Close delay", systemImage: "cursorarrow.rays")
                            Spacer()
                            Text("\(Int(closeDelay * 1000)) ms").foregroundStyle(ink.opacity(0.56)).monospacedDigit()
                        }
                        Slider(value: $closeDelay, in: 0.05...0.35, step: 0.01)
                            .tint(ink)
                        Text("A tiny delay prevents accidental closes when you skim the edge of the notch.")
                            .font(.system(size: 11)).foregroundStyle(ink.opacity(0.48))
                    }
                }
                settingsSection("Volume & Brightness indicators") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Indicator style", selection: $indicatorMode) {
                            Text("Both").tag("both")
                            Text("Only NotchDock").tag("notchdock")
                            Text("Only macOS").tag("macos")
                        }
                        .pickerStyle(.segmented)

                        Text(indicatorModeDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(ink.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)

                        if indicatorMode == "notchdock" && !AXIsProcessTrusted() {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Accessibility permission is required to hide the macOS overlay.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(ink.opacity(0.85))
                                    Spacer()
                                    Button("Grant Access") {
                                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                                        _ = AXIsProcessTrustedWithOptions(options)
                                        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
                                    }
                                    .buttonStyle(ChipButton())
                                }
                                Text("Tip: In System Settings → Privacy & Security → Accessibility, toggle NotchDock off and on (or remove and re-add it) after updating.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(ink.opacity(0.6))
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }

                        Divider().opacity(0.15)

                        Toggle(isOn: $capsLockHUDEnabled) {
                            Label("Show Caps Lock indicator in notch", systemImage: "capslock")
                        }
                        .toggleStyle(.switch)
                    }
                }
                settingsSection("Appearance") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Theme", systemImage: "circle.lefthalf.filled")
                        HStack(spacing: 8) {
                            themeButton("Black", value: "black")
                            themeButton("White", value: "white")
                        }
                    }
                }
            }
            .padding(26)
        }
    }

    private var integrationsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader("Integrations", subtitle: "Connect the services you want to control from the notch.")
                settingsSection("Music") {
                    integrationRow(
                        title: "Spotify",
                        detail: spotifyConnected ? "Ready to open from NotchDock" : "Open Spotify and finish sign-in there",
                        symbol: "music.note",
                        connected: spotifyConnected,
                        actionTitle: spotifyConnected ? "Disconnect" : "Connect"
                    ) {
                        if spotifyConnected {
                            spotifyConnected = false
                        } else {
                            let appURL = URL(string: "spotify:")!
                            let webURL = URL(string: "https://open.spotify.com")!
                            if !NSWorkspace.shared.open(appURL) { NSWorkspace.shared.open(webURL) }
                            spotifyConnected = true
                        }
                    }
                    if spotifyConnected {
                        Text("Spotify was opened. Finish signing in in the Spotify app if needed.").font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
                    }
                    spotifyPermissionGuide
                    Text("When Spotify is connected, the Music tab sends play, pause, previous, and next commands to Spotify. Apple Music remains available when Spotify is disconnected.")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.48))
                }
                settingsSection("Available now") {
                    integrationRow(title: "Apple Music", detail: "Playback controls are ready", symbol: "applelogo", connected: true, actionTitle: "Ready") {}
                }
            }
            .padding(26)
        }
    }

    private var shortcutsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader("Shortcuts", subtitle: "Quick ways to reach NotchDock.")
                settingsSection("Menu bar") {
                    shortcutRow("Open NotchDock", keys: "Menu bar icon")
                    shortcutRow("Open Settings", keys: "⌘ ,")
                }
                settingsSection("Coming next") {
                    Text("Custom keyboard shortcuts and per-feature visibility controls will appear here as those integrations are enabled.")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.52))
                }
            }
            .padding(26)
        }
    }

    private var indicatorModeDescription: String {
        switch indicatorMode {
        case "notchdock":
            return "Displays volume and brightness changes exclusively in NotchDock, hiding the stock macOS overlay."
        case "macos":
            return "Displays volume and brightness changes using only the stock macOS overlay. NotchDock indicators are turned off."
        default:
            return "Displays both the native macOS overlay and the NotchDock notch indicator simultaneously."
        }
    }

    private func settingsHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(ink.opacity(0.5))
        }
    }

    private var updateBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: updater.updateAvailable ? "arrow.down.circle.fill" : "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 36, height: 36)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(updater.updateAvailable ? "New NotchDock update" : "NotchDock")
                        .font(.system(size: 12, weight: .semibold))
                    Text("v\(updater.currentVersion)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(ink.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ink.opacity(0.08), in: Capsule())
                }
                Text(updater.errorText ?? updater.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(ink.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(updater.updateButtonTitle) {
                if updater.updateAvailable { updater.installLatest() } else { updater.checkForUpdates() }
            }
            .buttonStyle(UpdateButtonStyle())
            .disabled(updater.isChecking || updater.isInstalling)
        }
        .padding(12)
        .background(Color.blue.opacity(isLightTheme ? 0.09 : 0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var spotifyPermissionGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.blue)
                Text("Allow Spotify control")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Button("Open Settings") { NotchModel.openMusicAutomationSettings() }
                    .buttonStyle(ChipButton())
            }
            Text("For playback controls to work, allow NotchDock to control Spotify in System Settings → Privacy & Security → Automation. Turn on Spotify under NotchDock, then try the play button again.")
                .font(.system(size: 11))
                .foregroundStyle(ink.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.blue.opacity(isLightTheme ? 0.08 : 0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.blue.opacity(0.2), lineWidth: 1))
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(ink.opacity(0.45))
            content().padding(15).frame(maxWidth: .infinity, alignment: .leading).background(ink.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func integrationRow(title: String, detail: String, symbol: String, connected: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 38, height: 38).background(ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(ink.opacity(0.48))
            }
            Spacer()
            Button(actionTitle, action: action).buttonStyle(AccentButton())
        }
    }

    private func shortcutRow(_ title: String, keys: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(ink.opacity(0.52)).padding(.horizontal, 9).padding(.vertical, 5).background(ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func themeButton(_ title: String, value: String) -> some View {
        Button {
            themeName = value
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(themeName == value ? (isLightTheme ? .white : .black) : ink.opacity(0.72))
                .background(themeName == value ? (isLightTheme ? Color.black : Color.white) : ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

private struct UpdateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.blue.opacity(configuration.isPressed ? 0.72 : 0.95), in: Capsule())
    }
}
