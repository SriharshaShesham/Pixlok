import SwiftUI
import AppKit
import PDFKit

/// PDF display via PDFKit, with a strip on top (sidebar, page layout, search), an optional
/// thumbnails / contents sidebar, and — while a `PDFEditSession` is active — annotation tools
/// (the session's panel sits on the right, see `PDFEditPanelView`).
///
/// View rotation (toolbar ⟲ ⟳) changes the in-memory pages only and is never saved; page rotation
/// in edit mode is a real edit.
struct PDFDocumentView: View {
    let url: URL
    @ObservedObject var state: ViewerState
    @ObservedObject var editHost: EditHost
    weak var handler: ViewerCommandHandler?
    @StateObject private var model = PDFModel()

    private var session: PDFEditSession? {
        guard let s = editHost.pdfSession, s.url == url, s.document === model.document else { return nil }
        return s
    }

    var body: some View {
        ZStack {
            Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)
            switch model.url == url ? model.phase : .loading {
            case .loading:
                ImageLoadingIndicator()
            case .failed(let message):
                ImageMessageView(detail: message, fileName: url.lastPathComponent)
            case .locked:
                if let doc = model.document {
                    PDFUnlockView(fileName: url.lastPathComponent) { model.unlock(doc, password: $0) }
                }
            case .loaded:
                if let doc = model.document {
                    VStack(spacing: 0) {
                        PDFTopStrip(model: model, session: session)
                        HStack(spacing: 0) {
                            if model.showSidebar {
                                PDFSidebar(model: model, document: doc)
                                    .frame(width: 168)
                                    .overlay(alignment: .trailing) { Rectangle().fill(ViewerPalette.border).frame(width: 1) }
                            }
                            PDFKitRepresentable(model: model, document: doc, state: state, session: session,
                                                onRequestEdit: { (handler as? EditCommandHandler)?.editBegin() })
                                .overlay(alignment: .topLeading) {
                                    if let label = model.pageLabel {
                                        PDFPageBadge(text: label).padding(12)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .task(id: url) {
            editHost.livePDF = model
            await model.load(url, cachedPassword: editHost.pdfPasswords[url.standardizedFileURL.path])
        }
        .onChange(of: model.unlockedPassword) {
            if let p = model.unlockedPassword { editHost.pdfPasswords[url.standardizedFileURL.path] = p }
        }
        .onDisappear { if editHost.livePDF === model { editHost.livePDF = nil } }
        .onReceive(NotificationCenter.default.publisher(for: .pixlokFind)) { note in
            guard note.object as? PDFModel === model || note.object == nil else { return }
            model.showSearch = true
            model.focusSearchToken += 1
        }
    }
}

extension Notification.Name {
    /// Edit ▸ Find (⌘F): focus the PDF search field of the key window's document.
    static let pixlokFind = Notification.Name("PixlokFind")
}

@MainActor
final class PDFModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, locked, failed(String) }

    @Published private(set) var document: PDFDocument?
    @Published private(set) var phase: Phase = .loading
    /// "Page 3 of 12", nil for single-page documents.
    @Published var pageLabel: String?
    /// The password that unlocked the document (kept so saving can keep it protected).
    @Published private(set) var unlockedPassword: String?
    private(set) var url: URL?
    /// One PDF view per model, shared by the page area and the thumbnails.
    let pdfView = PDFCanvasView()

    // View options.
    @Published var showSidebar = false
    @Published var sidebarTab = 0                  // 0 thumbnails, 1 contents
    @Published var displayMode: PDFDisplayMode = .singlePageContinuous
    @Published var displaysAsBook = false

    // Search.
    @Published var showSearch = false
    @Published var query = ""
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var matchIndex = 0
    @Published var focusSearchToken = 0
    private var searchTask: Task<Void, Never>?

    func load(_ url: URL, cachedPassword: String? = nil) async {
        self.url = url
        document = nil
        pageLabel = nil
        unlockedPassword = nil
        phase = .loading
        // PDFDocument parses lazily, so opening even a large file is quick.
        guard FileManager.default.fileExists(atPath: url.path) else {
            phase = .failed("This file is no longer available.")
            return
        }
        guard let doc = PDFDocument(url: url) else {
            phase = .failed("The file isn't a valid PDF document, or it is damaged.")
            return
        }
        document = doc
        if doc.isLocked, let cachedPassword, doc.unlock(withPassword: cachedPassword) {
            unlockedPassword = cachedPassword
        }
        if doc.isLocked {
            phase = .locked
        } else if doc.pageCount == 0 {
            phase = .failed("This PDF has no pages.")
        } else {
            phase = .loaded
        }
    }

    /// Returns false when the password is wrong.
    @discardableResult
    func unlock(_ doc: PDFDocument, password: String) -> Bool {
        guard document === doc, doc.unlock(withPassword: password) else { return false }
        unlockedPassword = password
        phase = doc.pageCount == 0 ? .failed("This PDF has no pages.") : .loaded
        return true
    }

    // MARK: Search

    func search() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard let doc = document, !text.isEmpty else {
            matches = []
            pdfView.highlightedSelections = nil
            return
        }
        // findString is synchronous; run it on the next turn so typing stays responsive.
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            let found = doc.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
            found.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.6) }
            self.matches = found
            self.matchIndex = 0
            self.pdfView.highlightedSelections = found
            self.showMatch()
        }
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { NSSound.beep(); return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        showMatch()
    }

    private func showMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        let m = matches[matchIndex]
        pdfView.setCurrentSelection(m, animate: false)
        pdfView.scrollSelectionToVisible(nil)
    }

