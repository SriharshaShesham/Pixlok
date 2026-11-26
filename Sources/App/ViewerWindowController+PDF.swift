import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// PDF edit mode: entering it, saving (in place with the `original/` backup, or as a copy), and
/// the panels and sheets the edit panel asks for.
extension ViewerWindowController: PDFEditCommandHandler {

    func pdfEditBegin(url: URL) {
        guard let live = editHost.livePDF, live.url == url, live.phase == .loaded,
              let doc = live.document, !doc.isLocked else {
            NSSound.beep()
            return
        }
        guard doc.allowsCommenting || doc.allowsDocumentChanges || doc.allowsFormFieldEntry else {
            presentError(title: "“\(url.lastPathComponent)” can’t be changed",
                         message: "The PDF’s security settings don’t allow annotations, form filling or other changes.")
            return
        }
        // Page rotation is a real edit in edit mode; drop the view-only rotation first.
        state.rotationQuarterTurns = 0
        let session = PDFEditSession(url: url, document: doc, password: live.unlockedPassword)
        session.pdfView = live.pdfView
        editHost.pdfSession = session
        if let window, let text = window.firstResponder as? NSText, !text.isEditable { window.makeFirstResponder(nil) }
    }

    // MARK: - Save

    func pdfSave() {
        guard let session = pdfSession, !session.isSaving else { return }
        window?.makeFirstResponder(nil)   // finish typing in a text field / form field
        guard session.isDirty else { endEditing(); return }
        session.errorMessage = nil
        guard let data = session.renderedData() else {
            session.errorMessage = "The PDF couldn’t be written."
            return
        }
        // Check the bytes read back as the same document before replacing anything on disk.
        guard Self.verify(data, pageCount: session.document.pageCount, password: Self.savePassword(session)) else {
            session.errorMessage = "The written PDF didn’t read back correctly, so nothing was saved."
            return
        }
        session.isSaving = true
        let url = session.url
        Task { [weak self] in
            do {
                let (result, changed) = try await Task.detached(priority: .userInitiated) {
                    try Self.commit(data, over: url)
                }.value
                EditSaveService.postChanged(changed)
                guard let self, self.pdfSession === session else { return }
                session.isSaving = false
                self.finishPDFEditing(selecting: result.savedURL, changed: changed + [result.originalURL])
            } catch {
                session.isSaving = false
                session.errorMessage = "Couldn’t save: \(error.localizedDescription)"
            }
        }
    }

