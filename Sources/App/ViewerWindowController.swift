import AppKit
import SwiftUI
import Combine

/// One viewer window: owns its FolderBrowser (replaced when a file from another
/// folder is opened here), ViewerState, keyboard handling and slideshow.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, ViewerCommandHandler,
    EditCommandHandler {
    static let autosaveName = "PixlokWindow"

    let settings: AppSettings
    let model = ViewerWindowModel()
    let state = ViewerState()
    let chrome = ViewerChrome()
    /// Called when the window closes so the app delegate can release this controller.
    var onClose: ((ViewerWindowController) -> Void)?
    /// Routed from the empty state's "Open…" and the menu.
    var onRequestOpenPanel: (() -> Void)?
    var onRequestSettings: (() -> Void)?

    private var keyMonitor: Any?
    private var browserSubscriptions = Set<AnyCancellable>()
    private var slideshow: SlideshowController?
    private var lastShownURL: URL?
    /// Key code of the held key showing the "Before" image (the backslash compare hold), nil when not held.
    private var compareKeyCode: UInt16?

    var browser: FolderBrowser? { model.browser }
    var editHost: EditHost { model.editHost }
    /// The edit session, when this window is in edit mode.
    var editSession: EditSession? { model.editHost.session }
    var currentURL: URL? { model.browser?.current }

    init(settings: AppSettings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ViewerPalette.nsBackground
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = "Pixlok"
        super.init(window: window)
        window.delegate = self

        let root = ViewerRootView(model: model, state: state, settings: settings, chrome: chrome, handler: self)
        window.contentView = NSHostingView(rootView: root)

        slideshow = SlideshowController(window: window, state: state, settings: settings, chrome: chrome) { [weak self] in
            guard let browser = self?.model.browser, browser.count > 1 else { return false }
            return browser.step(1)
        }
        installKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Positions a new window: restores the saved frame for the first window,
    /// cascades further windows from `reference`.
    func placeWindow(cascadingFrom reference: NSWindow?) {
        guard let window else { return }
        if let reference {
            let topLeft = NSPoint(x: reference.frame.minX, y: reference.frame.maxY)
            window.setFrame(NSRect(origin: .zero, size: reference.frame.size), display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else {
            window.center()
            window.setFrameUsingName(Self.autosaveName)
            window.setFrameAutosaveName(Self.autosaveName)
        }
    }

    // MARK: - Showing files

    /// Shows `url` (a file or folder) in this window.
    func show(_ url: URL) {
        if let session = editSession {
            if session.isSaving { NSSound.beep(); return }
            if session.isDirty {
                confirmDiscardEdits { [weak self] in
                    self?.endEditing()
                    self?.show(url)
                }
                return
            }
            endEditing()
        }
        let target = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            presentError(title: "“\(target.lastPathComponent)” can’t be opened",
                         message: "The file doesn’t exist or can’t be accessed.")
            return
        }
        if slideshow?.isRunning == true { slideshow?.stop() }
        let folder = isDir.boolValue ? target : target.deletingLastPathComponent()
        if let existing = model.browser, !isDir.boolValue,
           existing.folder.standardizedFileURL.path == folder.path {
            existing.reload(selecting: target)
        } else {
            setBrowser(FolderBrowser(opening: target, settings: settings))
        }
    }

    private func setBrowser(_ browser: FolderBrowser) {
        browserSubscriptions.removeAll()
        lastShownURL = nil
        model.browser = browser
        // @Published emits in willSet, and reload/trash assign items and index separately, so
        // read `current` on the next main-queue turn, after both assignments have finished.
        browser.objectWillChange
            .receive(on: DispatchQueue.main)
            .map { [weak browser] _ in browser?.current }
            .removeDuplicates()
            .sink { [weak self] url in self?.currentDidChange(url) }
            .store(in: &browserSubscriptions)
        currentDidChange(browser.current)
    }

    private func currentDidChange(_ url: URL?) {
        guard url != lastShownURL else { return }
        lastShownURL = url
        // The edited file went away (reload, external change): leave edit mode.
        if let session = editSession, session.url != url { endEditing() }
        state.resetForNewItem()
        // Drop a read-only text selection (Info / STL panel) so focus returns to the window.
        if let window, let text = window.firstResponder as? NSText, !text.isEditable {
            window.makeFirstResponder(nil)
        }
        if let url {
            window?.title = url.lastPathComponent
            window?.representedURL = url
        } else {
            window?.title = model.browser?.folder.lastPathComponent ?? "Pixlok"
            window?.representedURL = nil
        }
        slideshow?.itemDidChange()
        prefetchNeighbours()
    }

    private func prefetchNeighbours() {
        guard let browser = model.browser, browser.count > 1 else { return }
        let items = browser.items
        let i = browser.index
        var urls: [URL] = []
        for delta in [1, -1, 2] {
            let j = i + delta
            if items.indices.contains(j) {
                urls.append(items[j])
            } else if settings.wrapAround {
                urls.append(items[((j % items.count) + items.count) % items.count])
            }
        }
        ImageCanvasView.prefetch(urls)
    }

    // MARK: - ViewerCommandHandler

    func viewerRequestTrash() {
        guard let window, window.attachedSheet == nil,
              let browser = model.browser, let url = browser.current else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "You can restore it from the Trash in Finder."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak browser] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self, let browser else { return }
                // The folder may have changed while the sheet was up; only trash what was confirmed.
                guard browser.current == url else { return }
                do {
                    try browser.trashCurrent()
                } catch {
                    self.presentError(title: "“\(url.lastPathComponent)” couldn’t be moved to the Trash",
                                      message: error.localizedDescription)
                }
            }
        }
    }

    func viewerToggleSlideshow() {
        guard let slideshow else { return }
        if slideshow.isRunning {
            slideshow.stop()
        } else if model.browser?.current != nil {
            slideshow.start()
        }
    }

    func viewerOpenInPrimaryEditor() {
        guard !isEditing, let url = currentURL else { return }
        // The image editor is only offered for images; STL / video open in their first capable app.
        guard canTransform else {
            if let app = EditorService.installedApps(for: url).first {
                EditorService.open(url, with: app)
            } else {
                viewerChooseApplication()
            }
            return
        }
        if let editor = settings.primaryEditor {
            EditorService.open(url, with: editor.url)
        } else {
            viewerChooseApplication()
        }
    }

    func viewerOpen(with app: URL) {
        guard !isEditing, let url = currentURL else { return }
        EditorService.open(url, with: app)
    }

    func viewerChooseApplication() {
        guard !isEditing, let url = currentURL, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an app to open “\(url.lastPathComponent)”"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let app = panel.url else { return }
                EditorService.open(url, with: app)
            }
        }
    }

    func viewerShowSettings() { onRequestSettings?() }

    func viewerOpenFiles(_ urls: [URL]) {
        guard let first = urls.first else { return }
        show(first)
        window?.makeKeyAndOrderFront(nil)
    }

    func viewerShowOpenPanel() { onRequestOpenPanel?() }

    // MARK: - Menu actions (reached through the responder chain)

    @objc func pixlokOpenInPrimaryEditor(_ sender: Any?) { viewerOpenInPrimaryEditor() }
    @objc func pixlokOpenWithApp(_ sender: Any?) {
        if let app = (sender as? NSMenuItem)?.representedObject as? URL { viewerOpen(with: app) }
    }
    @objc func pixlokChooseApplication(_ sender: Any?) { viewerChooseApplication() }
    @objc func pixlokShowInFinder(_ sender: Any?) {
        if let url = currentURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    @objc func pixlokMoveToTrash(_ sender: Any?) { if !isEditing { viewerRequestTrash() } }
    @objc func pixlokZoomIn(_ sender: Any?) { if canTransform && !isEditing { state.zoomIn() } }
    @objc func pixlokZoomOut(_ sender: Any?) { if canTransform && !isEditing { state.zoomOut() } }
    @objc func pixlokActualSize(_ sender: Any?) { if canTransform && !isEditing { state.actualSize() } }
    @objc func pixlokZoomToFit(_ sender: Any?) { if canTransform && !isEditing { state.fit() } }
    @objc func pixlokRotateLeft(_ sender: Any?) {
        if let session = editSession { if session.source != nil { session.rotate(clockwise: false) } }
        else if canTransform { state.rotateLeft() }
    }
    @objc func pixlokRotateRight(_ sender: Any?) {
        if let session = editSession { if session.source != nil { session.rotate(clockwise: true) } }
        else if canTransform { state.rotateRight() }
    }
    @objc func pixlokToggleInfo(_ sender: Any?) { if currentURL != nil && !isEditing { state.showInfo.toggle() } }
    @objc func pixlokToggleSlideshow(_ sender: Any?) { if !isEditing { viewerToggleSlideshow() } }
    @objc func pixlokNext(_ sender: Any?) { if !isEditing { model.browser?.next() } }
    @objc func pixlokPrevious(_ sender: Any?) { if !isEditing { model.browser?.previous() } }
    @objc func pixlokFirst(_ sender: Any?) { if !isEditing { model.browser?.first() } }
    @objc func pixlokLast(_ sender: Any?) { if !isEditing { model.browser?.last() } }
    @objc func pixlokEditImage(_ sender: Any?) { editBegin() }
    @objc func pixlokSaveEdits(_ sender: Any?) { editSave() }
    @objc func pixlokCancelEditing(_ sender: Any?) { editRequestCancel() }
    @objc func pixlokRevertToOriginal(_ sender: Any?) { editRequestRevert() }

    var isEditing: Bool { editSession != nil }

    /// Edit mode is offered for single-frame raster images ImageEditPipeline can read.
    var canEditCurrent: Bool {
        guard let url = currentURL else { return false }
        return editHost.canEdit(url)
    }

    private var currentCategory: MediaCategory? {
        currentURL.flatMap { FormatRegistry.format(for: $0)?.category }
    }

    /// Zoom / rotate (and the image editor) apply to images and SVG only.
    var canTransform: Bool { currentCategory == .raster || currentCategory == .svg }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasFile = currentURL != nil
        let editing = isEditing
        switch item.action {
        case #selector(pixlokZoomIn(_:)), #selector(pixlokZoomOut(_:)), #selector(pixlokActualSize(_:)),
             #selector(pixlokZoomToFit(_:)):
            return canTransform && !editing
        case #selector(pixlokRotateLeft(_:)), #selector(pixlokRotateRight(_:)):
            if let session = editSession { return session.source != nil && !session.isSaving }
            return canTransform
        case #selector(pixlokToggleInfo(_:)):
            item.title = state.showInfo ? "Hide Info" : "Show Info"
            return hasFile && !editing
        case #selector(pixlokToggleSlideshow(_:)):
            item.title = state.isSlideshowRunning ? "Stop Slideshow" : "Start Slideshow"
            return hasFile && !editing
        case #selector(pixlokNext(_:)), #selector(pixlokPrevious(_:)), #selector(pixlokFirst(_:)), #selector(pixlokLast(_:)):
            return (model.browser?.count ?? 0) > 1 && !editing
        case #selector(pixlokMoveToTrash(_:)):
            return hasFile && !editing
        case #selector(pixlokEditImage(_:)):
            return !editing && !state.isSlideshowRunning && canEditCurrent
        case #selector(pixlokSaveEdits(_:)):
            return editSession?.canSave ?? false
        case #selector(pixlokCancelEditing(_:)):
            return editing && editSession?.isSaving != true
        case #selector(pixlokRevertToOriginal(_:)):
            guard let url = currentURL, editSession?.isSaving != true else { return false }
            return EditSaveService.hasOriginal(for: url)
        case #selector(pixlokOpenInPrimaryEditor(_:)), #selector(pixlokOpenWithApp(_:)), #selector(pixlokChooseApplication(_:)):
            // Another app changing the file under unsaved edits would make Save apply them to
            // content the user never previewed.
            return hasFile && !editing
        case #selector(pixlokShowInFinder(_:)):
            return hasFile
        default:
            return true
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyUp { return self.handleKeyUp(event) ? nil : event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    /// Returns true when the event was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil else { return false }
        // Leave typing alone (editable field editor / text views). Read-only selectable
        // text (Info / STL panels) must not swallow ← → Delete Space.
        if let text = window.firstResponder as? NSText, text.isEditable { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let browser = model.browser

        if let session = editSession { return handleEditKeyDown(event, session: session, mods: mods) }

        if mods.isEmpty {
            switch event.keyCode {
            case 123, 116: browser?.previous(); return browser != nil        // ←, Page Up
            case 124, 121: browser?.next(); return browser != nil            // →, Page Down
            case 115: browser?.first(); return browser != nil                // Home
            case 119: browser?.last(); return browser != nil                 // End
            case 51, 117:                                                    // Delete, Forward Delete
                guard currentURL != nil else { return false }
                viewerRequestTrash(); return true
            case 53:                                                         // Esc
                if state.isSlideshowRunning { slideshow?.stop(); return true }
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); return true }
                return false
            case 96:                                                         // F5
                guard currentURL != nil else { return false }
                viewerToggleSlideshow(); return true
            case 49:                                                         // Space
                // Video uses Space for play/pause; STL leaves it alone too.
                guard canTransform, let browser else { return false }
                browser.next(); return true
            case 14 where event.charactersIgnoringModifiers?.lowercased() == "e":   // E: edit
                guard canEditCurrent, !state.isSlideshowRunning else { return false }
                editBegin(); return true
            default:
                return false
            }
        }
        // ⌘= (unshifted "+") zooms in like ⌘+.
        if mods == [.command], event.charactersIgnoringModifiers == "=" {
            if canTransform { state.zoomIn() }
            return true
        }
        return false
    }

    /// Keys while editing: Esc cancels (crop first), Return applies the crop, "\" shows the
    /// original while held; navigation / delete / slideshow / zoom keys are swallowed.
    private func handleEditKeyDown(_ event: NSEvent, session: EditSession, mods: NSEvent.ModifierFlags) -> Bool {
        // "\" by physical key (ANSI) or by the character it types (⌥⇧7 on German layouts, …).
        let isBackslash = event.keyCode == 42 /* kVK_ANSI_Backslash */
            || event.characters == "\\" || event.charactersIgnoringModifiers == "\\"
        if isBackslash && mods.isDisjoint(with: [.command, .control]) {
            if !session.showingOriginal && session.beforeImage != nil {
                session.showingOriginal = true
                compareKeyCode = event.keyCode
            }
            return true
        }
        if mods.isEmpty {
            switch event.keyCode {
            case 53:                                                         // Esc
                if session.isCropping { session.cancelCrop() } else { editRequestCancel() }
                return true
            case 36, 76:                                                     // Return, Enter
                guard session.isCropping else { return false }
                session.commitCrop(); return true
            case 123, 124, 116, 121, 115, 119, 51, 117, 96, 49:              // nav, delete, F5, Space
                return true
            default:
                return event.charactersIgnoringModifiers?.lowercased() == "e"
            }
        }
        if mods == [.command], event.charactersIgnoringModifiers == "=" { return true }
        return false
    }

    /// Ends the compare hold on key-up of the physical key that started it, whatever the
    /// modifiers are at release (Shift pressed mid-hold would otherwise report "|").
    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let session = editSession,
              let code = compareKeyCode, event.keyCode == code else { return false }
        compareKeyCode = nil
        session.showingOriginal = false
        return true
    }

    // MARK: - Edit mode (EditCommandHandler)

    func editBegin() {
        guard !isEditing, let url = currentURL, editHost.canEdit(url), let window, window.attachedSheet == nil else { return }
        if slideshow?.isRunning == true { slideshow?.stop() }
        // What you see is what gets saved: seed the edit with the current view rotation.
        var seed = EditRecipe()
        seed.rotationQuarterTurns = ((state.rotationQuarterTurns % 4) + 4) % 4
        let session = EditSession(url: url, initialRecipe: seed)
        editHost.session = session
        session.load()
        // Drop a read-only text selection so the window keeps the keyboard.
        if let text = window.firstResponder as? NSText, !text.isEditable { window.makeFirstResponder(nil) }
    }

    func editRequestCancel() {
        guard let session = editSession, !session.isSaving else { return }
        if session.isDirty {
            confirmDiscardEdits { [weak self] in self?.endEditing() }
        } else {
            endEditing()
        }
    }

    func editSave() {
        guard let session = editSession, !session.isSaving, session.source != nil else { return }
        if session.isCropping { session.commitCrop() }
        guard !session.recipe.isIdentity else { endEditing(); return }
        Task { [weak self] in
            do {
                let result = try await session.save()
                guard let self, self.editSession === session else { return }
                self.finishEditing(selecting: result.savedURL, changed: [session.url, result.savedURL, result.originalURL])
            } catch {
                guard let self, self.editSession === session else { return }
                self.presentError(title: "“\(session.url.lastPathComponent)” couldn’t be saved",
                                  message: error.localizedDescription)
            }
        }
    }

    func editRequestRevert() {
        guard let url = currentURL, let window, window.attachedSheet == nil,
              editSession?.isSaving != true, EditSaveService.hasOriginal(for: url) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revert “\(url.lastPathComponent)” to the original?"
        alert.informativeText = "The edited version will be moved to the Trash and the untouched file from the “\(EditSaveService.originalFolderName)” folder put back."
        alert.addButton(withTitle: "Revert").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self, self.currentURL == url else { return }
                self.performRevert(of: url)
            }
        }
    }

    private func performRevert(of url: URL) {
        let original = EditSaveService.existingOriginal(for: url)
        let restored: URL
        do {
            restored = try EditSaveService.revert(url)
        } catch {
            presentError(title: "“\(url.lastPathComponent)” couldn’t be reverted", message: error.localizedDescription)
            return
        }
        let changed = [url, restored] + (original.map { [$0] } ?? [])
        EditSession.postFileDidChange(changed)
        finishEditing(selecting: restored, changed: changed)
    }

    /// Leaves edit mode without saving.
    func endEditing() {
        guard let session = editSession else { return }
        session.cancel()
        session.showingOriginal = false
        compareKeyCode = nil
        editHost.session = nil
    }

    /// After a save / revert: drop stale decodes, leave edit mode and show `url` (selection follows it).
    private func finishEditing(selecting url: URL, changed: [URL]) {
        ImageCache.shared.invalidate(changed)
        editHost.forgetEditability(changed)
        endEditing()
        editHost.contentRevision += 1
        state.resetForNewItem()
        model.browser?.reload(selecting: url)
    }

    /// "Discard changes?" sheet; runs `discard` when confirmed.
    func confirmDiscardEdits(_ discard: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard changes?"
        if let name = editSession?.url.lastPathComponent {
            alert.informativeText = "Your edits to “\(name)” haven’t been saved."
        }
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { if response == .alertFirstButtonReturn { discard() } }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            discard()
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session = editSession else { return true }
        if session.isSaving { NSSound.beep(); return false }
        guard session.isDirty else { endEditing(); return true }
        confirmDiscardEdits { [weak self] in
            self?.endEditing()
            self?.window?.close()
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        editSession?.showingOriginal = false
        compareKeyCode = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Pick up files added/removed in Finder while we were in the background.
        // Debounced: focus also returns after every sheet (Delete confirmation, Choose app).
        if let browser = model.browser, !state.isSlideshowRunning,
           Date().timeIntervalSince(browser.lastReloadDate) > 1.5 {
            browser.reload()
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        chrome.isFullScreen = true
        slideshow?.windowDidEnterFullScreen()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        chrome.isFullScreen = false
        if state.isSlideshowRunning { slideshow?.stop(leaveFullScreen: false) }
    }

    func windowWillClose(_ notification: Notification) {
        slideshow?.stop(leaveFullScreen: false)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        browserSubscriptions.removeAll()
        onClose?(self)
    }

    // MARK: - Errors

    func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
