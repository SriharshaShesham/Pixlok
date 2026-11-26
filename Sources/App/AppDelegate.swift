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
        // We add our own "Enter Full Screen" item. Window tabbing stays on: viewer windows can be
        // tabbed (File ▸ New Tab; the system adds Show Tab Bar / Merge All Windows to Window).
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build(delegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditorService.seedDefaultEditorsIfNeeded(settings: settings)
        NSApp.activate()
        if runDebugOpenEditIfRequested() || runDebugViewIfRequested() { return }
        // Quiet daily update check, after launch has settled (debug/QA runs above never check).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { UpdateService.shared.checkAutomaticallyIfDue() }
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
            Self.writeDebugSnapshotIfRequested(after: 3.0) { [weak self] in self?.frontmostViewer() }
        }
        return true
    }

    /// `--debug-snapshot <out.png>`: render the front viewer window to a PNG after things settle,
    /// then exit immediately (nothing is saved; skips the unsaved-edits quit alert).
    private static func writeDebugSnapshotIfRequested(after delay: TimeInterval,
                                                      viewer: @escaping () -> ViewerWindowController?) {
        let args = CommandLine.arguments
        guard let s = args.firstIndex(of: "--debug-snapshot"), s + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[s + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let window = viewer()?.window
            guard let view = window?.contentView?.superview ?? window?.contentView,
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

    /// Debug/QA hook: `Pixlok --debug-view <file> [actions]` opens the file, then runs the
    /// comma-separated viewer actions one by one (zoomIn, zoomOut, actualSize, fit, rotateLeft,
    /// rotateRight, next, previous, newTab, newWindow), so view states can be screenshotted without UI scripting.
    /// Nothing is saved.
    private func runDebugViewIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--debug-view"), i + 1 < args.count else { return false }
        handledLaunchOpen = true
        openFiles([URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)])
        let actions = (i + 2 < args.count ? args[i + 2] : "").split(separator: ",").map(String.init)
        for (n, action) in actions.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + 0.4 * Double(n)) { [weak self] in
                guard let viewer = self?.frontmostViewer() else { return }
                switch action {
                case "zoomIn": viewer.pixlokZoomIn(nil)
                case "zoomOut": viewer.pixlokZoomOut(nil)
                case "actualSize": viewer.pixlokActualSize(nil)
                case "fit": viewer.pixlokZoomToFit(nil)
                case "rotateLeft": viewer.pixlokRotateLeft(nil)
                case "rotateRight": viewer.pixlokRotateRight(nil)
                case "next": viewer.browser?.next()
                case "previous": viewer.browser?.previous()
                case "newTab": self?.perform(.newTab, from: viewer)
                case "newWindow": self?.perform(.newWindow, from: viewer)
                default: FileHandle.standardError.write(Data("debug-view: unknown action \(action)\n".utf8))
                }
            }
        }
        Self.writeDebugSnapshotIfRequested(after: 2.0 + 0.4 * Double(actions.count)) { [weak self] in
            self?.frontmostViewer()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledLaunchOpen = true
        // Finder and the Dock may deliver one multi-file open as several back-to-back calls
        // (e.g. one per folder). Handled one by one, each would replace the front window's
        // content, so gather calls that arrive together and open them as one batch.
        pendingOpenURLs += urls
        pendingOpenFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pendingOpenURLs
            self.pendingOpenURLs = []
            self.pendingOpenFlush = nil
            self.openFiles(batch)
        }
        pendingOpenFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openBatchWindow, execute: flush)
    }

    /// How long to wait for more `application(_:open:)` calls belonging to the same open.
    private static let openBatchWindow: TimeInterval = 0.15
    private var pendingOpenURLs: [URL] = []
    private var pendingOpenFlush: DispatchWorkItem?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controllers.contains(where: { $0.isSavingEdits }) {
            NSSound.beep()
            return .terminateCancel
        }
        let dirty = controllers.filter { $0.hasUnsavedEdits }
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit and discard unsaved edits?"
        let names = dirty.compactMap { $0.editedFileName }.map { "“\($0)”" }
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

    /// Window policy, per folder in the batch (only its first file is shown; the rest are
    /// reachable with ← →):
    /// - a window already showing that folder shows the file;
    /// - otherwise the folder goes where Settings ▸ "Open other folders" says: a new window
    ///   (default), a new tab of the frontmost viewer, or — for the first such folder — the
    ///   frontmost viewer itself (like Windows Photo Viewer). An empty viewer is always reused.
    ///
    /// With an explicit `destination` the first folder goes there (this window, a new window or a
    /// new tab) and every further folder gets a new window (or tab, for `.newTab`).
    func openFiles(_ urls: [URL], destination: OpenDestination? = nil) {
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !files.isEmpty else { return }
        if let destination {
            openFiles(files, at: destination)
            return
        }

        // One entry per folder, in the order given.
        var seenFolders: Set<String> = []
        let perFolder = files.compactMap { url -> (folder: String, url: URL)? in
            let folder = Self.folderPath(of: url)
            return seenFolders.insert(folder).inserted ? (folder, url) : nil
        }

        // Pass 1: folders already open in a window stay in that window.
        var targets = [ViewerWindowController?](repeating: nil, count: perFolder.count)
        var used: [ViewerWindowController] = []
        for (i, entry) in perFolder.enumerated() {
            if let existing = viewer(showingFolder: entry.folder, excluding: used) {
                targets[i] = existing
                used.append(existing)
            }
        }
        // Pass 2: the first remaining folder may take over the frontmost viewer (if it wasn't just
        // claimed): always when that window is empty, otherwise only with the "current window"
        // setting (like Windows Photo Viewer). The others get new windows or tabs, per Settings.
        let placement = settings.otherFolderPlacement
        let front = frontmostViewer()
        if let i = targets.firstIndex(where: { $0 == nil }),
           let front, !used.contains(where: { $0 === front }),
           placement == .currentWindow || front.browser == nil {
            targets[i] = front
            used.append(front)
        }

        var previous = front
        for (i, entry) in perFolder.enumerated() {
            let target: ViewerWindowController
            if let t = targets[i] {
                target = t
            } else {
                target = placement == .newTab && previous != nil
                    ? makeTab(beside: previous)
                    : makeController(cascadingFrom: previous?.window)
                targets[i] = target
            }
            target.show(entry.url)
            target.showWindow(nil)
            previous = target
        }
        hasShownViewer = true
        targets.first??.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Where an explicit open (top bar button, File ▸ New Tab …) puts the first folder.
    enum OpenDestination {
        case window(ViewerWindowController)
        case newWindow
        case newTab(beside: ViewerWindowController?)
    }

    private func openFiles(_ files: [URL], at destination: OpenDestination) {
        var seenFolders: Set<String> = []
        let firstPerFolder = files.filter { seenFolders.insert(Self.folderPath(of: $0)).inserted }
        var previous = frontmostViewer()
        var first: ViewerWindowController?
        for (i, url) in firstPerFolder.enumerated() {
            let target: ViewerWindowController
            switch destination {
            case .window(let c) where i == 0:
                target = c
            case .newTab(let beside):
                target = makeTab(beside: beside ?? previous)
            default:
                target = makeController(cascadingFrom: previous?.window)
            }
            target.show(url)
            target.showWindow(nil)
            previous = target
            if first == nil { first = target }
        }
        hasShownViewer = true
        first?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// A new empty viewer added as a tab of `beside`'s window (a plain new window if there is none).
    private func makeTab(beside: ViewerWindowController?) -> ViewerWindowController {
        let c = makeController(cascadingFrom: beside?.window)
        if let host = beside?.window, let tab = c.window {
            host.addTabbedWindow(tab, ordered: .above)
        }
        return c
    }

    /// A viewer window whose current folder is `folder`, frontmost first.
    private func viewer(showingFolder folder: String, excluding used: [ViewerWindowController]) -> ViewerWindowController? {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? ViewerWindowController }
        let candidates = ordered + controllers.filter { c in !ordered.contains { $0 === c } }
        return candidates.first { c in
            // A window in edit mode isn't reused (that would interrupt the edit); the file goes
            // to the frontmost viewer or a new window instead.
            !used.contains { $0 === c } && !c.isEditing
                && c.browser?.folder.standardizedFileURL.path == folder
        }
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
        c.onRequestOpenAction = { [weak self] viewer, action in self?.perform(action, from: viewer) }
        c.onRequestSettings = { [weak self] in self?.showSettings(nil) }
        controllers.append(c)
        return c
    }

    private func makeOpenPanel(foldersOnly: Bool = false) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = foldersOnly ? "Open Folder" : "Open"
        panel.message = foldersOnly ? "Choose a folder to browse"
            : "Choose an image, video, STL model, PDF or folder"
        panel.canChooseFiles = !foldersOnly
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

    func showOpenPanel(foldersOnly: Bool = false, destination: OpenDestination? = nil) {
        let panel = makeOpenPanel(foldersOnly: foldersOnly)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                // The target window may have closed while the panel was up.
                var destination = destination
                if case .window(let c)? = destination, c.window?.isVisible != true { destination = nil }
                self?.openFiles(panel.urls, destination: destination)
            }
        }
    }

    /// Top bar "Open ▾" button / empty state actions for `viewer`.
    func perform(_ action: ViewerOpenAction, from viewer: ViewerWindowController?) {
        switch action {
        case .openHere:
            showOpenPanel(destination: viewer.map { .window($0) })
        case .openFolderHere:
            showOpenPanel(foldersOnly: true, destination: viewer.map { .window($0) })
        case .openInNewWindow:
            showOpenPanel(destination: .newWindow)
        case .openInNewTab:
            showOpenPanel(destination: .newTab(beside: viewer))
        case .newWindow:
            let c = makeController(cascadingFrom: viewer?.window ?? frontmostViewer()?.window)
            c.showWindow(nil)
            hasShownViewer = true
        case .newTab:
            let c = makeTab(beside: viewer ?? frontmostViewer())
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
            hasShownViewer = true
        }
    }

    // MARK: - Menu actions

    /// ⌘O: like the top bar's Open button, the choice is shown in the active window.
    @objc func openDocument(_ sender: Any?) { perform(.openHere, from: activeViewer) }
    @objc func openFolder(_ sender: Any?) { perform(.openFolderHere, from: activeViewer) }
    @objc func newViewerWindow(_ sender: Any?) { perform(.newWindow, from: activeViewer) }
    @objc func newViewerTab(_ sender: Any?) { perform(.newTab, from: activeViewer) }
    /// The system's "+" in the tab bar.
    @objc func newWindowForTab(_ sender: Any?) { perform(.newTab, from: activeViewer) }

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

    @objc func checkForUpdates(_ sender: Any?) { UpdateService.shared.checkNow() }

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
        ⌘O   Open file or folder      ⌘⇧O   Open folder
        ⌘N   New window      ⌘T   New tab
        ⌘F   Search a PDF (⌘G next)      ⌘P   Print a PDF
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
        PDF edit (E): ⌘Z undo · Delete removes the selection · arrows nudge · Esc steps back
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