    nonisolated static func commit(_ data: Data, over url: URL) throws -> (EditSaveResult, [URL]) {
        let folder = url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).pixlok-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .atomic)
        } catch {
            let why = FileManager.default.isWritableFile(atPath: folder.path)
                ? error.localizedDescription
                : "The folder “\(folder.lastPathComponent)” is read-only."
            throw EditSaveService.SaveError.cannotWrite(why)
        }
        return try EditSaveService.commitReplacing(url, withTemp: temp, prior: EditSaveService.ownedBackup(for: url))
    }

    static func savePassword(_ s: PDFEditSession) -> String? {
        switch s.passwordChange {
        case .keep: return s.openPassword
        case .set(let p): return p
        case .remove: return nil
        }
    }

    /// The data opens as a PDF with `pageCount` pages (unlocking with `password` if needed).
    static func verify(_ data: Data, pageCount: Int, password: String?) -> Bool {
        guard let doc = PDFDocument(data: data) else { return false }
        if doc.isLocked { guard let password, doc.unlock(withPassword: password) else { return false } }
        return doc.pageCount == pageCount
    }

    private func finishPDFEditing(selecting url: URL, changed: [URL]) {
        editHost.pdfSession = nil
        editHost.contentRevision += 1
        state.resetForNewItem()
        model.browser?.reload(selecting: url)
    }

    // MARK: - Save a copy

    func pdfSaveAsCopy() {
        guard let session = pdfSession, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = session.url.deletingLastPathComponent()
        panel.nameFieldStringValue = session.url.deletingPathExtension().lastPathComponent + " (copy).pdf"
        panel.message = "Save a copy with your changes. The open file isn’t changed."

        let flatten = NSButton(checkboxWithTitle: "Flatten — make annotations and form fields part of the page", target: nil, action: nil)
        let ocr = NSButton(checkboxWithTitle: "Make scanned text searchable (text recognition)", target: nil, action: nil)
        let optimize = NSButton(checkboxWithTitle: "Reduce file size (downsample images for screen)", target: nil, action: nil)
        let stack = NSStackView(views: [flatten, ocr, optimize])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = stack

        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let dest = panel.url, let self, self.pdfSession === session else { return }
                var options = PDFEditSession.WriteOptions()
                options.flatten = flatten.state == .on
                options.ocr = ocr.state == .on
                options.optimizeImages = optimize.state == .on
                guard let data = session.renderedData(options) else {
                    self.presentError(title: "The copy couldn’t be written", message: "PDFKit couldn’t produce the file.")
                    return
                }
                if dest.standardizedFileURL == session.url.standardizedFileURL {
                    self.presentError(title: "Choose another name",
                                      message: "To save over the open file, use Save; it keeps the original in “original/”.")
                    return
                }
                do {
                    try data.write(to: dest, options: .atomic)
                    EditSaveService.postChanged([dest])
                } catch {
                    self.presentError(title: "The copy couldn’t be saved", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Password

    func pdfSetPassword() {
        guard let session = pdfSession, let window else { return }
        let alert = NSAlert()
        alert.messageText = session.isEncrypted ? "Change the password" : "Protect with a password"
        alert.informativeText = "Anyone opening the PDF will need this password. It is applied when you save — keep it somewhere safe; it can’t be recovered."
        let pw = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        pw.placeholderString = "Password"
        let confirm = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        confirm.placeholderString = "Confirm password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
        box.addSubview(pw)
        box.addSubview(confirm)
        alert.accessoryView = box
        alert.addButton(withTitle: "Set Password")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = pw
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self, self.pdfSession === session else { return }
                let p = pw.stringValue
                guard !p.isEmpty else { return }
                guard p == confirm.stringValue else {
                    self.presentError(title: "The passwords don’t match", message: "Nothing was changed. Try again.")
                    return
                }
                session.passwordChange = .set(p)
            }
        }
    }

    // MARK: - Signatures

    func pdfNewSignature() {
        guard let window, let session = pdfSession else { return }
        var sheet: NSWindow?
        let view = SignatureCreatorView { [weak self] image in
            if let sheet { window.endSheet(sheet) }
            guard let image else { return }
            do {
                let id = try SignatureStore.shared.add(image)
                if self?.pdfSession === session { session.tool = .signature(id) }
            } catch {
                self?.presentError(title: "The signature couldn’t be saved", message: error.localizedDescription)
            }
        }
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled]
        sheet = w
        window.beginSheet(w)
    }

    // MARK: - Pages

    func pdfInsertPagesFromFile() {
        guard let window, let session = pdfSession else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs or pictures to insert after the current page"
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, self?.pdfSession === session else { return }
                session.insertPages(from: panel.urls)
            }
        }
    }

    func pdfExtractPages() {
        guard let window, let session = pdfSession else { return }
        let doc = session.extractedDocument()
        guard doc.pageCount > 0 else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = session.url.deletingLastPathComponent()
        let base = session.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = doc.pageCount == 1
            ? "\(base) page \(session.currentIndex + 1).pdf" : "\(base) pages.pdf"
        panel.message = "Save the selected page\(doc.pageCount == 1 ? "" : "s") (\(doc.pageCount)) as a new PDF"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let dest = panel.url else { return }
                if dest.standardizedFileURL == session.url.standardizedFileURL {
                    self?.presentError(title: "Choose another name", message: "That would replace the open PDF.")
                    return
                }
                if doc.write(to: dest) { EditSaveService.postChanged([dest]) }
                else { self?.presentError(title: "The pages couldn’t be saved", message: "PDFKit couldn’t write the file.") }
            }
        }
    }
}
