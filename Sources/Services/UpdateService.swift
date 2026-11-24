import AppKit

/// "Is there a newer Pixlok?" — asks GitHub for the latest published release and compares its
/// version with ours. It only notifies (release page / Homebrew command); it never downloads or
/// installs anything. Automatic checks run at most once a day and can be turned off in Settings.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService(settings: .shared)

    static let releasesAPI = URL(string: "https://api.github.com/repos/SriharshaShesham/Pixlok/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/SriharshaShesham/Pixlok/releases/latest")!
    static let brewCommand = "brew upgrade --cask SriharshaShesham/tap/pixlok"
    private static let automaticInterval: TimeInterval = 24 * 60 * 60

    struct Release: Equatable {
        let version: String
        let name: String
        let notes: String
        let page: URL
    }

    enum CheckError: LocalizedError {
        case badResponse(Int)
        case unreadable
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "GitHub answered with status \(code)."
            case .unreadable: return "GitHub’s answer couldn’t be read."
            }
        }
    }

    private let settings: AppSettings
    @Published private(set) var isChecking = false

    init(settings: AppSettings) { self.settings = settings }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Entry points

    /// At launch: checks quietly if enabled and the last check was a day ago or more; shows an
    /// alert only when a newer, not-skipped version exists.
    func checkAutomaticallyIfDue() {
        guard settings.checkForUpdates else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < Self.automaticInterval { return }
        Task { await check(userInitiated: false) }
    }

    /// Pixlok ▸ Check for Updates… / Settings "Check Now": always reports the outcome.
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await Self.fetchLatest()
            settings.lastUpdateCheck = Date()
            let newer = Self.isVersion(release.version, newerThan: Self.currentVersion)
            if newer && (userInitiated || release.version != settings.skippedUpdateVersion) {
                presentAvailable(release, userInitiated: userInitiated)
            } else if userInitiated {
                presentUpToDate()
            }
        } catch {
            // Automatic checks fail silently (offline, rate-limited, …) and retry next launch.
            if userInitiated { presentFailure(error) }
        }
    }

    // MARK: - Network

    static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pixlok/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CheckError.badResponse(status) }
        guard let release = parseRelease(data) else { throw CheckError.unreadable }
        return release
    }

    /// Parses GitHub's "latest release" JSON (drafts and pre-releases are never returned there).
    static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty, version.first?.isNumber == true else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return Release(version: version,
                       name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Pixlok \(version)",
                       notes: json["body"] as? String ?? "",
                       page: page)
    }

    /// Numeric dotted comparison: 1.10.0 > 1.9.2, 1.2 == 1.2.0. Non-numeric suffixes are ignored.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Installed through the Homebrew tap (the cask's Caskroom entry exists).
    static var isHomebrewInstall: Bool {
        ["/opt/homebrew/Caskroom/pixlok", "/usr/local/Caskroom/pixlok"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Alerts

    private func presentAvailable(_ release: Release, userInitiated: Bool) {
        let alert = NSAlert()
        alert.messageText = "\(release.name) is available"
        var info = "You have Pixlok \(Self.currentVersion)."
        if Self.isHomebrewInstall {
            info += " To update with Homebrew, run:\n\(Self.brewCommand)"
        }
        alert.informativeText = info
        alert.accessoryView = notesView(release.notes)
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if !userInitiated { alert.addButton(withTitle: "Skip This Version") }
        if Self.isHomebrewInstall { alert.addButton(withTitle: "Copy Homebrew Command") }
        NSApp.activate()
        let response = alert.runModal()
        let title = alert.buttons[response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue].title
        switch title {
        case "Download":
            NSWorkspace.shared.open(release.page)
        case "Skip This Version":
            settings.skippedUpdateVersion = release.version
        case "Copy Homebrew Command":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.brewCommand, forType: .string)
        default:
            break
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "Pixlok is up to date"
        alert.informativeText = "Version \(Self.currentVersion) is the latest release."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t check for updates"
        alert.informativeText = "\(error.localizedDescription)\n\nYou can see the latest release on GitHub."
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesPage) }
    }

    /// Scrollable, read-only release notes (GitHub Markdown, lightly tidied).
    private func notesView(_ markdown: String) -> NSView? {
        let text = Self.plainNotes(markdown)
        guard !text.isEmpty else { return nil }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 170))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.autoresizingMask = [.width]
        view.font = .systemFont(ofSize: 11.5)
        view.textColor = .labelColor
        view.string = text
        scroll.documentView = view
        return scroll
    }

    /// Strips the Markdown markers that read badly as plain text (#, **, `).
    static func plainNotes(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = String(line)
                while l.hasPrefix("#") { l.removeFirst() }
                if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "•" + l.dropFirst(1) }
                return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
