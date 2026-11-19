import SwiftUI
import AppKit
import PDFKit

/// PDF display via PDFKit: all pages in one vertically scrolling column, honouring
/// ViewerState zoom/rotation. Scale 1.0 = 100% (one PDF point per screen point);
/// "Fit" lets PDFKit fit the page width to the window.
///
/// Rotation is view-only: it changes the pages of the in-memory document, which is
/// never written back to disk.
struct PDFDocumentView: View {
    let url: URL
    @ObservedObject var state: ViewerState
    @StateObject private var model = PDFModel()

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
                    PDFKitRepresentable(document: doc, state: state, page: $model.pageLabel)
                        .overlay(alignment: .topLeading) {
                            if let label = model.pageLabel {
                                PDFPageBadge(text: label).padding(12)
                            }
                        }
                }
            }
        }
        .task(id: url) { await model.load(url) }
    }
}

@MainActor
final class PDFModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, locked, failed(String) }

    @Published private(set) var document: PDFDocument?
    @Published private(set) var phase: Phase = .loading
    /// "Page 3 of 12", nil for single-page documents.
    @Published var pageLabel: String?
    private(set) var url: URL?

    func load(_ url: URL) async {
        self.url = url
        document = nil
        pageLabel = nil
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
        phase = doc.pageCount == 0 ? .failed("This PDF has no pages.") : .loaded
        return true
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

/// Hosts a PDFView and keeps it in sync with ViewerState.
private struct PDFKitRepresentable: NSViewRepresentable {
    let document: PDFDocument
    @ObservedObject var state: ViewerState
    @Binding var page: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.backgroundColor = NSColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
        view.minScaleFactor = ViewerState.zoomSteps.first!
        view.maxScaleFactor = ViewerState.zoomSteps.last!
        let c = context.coordinator
        c.view = view
        c.state = state
        c.pageBinding = $page
        c.attach(document)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.scaleChanged),
                                               name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: view)
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

    func updateNSView(_ view: PDFView, context: Context) {
        let c = context.coordinator
        c.state = state
        c.pageBinding = $page
        if view.document !== document { c.attach(document) }
        c.apply(zoom: state.zoom, turns: state.rotationQuarterTurns)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: PDFView?
        weak var state: ViewerState?
        var pageBinding: Binding<String?>?
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
            let binding = pageBinding
            DispatchQueue.main.async {
                if binding?.wrappedValue != text { binding?.wrappedValue = text }
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