    func endSearch() {
        query = ""
        matches = []
        showSearch = false
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }

    func applyDisplayMode() {
        pdfView.displayMode = displayMode
        pdfView.displaysAsBook = displaysAsBook
        pdfView.layoutDocumentView()
    }

    func print(in window: NSWindow?) {
        guard let doc = document,
              let op = doc.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else {
            NSSound.beep(); return
        }
        op.jobTitle = url?.deletingPathExtension().lastPathComponent
        if let window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }
}

// MARK: - Top strip

private struct PDFTopStrip: View {
    @ObservedObject var model: PDFModel
    let session: PDFEditSession?
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            stripButton("sidebar.left", help: model.showSidebar ? "Hide sidebar" : "Show page thumbnails and contents",
                        on: model.showSidebar) { model.showSidebar.toggle() }
            Menu {
                Picker("Layout", selection: $model.displayMode) {
                    Text("Single Page").tag(PDFDisplayMode.singlePage)
                    Text("Single Page Continuous").tag(PDFDisplayMode.singlePageContinuous)
                    Text("Two Pages").tag(PDFDisplayMode.twoUp)
                    Text("Two Pages Continuous").tag(PDFDisplayMode.twoUpContinuous)
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Show Cover Page Separately", isOn: $model.displaysAsBook)
                    .disabled(model.displayMode != .twoUp && model.displayMode != .twoUpContinuous)
            } label: {
                Image(systemName: model.displayMode == .twoUp || model.displayMode == .twoUpContinuous
                      ? "book" : "doc.plaintext")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Page layout")
            .onChange(of: model.displayMode) { model.applyDisplayMode() }
            .onChange(of: model.displaysAsBook) { model.applyDisplayMode() }

            if let session {
                PDFToolRow(session: session)
                    .padding(.leading, 6)
            }

            Spacer(minLength: 8)

            if model.showSearch {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(ViewerPalette.secondaryText)
                    TextField("Search", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 150)
                        .focused($searchFocused)
                        .onSubmit { model.step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                        .onChange(of: model.query) { model.search() }
                        .onExitCommand { model.endSearch() }
                    if !model.query.isEmpty {
                        Text(model.matches.isEmpty ? "0" : "\(model.matchIndex + 1)/\(model.matches.count)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(ViewerPalette.secondaryText)
                    }
                    stripButton("chevron.up", help: "Previous match (⇧⌘G)") { model.step(-1) }
                        .disabled(model.matches.isEmpty)
                    stripButton("chevron.down", help: "Next match (⌘G)") { model.step(1) }
                        .disabled(model.matches.isEmpty)
                    stripButton("xmark.circle.fill", help: "Close search (Esc)") { model.endSearch() }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(ViewerPalette.pill))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ViewerPalette.border))
            } else {
                stripButton("magnifyingglass", help: "Search (⌘F)") {
                    model.showSearch = true
                    model.focusSearchToken += 1
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(ViewerPalette.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(ViewerPalette.border).frame(height: 1) }
        .onChange(of: model.focusSearchToken) {
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private func stripButton(_ symbol: String, help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(on ? ViewerPalette.accent : ViewerPalette.primaryText)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Tool buttons shown in the strip while editing.
struct PDFToolRow: View {
    @ObservedObject var session: PDFEditSession

    var body: some View {
        HStack(spacing: 2) {
            tool(.select)
            divider
            ForEach(PDFTool.markupTools, id: \.self) { tool($0) }
            divider
            ForEach(PDFTool.drawTools, id: \.self) { tool($0) }
            divider
            ForEach(PDFEditSession.palette.indices, id: \.self) { i in
                Circle()
                    .fill(Color(nsColor: PDFEditSession.palette[i]))
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(Color.white.opacity(session.colorIndex == i ? 0.95 : 0.15),
                                                   lineWidth: session.colorIndex == i ? 2 : 1))
                    .padding(2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        session.colorIndex = i
                        if let a = session.selected { session.setColor(i, of: a) }
                    }
                    .help("Colour")
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(ViewerPalette.border).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    private func tool(_ t: PDFTool) -> some View {
        let on = session.tool == t
        return Button {
            session.tool = t
        } label: {
            Image(systemName: t.symbol)
                .font(.system(size: 12))
                .foregroundStyle(on ? Color.white : ViewerPalette.primaryText)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? ViewerPalette.accent : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.label + (t.isTextMarkup ? " — select text to apply" : ""))
    }
}

// MARK: - Sidebar

private struct PDFSidebar: View {
    @ObservedObject var model: PDFModel
    let document: PDFDocument

    var body: some View {
        VStack(spacing: 0) {
            if document.outlineRoot.map({ $0.numberOfChildren > 0 }) == true {
                Picker("", selection: $model.sidebarTab) {
                    Text("Pages").tag(0)
                    Text("Contents").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
            }
            if model.sidebarTab == 1, let root = document.outlineRoot, root.numberOfChildren > 0 {
                List {
                    OutlineGroup(PDFOutlineItem.children(of: root), children: \.children) { item in
                        Text(item.label)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .contentShape(Rectangle())
                            .onTapGesture { item.go(in: model.pdfView) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                PDFThumbnailsRepresentable(pdfView: model.pdfView)
            }
        }
        .background(ViewerPalette.background)
    }
}

/// One entry of the document outline (table of contents).
struct PDFOutlineItem: Identifiable {
    let id = UUID()
    let outline: PDFOutline
    var label: String { outline.label ?? "Untitled" }
    var children: [PDFOutlineItem]? {
        outline.numberOfChildren > 0 ? Self.children(of: outline) : nil
    }

    static func children(of o: PDFOutline) -> [PDFOutlineItem] {
        (0..<o.numberOfChildren).compactMap { o.child(at: $0).map { PDFOutlineItem(outline: $0) } }
    }

    @MainActor func go(in view: PDFView) {
        if let dest = outline.destination { view.go(to: dest) }
        else if let action = outline.action { view.perform(action) }
    }
}

private struct PDFThumbnailsRepresentable: NSViewRepresentable {
    let pdfView: PDFCanvasView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let t = PDFThumbnailView()
        t.pdfView = pdfView
        t.thumbnailSize = CGSize(width: 120, height: 150)
        t.backgroundColor = NSColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
        t.allowsMultipleSelection = true
        t.allowsDragging = false
        pdfView.thumbnailView = t
        return t
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== pdfView { view.pdfView = pdfView }
        pdfView.thumbnailView = view
    }
}

/// "Page 3 of 12" capsule, styled like the position badge.
private struct PDFPageBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(ViewerPalette.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
            .allowsHitTesting(false)
    }
}

/// Password prompt for an encrypted PDF.
private struct PDFUnlockView: View {
    let fileName: String
    let unlock: (String) -> Bool
    @State private var password = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(ViewerPalette.secondaryText)
            Text("“\(fileName)” is password-protected")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ViewerPalette.primaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($focused)
                    .onSubmit(submit)
                Button("Unlock", action: submit)
                    .buttonStyle(ViewerAccentButtonStyle())
                    .disabled(password.isEmpty)
            }
            Text(wrong ? "Wrong password. Try again." : " ")
                .font(.system(size: 12))
                .foregroundStyle(Color.red.opacity(0.85))
        }
        .padding(24)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        wrong = !unlock(password)
        if wrong { password = "" }
    }
}

/// Hosts the model's PDF view and keeps it in sync with ViewerState and the edit session.
private struct PDFKitRepresentable: NSViewRepresentable {
    @ObservedObject var model: PDFModel
    let document: PDFDocument
    @ObservedObject var state: ViewerState
    let session: PDFEditSession?
    let onRequestEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFCanvasView {
        let view = model.pdfView
        view.displayMode = model.displayMode
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.backgroundColor = NSColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
        view.minScaleFactor = ViewerState.zoomSteps.first!
        view.maxScaleFactor = ViewerState.zoomSteps.last!
        let c = context.coordinator
        c.view = view
        c.state = state
        c.model = model
        c.attach(document)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.scaleChanged),
                                               name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFDocumentDidUnlock, object: nil)
        c.apply(zoom: state.zoom, turns: state.rotationQuarterTurns)
        c.pageChanged()
        // Focus the document so ↑ / ↓ scroll it straight away (← → stay folder navigation,
        // handled at window level). Only when nothing editable has focus.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            if let text = window.firstResponder as? NSText, text.isEditable { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: PDFCanvasView, context: Context) {
        let c = context.coordinator
        c.state = state
        c.model = model
        view.onRequestEdit = onRequestEdit
        if view.document !== document { c.attach(document) }
        if view.session !== session {
            view.session = session
            session?.pdfView = view
        }
        // In edit mode page rotation is a real edit; the view rotation stays at 0.
        if session == nil { c.apply(zoom: state.zoom, turns: state.rotationQuarterTurns) }
        else { c.apply(zoom: state.zoom, turns: 0) }
        c.pageChanged()
    }

    static func dismantleNSView(_ view: PDFCanvasView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: PDFView?
        weak var state: ViewerState?
        weak var model: PDFModel?
        /// Each page's own rotation, so view rotation is applied on top of it.
        private var baseRotations: [Int] = []
        private var appliedTurns = 0
        private var appliedZoom: ZoomMode?
        /// Set while we change the scale ourselves, so the change isn't read back as a user zoom.
        private var applying = false

        func attach(_ document: PDFDocument) {
            guard let view else { return }
            baseRotations = (0..<document.pageCount).map { document.page(at: $0)?.rotation ?? 0 }
            appliedTurns = 0
            appliedZoom = nil
            view.document = document
        }

        func apply(zoom: ZoomMode, turns: Int) {
            guard let view, let doc = view.document else { return }
            let turns = ((turns % 4) + 4) % 4
            let rotated = turns != appliedTurns
            if rotated {
                let current = view.currentPage
                for i in 0..<min(doc.pageCount, baseRotations.count) {
                    doc.page(at: i)?.rotation = (baseRotations[i] + 90 * turns) % 360
                }
                appliedTurns = turns
                view.layoutDocumentView()
                if let current { view.go(to: current) }
            }
            guard rotated || zoom != appliedZoom else { return }
            appliedZoom = zoom
            applying = true
            defer { applying = false }
            switch zoom {
            case .fit:
                view.autoScales = true
            case .scale(let s):
                view.autoScales = false
                let clamped = min(max(s, view.minScaleFactor), view.maxScaleFactor)
                if abs(view.scaleFactor - clamped) > 0.0001 { view.scaleFactor = clamped }
            }
            reportScale()
        }

        @objc func scaleChanged() {
            reportScale()
            // A pinch or PDFKit's own zoom commands: switch the toolbar from "Fit" to a percentage.
            guard !applying, let view, let state, !view.autoScales else { return }
            let scale = view.scaleFactor
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .scale(let s) = state.zoom, abs(s - scale) < 0.0001 { return }
                self.appliedZoom = .scale(scale)
                state.zoom = .scale(scale)
            }
        }

        @objc func pageChanged() {
            guard let view, let doc = view.document else { return }
            let count = doc.pageCount
            var text: String?
            if count > 1, let page = view.currentPage {
                text = "Page \(doc.index(for: page) + 1) of \(count)"
            }
            let model = self.model
            DispatchQueue.main.async {
                if model?.pageLabel != text { model?.pageLabel = text }
            }
        }

        private func reportScale() {
            guard let view else { return }
            let scale = view.scaleFactor
            DispatchQueue.main.async { [weak self] in
                guard let state = self?.state, abs(state.effectiveScale - scale) > 0.0001 else { return }
                state.effectiveScale = scale
            }
        }
    }
}
