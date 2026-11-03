import AppKit
import Combine
import Foundation

@MainActor
final class NotchUpdater: ObservableObject {
    struct ReleaseAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    struct Release: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let assets: [ReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case assets
        }
    }

    @Published private(set) var latestVersion: String?
    @Published private(set) var statusText = "Check for updates"
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var errorText: String?

    private let releaseAPI = URL(string: "https://api.github.com/repos/aaravbasketball-del/NotchDock/releases/latest")!
    private var release: Release?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return compareVersions(latestVersion, currentVersion) == .orderedDescending
    }

    var updateButtonTitle: String {
        if isInstalling { return "Installing…" }
        if updateAvailable, let latestVersion { return "Update \(latestVersion)" }
        return isChecking ? "Checking…" : "Check for updates"
    }

    func checkForUpdates() {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        errorText = nil
        statusText = "Checking GitHub…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isChecking = false }

            do {
                var request = URLRequest(url: releaseAPI)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("NotchDock/1.2.3", forHTTPHeaderField: "User-Agent")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    release = nil
                    latestVersion = nil
                    statusText = "No public release yet"
                    return
                }
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    throw URLError(.badServerResponse)
                }

                let decoded = try JSONDecoder().decode(Release.self, from: data)
                release = decoded
                latestVersion = normalizedVersion(decoded.tagName)
                statusText = updateAvailable ? "A new NotchDock update is ready" : "You’re up to date"
            } catch {
                errorText = "Couldn’t check for updates"
                statusText = "Try again later"
            }
        }
    }

    func installLatest() {
        guard updateAvailable, !isInstalling, let release else { return }
        guard let zipAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else {
            if let dmgAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
                NSWorkspace.shared.open(dmgAsset.browserDownloadURL)
                statusText = "The update download is open"
            } else {
                errorText = "This release has no installer"
            }
            return
        }

        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            errorText = "Move NotchDock to Applications before updating"
            statusText = "Install from Applications first"
            return
        }

        isInstalling = true
        errorText = nil
        statusText = "Downloading update…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (downloadURL, _) = try await URLSession.shared.download(from: zipAsset.browserDownloadURL)
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NotchDock-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let zipURL = root.appendingPathComponent(zipAsset.name)
                try FileManager.default.moveItem(at: downloadURL, to: zipURL)

                let extractProcess = Process()
                extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                extractProcess.arguments = ["-x", "-k", zipURL.path, root.path]
                try extractProcess.run()
                extractProcess.waitUntilExit()
                guard extractProcess.terminationStatus == 0 else { throw URLError(.cannotDecodeContentData) }

                let newApp = root.appendingPathComponent("NotchDock.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else { throw URLError(.fileDoesNotExist) }
                let version = normalizedVersion(release.tagName)
                let message = cleanReleaseDescription(release.body, version: version)
                UserDefaults.standard.set(version, forKey: "notchdock.pendingUpdateVersion")
                UserDefaults.standard.set(message, forKey: "notchdock.pendingUpdateMessage")
                try launchReplacementHelper(root: root, newApp: newApp, currentApp: Bundle.main.bundleURL)
                statusText = "Installing… NotchDock will reopen"
                try await Task.sleep(for: .milliseconds(400))
                NSApp.terminate(nil)
            } catch {
                isInstalling = false
                errorText = "The update could not be installed"
                statusText = "Try again later"
            }
        }
    }

    private func launchReplacementHelper(root: URL, newApp: URL, currentApp: URL) throws {
        let backup = root.appendingPathComponent("NotchDock-previous.app")
        let scriptURL = root.appendingPathComponent("install-update.sh")
        let script = """
        #!/bin/sh
        set -u
        sleep 1
        rm -rf \(shellQuote(backup.path))
        mv \(shellQuote(currentApp.path)) \(shellQuote(backup.path))
        if /usr/bin/ditto \(shellQuote(newApp.path)) \(shellQuote(currentApp.path)); then
            /usr/bin/xattr -cr \(shellQuote(currentApp.path)) 2>/dev/null || true
            rm -rf \(shellQuote(backup.path))
            /usr/bin/open \(shellQuote(currentApp.path))
        else
            mv \(shellQuote(backup.path)) \(shellQuote(currentApp.path))
        fi
        rm -rf \(shellQuote(root.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["755", scriptURL.path]
        try chmod.run()
        chmod.waitUntilExit()

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [scriptURL.path]
        try helper.run()
    }

    private func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^v", with: "", options: .regularExpression)
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = normalizedVersion(lhs).split(separator: ".").map { Int($0) ?? 0 }
        let right = normalizedVersion(rhs).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func cleanReleaseDescription(_ raw: String?, version: String = "") -> String {
        var newFeatures: [String] = []
        var fixes: [String] = []
        var otherItems: [String] = []

        if let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let lines = raw.components(separatedBy: .newlines)
            var currentCategory = ""

            for line in lines {
                var item = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if item.isEmpty { continue }

                let lower = item.lowercased()
                if lower.contains("what's new") || lower.contains("features") || lower.contains("new features") {
                    currentCategory = "new"
                    continue
                } else if lower.contains("fix") || lower.contains("bug") || lower.contains("resolved") || lower.contains("improvements") {
                    currentCategory = "fixed"
                    continue
                }

                if item.hasPrefix("#") { continue }
                if lower.contains("full changelog") || item.contains("/compare/") { continue }
                if item.hasPrefix("http://") || item.hasPrefix("https://") { continue }

                if let byRange = item.range(of: " by @", options: .backwards) {
                    item = String(item[..<byRange.lowerBound])
                }
                item = item.replacingOccurrences(of: "^[*\\-•]\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                item = item.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !item.isEmpty else { continue }

                let itemLower = item.lowercased()
                if currentCategory == "new" || itemLower.hasPrefix("add") || itemLower.contains("feature") || itemLower.contains("new ") || itemLower.contains("support") || itemLower.contains("badge") || itemLower.contains("version") {
                    newFeatures.append(item)
                } else if currentCategory == "fixed" || itemLower.hasPrefix("fix") || itemLower.contains("bug") || itemLower.contains("eliminate") || itemLower.contains("restore") || itemLower.contains("remove") || itemLower.contains("box") || itemLower.contains("freeze") || itemLower.contains("artifact") {
                    fixes.append(item)
                } else {
                    otherItems.append(item)
                }
            }
        }

        if newFeatures.isEmpty && fixes.isEmpty && otherItems.isEmpty {
            return Self.defaultReleaseNotes(for: version)
        }

        var result: [String] = []
        if !newFeatures.isEmpty {
            result.append("WHAT'S NEW")
            result.append(contentsOf: newFeatures.map { "• " + $0 })
        }
        if !fixes.isEmpty {
            if !result.isEmpty { result.append("") }
            result.append("WHAT'S FIXED")
            result.append(contentsOf: fixes.map { "• " + $0 })
        }
        if !otherItems.isEmpty && (newFeatures.isEmpty || fixes.isEmpty) {
            if !result.isEmpty { result.append("") }
            result.append("IMPROVEMENTS")
            result.append(contentsOf: otherItems.map { "• " + $0 })
        }

        return result.isEmpty ? NotchUpdater.defaultReleaseNotes(for: version) : result.joined(separator: "\n")
    }

    static func defaultReleaseNotes(for version: String = "") -> String {
        """
        WHAT'S NEW
        • App Version in Settings: Current version is now displayed directly in the Settings update card.
        • Two-Way Apple Notes Sync: Type quick notes in the notch to auto-save to Apple Notes, with click-to-open feed.
        • Fake Notch & Dynamic Island: Simulate a MacBook notch or floating Dynamic Island pill with customizable dimensions.
        • Small Trigger Bump: Subtle tactile hover target for external displays.

        WHAT'S FIXED
        • Apple Notes Saving & Permissions: Auto-launches Notes.app and eliminates modal freezes when saving notes.
        • Outward Rounded Top Corners: Restored smooth fillets merging directly into the display bezel.
        • Square Shadow Artifact: Eliminated the transparent rectangular box and side shadow clipping.
        """
    }
}
