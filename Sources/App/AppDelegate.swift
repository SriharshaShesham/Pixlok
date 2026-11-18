import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App lifecycle: opens viewer windows for files from Finder / Dock / Open panel,
/// owns the main menu and the single Settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private var controllers: [ViewerWindowController] = []
    private var settingsWindow: NSWindow?
    /// Set once something was opened (or the launch panel ran), so launch doesn't show a second panel.
    private var handledLaunchOpen = false
    /// The app quits when its last window closes, but only after a viewer has been shown
    /// (closing the launch Open panel must not quit).
    private var hasShownViewer = false

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // We add our own "Enter Full Screen" item; no tabs in a viewer.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build(delegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditorService.seedDefaultEditorsIfNeeded(settings: settings)
        NSApp.activate()
        if runDebugOpenEditIfRequested() { return }
        // Files passed at launch arrive via application(_:open:) around now; give them a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.handledLaunchOpen, self.controllers.isEmpty else { return }
            self.handledLaunchOpen = true
            self.runLaunchOpenPanel()
        }
    }

    /// Debug/QA hook: `Pixlok --debug-open-edit <file> [recipe-json] [--crop]` opens the file
    /// and enters edit mode (optionally with a recipe applied and the crop tool active), so the
    /// edit UI can be screenshotted without UI scripting. Nothing is saved.
    private func runDebugOpenEditIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--debug-open-edit"), i + 1 < args.count else { return false }
        handledLaunchOpen = true
        let url = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        let json = (i + 2 < args.count && !args[i + 2].hasPrefix("--")) ? args[i + 2] : nil
        let crop = args.contains("--crop")
        openFiles([url])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let viewer = self?.frontmostViewer() else { return }
            viewer.editBegin()
            guard let session = viewer.editSession else { return }
            if let json, let recipe = try? SaveSelfTest.recipe(fromJSON: json) { session.recipe = recipe }
            if crop {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { session.beginCrop() }
            }
            // `--debug-snapshot <out.png>`: render just this window to a PNG after things settle,
            // then exit immediately (nothing is saved; skips the unsaved-edits quit alert).
            if let s = args.firstIndex(of: "--debug-snapshot"), s + 1 < args.count {
                let out = URL(fileURLWithPath: args[s + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak viewer] in
                    guard let view = viewer?.window?.contentView?.superview ?? viewer?.window?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    do {
                        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
                        try png.write(to: out)
                    } catch {
                        exit(1)
                    }
                    exit(0)
                }
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledLaunchOpen = true
        openFiles(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controllers.contains(where: { $0.editSession?.isSaving == true }) {
            NSSound.beep()
            return .terminateCancel
        }
        let dirty = controllers.filter { $0.editSession?.isDirty == true }
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit and discard unsaved edits?"
        let names = dirty.compactMap { $0.editSession?.url.lastPathComponent }.map { "“\($0)”" }
        alert.informativeText = "Edits to \(names.joined(separator: ", ")) haven’t been saved."
        alert.addButton(withTitle: "Discard and Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        dirty.forEach { $0.endEditing() }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        hasShownViewer
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && controllers.isEmpty { showOpenPanel() }
        return true
    }

    private func runLaunchOpenPanel() {
        let panel = makeOpenPanel()
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            openFiles(panel.urls)
        }
        if controllers.isEmpty {
            // Cancelled: keep running with an empty "Open a file or drop one here" window.
            let c = makeController(cascadingFrom: nil)
            c.showWindow(nil)
            hasShownViewer = true
        }
    }

    // MARK: - Opening files

    /// Window policy: the first file goes to the frontmost viewer window (replacing its
    /// content, like Windows Photo Viewer); files from other folders get their own windows.
    func openFiles(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard let first = files.first else { return }
        var shownFolders: Set<String> = []

        let target = frontmostViewer() ?? makeController(cascadingFrom: nil)
        target.show(first)
        target.showWindow(nil)
        shownFolders.insert(Self.folderPath(of: first))

        var previous = target.window
        for url in files.dropFirst() {
            let folder = Self.folderPath(of: url)
            guard !shownFolders.contains(folder) else { continue }   // reachable with ← →
            shownFolders.insert(folder)
            let c = makeController(cascadingFrom: previous)
            c.show(url)
            c.showWindow(nil)
            previous = c.window
        }
        hasShownViewer = true
        target.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func folderPath(of url: URL) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url.path }
        return url.deletingLastPathComponent().path
    }

    private func frontmostViewer() -> ViewerWindowController? {
        for window in NSApp.orderedWindows {
            if let c = window.windowController as? ViewerWindowController, window.isVisible { return c }
        }
        return controllers.last
    }

    /// The viewer that menu commands apply to.
    private var activeViewer: ViewerWindowController? {
        (NSApp.keyWindow?.windowController as? ViewerWindowController)
            ?? (NSApp.mainWindow?.windowController as? ViewerWindowController)
    }

    private func makeController(cascadingFrom reference: NSWindow?) -> ViewerWindowController {
        let c = ViewerWindowController(settings: settings)
        let ref = reference ?? controllers.last?.window
        c.placeWindow(cascadingFrom: ref)
        c.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        c.onRequestOpenPanel = { [weak self] in self?.showOpenPanel() }
        c.onRequestSettings = { [weak self] in self?.showSettings(nil) }
        controllers.append(c)
        return c
    }

    private func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.message = "Choose an image, video, STL model or folder"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.folder]
        for format in FormatRegistry.all {
            types += format.utTypes.compactMap { UTType($0) }
            types += format.extensions.compactMap { UTType(filenameExtension: $0) }
        }
        var seen = Set<String>()
        panel.allowedContentTypes = types.filter { seen.insert($0.identifier).inserted }
        return panel
    }

    func showOpenPanel() {
        let panel = makeOpenPanel()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.openFiles(panel.urls)
            }
        }
    }

    // MARK: - Menu actions

    @objc func openDocument(_ sender: Any?) { showOpenPanel() }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings).preferredColorScheme(.dark))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.center()
            window.setFrameAutosaveName("PixlokSettings")
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Pixlok",
            .applicationVersion: version,
            .version: build,
        ])
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        ← →   Previous / next file
        Home / End   First / last file
        Space   Next image (play/pause for videos)
        ⌘+  ⌘−   Zoom in / out
        ⌘0   Actual size      ⌘9   Zoom to fit
        ⌘L  ⌘R   Rotate left / right
        F5 or ⌘⇧S   Slideshow (Esc to stop)
        ⌘I   File info
        E or ⌘⇧E   Edit image (brightness, exposure, crop…)
            ⌘S Save · Esc Cancel · hold \\ to compare · Return applies crop
        ⌘E   Edit in default editor
        Delete or ⌘⌫   Move to Trash
        ⌃⌘F   Full screen
        """
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - NSMenuDelegate (dynamic File menu items)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "File" {
            if let edit = menu.item(withTag: MainMenu.editInTag) {
                if let viewer = activeViewer, viewer.currentURL != nil, !viewer.canTransform {
                    // STL / video: ⌘E opens the first app that can handle the file, not the image editor.
                    edit.title = "Open in Default App"
                } else {
                    edit.title = settings.primaryEditor.map { "Edit in \($0.name)" } ?? "Edit in…"
                }
            }
        } else if menu.title == "Open With" {
            menu.removeAllItems()
            let viewer = activeViewer
            guard let url = viewer?.currentURL else {
                let none = NSMenuItem(title: "No File", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
                return
            }
            let editorPaths = Set(settings.editors.map(\.path))
            for editor in settings.editors {
                menu.addItem(openWithItem(editor.url, name: editor.name, viewer: viewer))
            }
            let others = EditorService.installedApps(for: url)
                .filter { !editorPaths.contains($0.standardizedFileURL.path) }
                .prefix(25)
            if !settings.editors.isEmpty && !others.isEmpty { menu.addItem(.separator()) }
            for app in others {
                menu.addItem(openWithItem(app, name: EditorService.appName(app), viewer: viewer))
            }
            menu.addItem(.separator())
            let choose = NSMenuItem(title: "Choose Application…",
                                    action: #selector(ViewerWindowController.pixlokChooseApplication(_:)), keyEquivalent: "")
            choose.target = viewer
            menu.addItem(choose)
        }
    }

    private func openWithItem(_ app: URL, name: String, viewer: ViewerWindowController?) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: #selector(ViewerWindowController.pixlokOpenWithApp(_:)), keyEquivalent: "")
        item.representedObject = app
        item.target = viewer
        let icon = EditorService.icon(app)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }
}
