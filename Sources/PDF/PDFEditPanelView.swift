import SwiftUI
import AppKit
import PDFKit

/// Actions the PDF edit panel forwards to the window controller (panels, sheets, files).
@MainActor
protocol PDFEditCommandHandler: AnyObject {
    func pdfNewSignature()
    func pdfInsertPagesFromFile()
    func pdfExtractPages()
    func pdfSaveAsCopy()
    func pdfSetPassword()
}

/// Right-hand panel in PDF edit mode: selected item, style, signatures, pages, document, and the
/// sticky Save / Cancel footer.
struct PDFEditPanelView: View {
    @ObservedObject var session: PDFEditSession
    @ObservedObject var signatures = SignatureStore.shared
    weak var handler: EditCommandHandler?
    weak var pdfHandler: PDFEditCommandHandler?
    @FocusState private var textFocused: Bool
    @State private var editingText = ""
    /// Text of the selected item when typing started (one undo step per edit).
    @State private var textAtFocus: (PDFAnnotation, String)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ViewerPalette.border)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    if let a = session.selected { selectionSection(a) } else { toolHint }
                    styleSection
                    signatureSection
                    pagesSection
                    documentSection
                }
                .padding(16)
            }
            .disabled(session.isSaving)
            footer
        }
        .font(.system(size: 12))
        .foregroundStyle(ViewerPalette.primaryText)
        .frame(width: EditPanelView.width)
        .frame(maxHeight: .infinity)
        .background(EditPanelView.panelColor)
        .overlay(alignment: .leading) { Rectangle().fill(ViewerPalette.border).frame(width: 1) }
        .onAppear {
            session.pdfView?.onRequestTextEditing = {
                DispatchQueue.main.async {
                    textFocused = true
                    // Select the text so typing replaces a new box's placeholder.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
            }
        }
        .onChange(of: session.selected) {
            commitTyping()
            editingText = session.selected?.contents ?? ""
        }
        .onChange(of: textFocused) {
            if textFocused, let a = session.selected { textAtFocus = (a, a.contents ?? "") } else { commitTyping() }
        }
        .onDisappear { commitTyping() }
        .onChange(of: session.revision) {
            if !textFocused { editingText = session.selected?.contents ?? "" }
        }
    }

    private func commitTyping() {
        guard let (a, old) = textAtFocus else { return }
        textAtFocus = nil
        session.commitContents(of: a, from: old)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Text("Edit PDF").font(.system(size: 13, weight: .semibold))
            Text("\(session.document.pageCount) page\(session.document.pageCount == 1 ? "" : "s")")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(ViewerPalette.secondaryText)
            Spacer()
            Button { session.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain)
                .disabled(!session.undoManager.canUndo)
                .help("Undo (⌘Z)")
            Button { session.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain)
                .disabled(!session.undoManager.canRedo)
                .help("Redo (⇧⌘Z)")
        }
        .id(session.revision)   // refresh undo/redo availability
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = session.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(ViewerPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if EditSaveService.hasOriginal(for: session.url) {
                Button {
                    handler?.editRequestRevert()
                } label: {
                    Label("Revert to Original", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(EditLinkButtonStyle())
                .help("Put back the untouched file kept in the “original” folder")
            }
            HStack(spacing: 8) {
                if session.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving…").foregroundStyle(ViewerPalette.secondaryText)
                }
                Spacer()
                Menu {
                    Button("Save a Copy…") { pdfHandler?.pdfSaveAsCopy() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More save options")
                Button("Cancel") { handler?.editRequestCancel() }
                    .buttonStyle(EditPanelButtonStyle(selected: false, fixed: true))
                    .help("Leave edit mode (Esc)")
                Button("Save") { handler?.editSave() }
                    .buttonStyle(EditPanelButtonStyle(selected: false, prominent: true, fixed: true))
                    .help("Save over the file; the untouched original is kept in “original/” (⌘S)")
            }
            .disabled(session.isSaving)
        }
        .padding(16)
        .background(EditPanelView.panelColor)
        .overlay(alignment: .top) { Rectangle().fill(ViewerPalette.border).frame(height: 1) }
    }

    // MARK: Sections

    private var toolHint: some View {
        EditSection(title: "Tool", canReset: false, onReset: {}) {
            Text(hint(for: session.tool))
                .foregroundStyle(ViewerPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Add Today’s Date") {
                    session.pendingText = Date().formatted(date: .long, time: .omitted)
                    session.tool = .text
                }
                .buttonStyle(EditPanelButtonStyle(selected: false, compact: true))
                Button("Add Check Mark") {
                    session.pendingText = "✓"
                    session.tool = .text
                }
                .buttonStyle(EditPanelButtonStyle(selected: false, compact: true))
            }
        }
    }

    private func hint(for tool: PDFTool) -> String {
        switch tool {
        case .select: return "Click an annotation to select, move or resize it. Click a form field to fill it in. Delete removes the selection."
        case .highlight, .underline, .strikeOut: return "Drag across text to \(tool.label.lowercased()) it."
        case .text: return "Click where the text should go, then type it in the box on the right."
        case .note: return "Click to pin a note, then type it on the right."
        case .ink: return "Drag to draw freehand."
        case .rectangle, .oval, .line, .arrow: return "Drag to draw a \(tool.label.lowercased()). Hold Shift while resizing to keep proportions."
        case .signature: return "Click on the page where the signature goes. You can move and resize it afterwards."
        }
    }

    private func selectionSection(_ a: PDFAnnotation) -> some View {
        EditSection(title: PDFCanvasView.displayName(a), canReset: false, onReset: {}) {
            if a.type == "FreeText" || a.type == "Text" {
                TextEditor(text: $editingText)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 60, maxHeight: 140)
                    .background(RoundedRectangle(cornerRadius: 6).fill(ViewerPalette.pill))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(textFocused ? ViewerPalette.accent : ViewerPalette.border))
                    .focused($textFocused)
                    .onChange(of: editingText) { session.liveSetContents(editingText, of: a) }
                if a.type == "FreeText" {
                    HStack {
                        Text("Size")
                        Slider(value: Binding(get: { a.font?.pointSize ?? session.fontSize },
                                              set: { session.setFontSize($0.rounded(), of: a) }), in: 6...72)
                        Text("\(Int(a.font?.pointSize ?? 0)) pt").monospacedDigit()
                            .foregroundStyle(ViewerPalette.secondaryText).frame(width: 40, alignment: .trailing)
                    }
                }
            }
            if PDFEditSession.hasStroke(a.type) {
                HStack {
                    Text("Line")
                    Slider(value: Binding(get: { a.border?.lineWidth ?? 1 },
                                          set: { session.setLineWidth(($0 * 2).rounded() / 2, of: a) }), in: 0.5...12)
                    Text(String(format: "%.1f", a.border?.lineWidth ?? 1)).monospacedDigit()
                        .foregroundStyle(ViewerPalette.secondaryText).frame(width: 32, alignment: .trailing)
                }
            }
            HStack {
                Button(role: .destructive) { session.deleteSelected() } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(EditPanelButtonStyle(selected: false, compact: true))
                .help("Delete (⌫)")
                Spacer()
                Button("Deselect") { session.selected = nil }
                    .buttonStyle(EditLinkButtonStyle())
            }
        }
        .id(ObjectIdentifier(a))
    }

    private var styleSection: some View {
        EditSection(title: "New items", canReset: false, onReset: {}) {
            HStack {
                Text("Line width")
                Slider(value: $session.lineWidth, in: 0.5...12, step: 0.5)
                Text(String(format: "%.1f", session.lineWidth)).monospacedDigit()
                    .foregroundStyle(ViewerPalette.secondaryText).frame(width: 32, alignment: .trailing)
            }
            HStack {
                Text("Text size")
                Slider(value: $session.fontSize, in: 6...72, step: 1)
                Text("\(Int(session.fontSize)) pt").monospacedDigit()
                    .foregroundStyle(ViewerPalette.secondaryText).frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var signatureSection: some View {
        EditSection(title: "Signatures", canReset: false, onReset: {}) {
            if signatures.signatures.isEmpty {
                Text("Create a signature once — draw it, type it or use a photo — then click to place it.")
                    .foregroundStyle(ViewerPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(signatures.signatures) { sig in
                let active = session.tool == .signature(sig.id)
                HStack(spacing: 8) {
                    Image(nsImage: sig.image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 34)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(active ? ViewerPalette.accent : Color.clear, lineWidth: 2))
                        .contentShape(Rectangle())
                        .onTapGesture { session.tool = active ? .select : .signature(sig.id) }
                        .help("Click, then click on the page to place it")
                    Button { signatures.delete(sig.id) } label: {
                        Image(systemName: "trash").foregroundStyle(ViewerPalette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this saved signature")
                }
            }
            Button {
                pdfHandler?.pdfNewSignature()
            } label: {
                Label("New Signature…", systemImage: "signature")
            }
            .buttonStyle(EditPanelButtonStyle(selected: false, compact: true))
        }
    }

    private var pagesSection: some View {
        EditSection(title: "Pages", canReset: false, onReset: {}) {
            Text("Act on the current page, or on the pages selected in the sidebar.")
                .font(.system(size: 11))
                .foregroundStyle(ViewerPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                pageButton("Rotate Left", "rotate.left") { session.rotatePages(clockwise: false) }
                pageButton("Rotate Right", "rotate.right") { session.rotatePages(clockwise: true) }
                pageButton("Move Up", "arrow.up") { session.movePage(by: -1) }
                pageButton("Move Down", "arrow.down") { session.movePage(by: 1) }
                pageButton("Blank Page", "doc.badge.plus") { session.insertBlankPage() }
                pageButton("Duplicate", "plus.square.on.square") { session.duplicatePages() }
                pageButton("Insert File…", "doc.on.doc") { pdfHandler?.pdfInsertPagesFromFile() }
                pageButton("Extract…", "square.and.arrow.up") { pdfHandler?.pdfExtractPages() }
            }
            Button(role: .destructive) { session.deletePages() } label: {
                Label("Delete Page", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(EditPanelButtonStyle(selected: false, compact: true))
            .disabled(session.document.pageCount <= 1)
        }
    }

    private func pageButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(EditPanelButtonStyle(selected: false, compact: true))
    }

    private var documentSection: some View {
        EditSection(title: "Document", canReset: false, onReset: {}) {
            labeled("Title") { TextField("", text: $session.title) }
            labeled("Author") { TextField("", text: $session.author) }
            labeled("Subject") { TextField("", text: $session.subject) }
            labeled("Keywords") { TextField("comma, separated", text: $session.keywords) }
            HStack(spacing: 6) {
                Image(systemName: session.isEncrypted ? "lock.fill" : "lock.open")
                    .foregroundStyle(session.isEncrypted ? ViewerPalette.accent : ViewerPalette.secondaryText)
                Text(passwordStatus)
                    .foregroundStyle(ViewerPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button(session.isEncrypted ? "Change Password…" : "Add Password…") { pdfHandler?.pdfSetPassword() }
                    .buttonStyle(EditPanelButtonStyle(selected: false, compact: true))
                if session.isEncrypted {
                    Button("Remove") { session.passwordChange = .remove }
                        .buttonStyle(EditPanelButtonStyle(selected: false, compact: true))
                }
            }
        }
    }

    private var passwordStatus: String {
        switch session.passwordChange {
        case .keep:
            if session.document.isEncrypted && session.openPassword == nil {
                return "This PDF has security settings (kept when saving)."
            }
            return session.isEncrypted ? "Password-protected (kept when saving)" : "No password"
        case .set: return "A new password will be set when you save"
        case .remove: return "The password will be removed when you save"
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).foregroundStyle(ViewerPalette.secondaryText).frame(width: 62, alignment: .leading)
            content().textFieldStyle(.roundedBorder).controlSize(.small)
        }
    }
}
