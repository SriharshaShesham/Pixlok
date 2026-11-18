import AppKit
import UniformTypeIdentifiers

/// "Edit in" support: discovering external apps and opening files in them.
enum EditorService {

    // MARK: - Discovery

    /// Apps that can open `url`, best match first, excluding Pixlok itself, without duplicates.
    static func installedApps(for url: URL) -> [URL] {
        filtered(NSWorkspace.shared.urlsForApplications(toOpen: url))
    }

    /// Apps that can open any image (used by Settings › "Add from installed apps…").
    static func installedImageApps() -> [URL] {
        filtered(NSWorkspace.shared.urlsForApplications(toOpen: UTType.image))
    }

    /// Removes this app and duplicates (same standardized path or same bundle identifier).
    private static func filtered(_ urls: [URL]) -> [URL] {
        let selfPath = Bundle.main.bundleURL.standardizedFileURL.path
        let selfID = Bundle.main.bundleIdentifier
        var seenPaths = Set<String>()
        var seenIDs = Set<String>()
        var result: [URL] = []
        for app in urls {
            let path = app.standardizedFileURL.path
            if path == selfPath { continue }
            let bid = Bundle(url: app)?.bundleIdentifier
            if let bid, let selfID, bid == selfID { continue }
            if seenPaths.contains(path) { continue }
            if let bid, seenIDs.contains(bid) { continue }
            seenPaths.insert(path)
            if let bid { seenIDs.insert(bid) }
            result.append(app)
        }
        return result
    }

    // MARK: - Opening

    /// Opens `file` in the app at `app`. Shows an alert if that fails.
    static func open(_ file: URL, with app: URL) {
        guard FileManager.default.fileExists(atPath: app.path) else {
            showError(title: "Can’t open “\(file.lastPathComponent)”",
                      message: "\(appName(app)) could not be found. It may have been moved or deleted. You can change the “Edit in” apps in Settings.")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                showError(title: "Can’t open “\(file.lastPathComponent)” in \(appName(app))",
                          message: error.localizedDescription)
            }
        }
    }

    private static func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - First-run seeding

    private static let gimpBundleIDs = ["org.gimp.gimp-3.0", "org.gimp.gimp-3", "org.gimp.gimp-2.10", "org.gimp.gimp"]

    /// Locates an installed GIMP, if any.
    static func findGIMP() -> URL? {
        for id in gimpBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let fm = FileManager.default
        let dirs = [URL(fileURLWithPath: "/Applications"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            let hits = items
                .filter { $0.pathExtension == "app" && $0.lastPathComponent.lowercased().hasPrefix("gimp") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            if let first = hits.first { return first }
        }
        return nil
    }

    /// On first run, adds GIMP (as default, if installed) and Preview to the "Edit in" list.
    @MainActor
    static func seedDefaultEditorsIfNeeded(settings: AppSettings) {
        guard !settings.didSeedEditors else { return }
        var list = settings.editors
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !list.contains(where: { $0.path == path }) else { return }
            list.append(EditorApp(path: path, name: appName(url)))
        }
        let gimp = findGIMP()
        if let gimp { add(gimp) }
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            add(preview)
        }
        settings.editors = list
        if let gimp {
            settings.defaultEditorPath = gimp.standardizedFileURL.path
        }
        settings.didSeedEditors = true
    }

    // MARK: - Helpers

    /// Display name of an app bundle ("GIMP", "Preview").
    static func appName(_ appURL: URL) -> String {
        if let bundle = Bundle(url: appURL) {
            if let n = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String, !n.isEmpty { return n }
            if let n = bundle.infoDictionary?["CFBundleDisplayName"] as? String, !n.isEmpty { return n }
        }
        let display = FileManager.default.displayName(atPath: appURL.path)
        if display.lowercased().hasSuffix(".app") { return String(display.dropLast(4)) }
        if !display.isEmpty { return display }
        return appURL.deletingPathExtension().lastPathComponent
    }

    static func icon(_ appURL: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: appURL.path)
    }

    /// Lets the user pick any application bundle. Returns nil if cancelled.
    @MainActor
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to edit images with"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}
