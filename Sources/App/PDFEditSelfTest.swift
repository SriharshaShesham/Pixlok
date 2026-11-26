import AppKit
import PDFKit
import CoreText

/// `Pixlok --selftest-pdf-edit <empty scratch folder>`: builds a PDF with text and a form field,
/// then exercises PDF edit mode headlessly — every annotation type, a signature, form filling,
/// page operations, undo/redo, metadata, password, save over the file with the original/ backup,
/// re-save, and Save a Copy options. Uses a throwaway signature folder inside the scratch folder.
@MainActor
enum PDFEditSelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String, _ why: @autoclosure () -> String = "") {
        if ok { print("PASS  \(name)") } else {
            failures += 1
            print("FAIL  \(name)\(why().isEmpty ? "" : " — \(why())")")
        }
    }

    static func run(root path: String) -> Int32 {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty else {
            print("FAIL  scratch folder must be empty: \(root.path)")
            return 1
        }
        let url = root.appendingPathComponent("form.pdf")
        makeFixture(url)
        let fixtureBytes = try? Data(contentsOf: url)

        guard let doc = PDFDocument(url: url) else { print("FAIL  fixture unreadable"); return 1 }
        check(doc.pageCount == 3, "fixture: 3 pages")
        check(doc.findString("Pixlok", withOptions: .caseInsensitive).count == 3, "search: 'Pixlok' found once per page")

        let session = PDFEditSession(url: url, document: doc, password: nil)
        session.undoManager.groupsByEvent = false   // no run loop between steps here
        let view = PDFCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        view.document = doc
        session.pdfView = view
        view.session = session
        check(!session.isDirty, "new session is clean")

        let p0 = doc.page(at: 0)!
        // Text markup.
        if let hello = doc.findString("Hello", withOptions: []).first {
            session.markup(hello, as: .highlight)
        }
        if let world = doc.findString("world", withOptions: []).first { session.markup(world, as: .underline) }
        if let page = doc.findString("page", withOptions: []).first { session.markup(page, as: .strikeOut) }
        let types0 = Set(p0.annotations.compactMap(\.type))
        check(types0.isSuperset(of: ["Highlight", "Underline", "StrikeOut"]), "markup: highlight/underline/strike", "\(types0)")
        check(session.isDirty && session.changeCount == 3, "markup marks dirty (3 changes)", "\(session.changeCount)")

        // Drawing tools.
        session.makeTextBox(at: CGPoint(x: 60, y: 300), on: p0)
        if let tb = session.selected { session.setContents("Approved by Ada", of: tb) }
        session.makeNote(at: CGPoint(x: 500, y: 700), on: p0)
        if let n = session.selected { session.setContents("Check this", of: n) }
        session.makeInk([CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 130), CGPoint(x: 180, y: 100)], on: p0)
        session.makeShape(.rectangle, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 400, y: 360), on: p0)
        session.makeShape(.oval, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 400, y: 260), on: p0)
        session.makeShape(.line, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 200, y: 60), on: p0)
        session.makeShape(.arrow, from: CGPoint(x: 50, y: 80), to: CGPoint(x: 200, y: 90), on: p0)
        let types1 = p0.annotations.compactMap(\.type)
        for t in ["FreeText", "Text", "Ink", "Square", "Circle", "Line"] {
            check(types1.contains(t), "tool creates \(t)")
        }
        check(types1.filter { $0 == "Line" }.count == 2, "line + arrow")
        let freeText = p0.annotations.first { $0.type == "FreeText" }
        check(freeText?.contents == "Approved by Ada", "text box contents")
        check((freeText?.bounds.width ?? 0) > 80, "text box grew to fit its text", "\(freeText?.bounds ?? .zero)")

        // Signature (throwaway store).
        let store = SignatureStore(folder: root.appendingPathComponent(".signatures"))
        let sigImage = SignatureStore.render(text: "Ada L", font: NSFont(name: "Snell Roundhand", size: 40) ?? .systemFont(ofSize: 40), color: .black)
        check(sigImage != nil, "signature: typed signature renders")
        var sigID: UUID?
        if let sigImage { sigID = try? store.add(sigImage) }
        check(sigID != nil && store.signatures.count == 1, "signature: saved to store")
        if let sigID { session.placeSignature(sigID, at: CGPoint(x: 400, y: 120), on: p0, store: store) }
        let stamp = p0.annotations.first { $0 is PDFImageStampAnnotation }
        check(stamp != nil, "signature: placed as stamp")
        // Move + resize with undo record.
        if let stamp {
            let old = stamp.bounds
            stamp.bounds = PDFCanvasView.resized(old, corner: 2, to: CGPoint(x: old.maxX + 40, y: old.maxY + 40), keepAspect: true)
            session.commitBounds(of: stamp, from: old, name: "Resize")
            let r = stamp.bounds
            check(abs(r.width / r.height - old.width / old.height) < 0.01, "signature resize keeps aspect")
        }

        // Paper-photo background removal.
        if let photo = makePaperPhoto(), let cleaned = SignatureStore.removingBackground(photo) {
            check(alpha(cleaned, x: 5, y: 5) < 20, "photo signature: paper becomes transparent")
            check(alpha(cleaned, x: cleaned.width / 2, y: cleaned.height / 2) > 200, "photo signature: ink stays opaque")
        } else { check(false, "photo signature processed") }

        // Form filling (directly, like typing into the field).
        let field = p0.annotations.first { $0.type == "Widget" }
        check(field != nil, "fixture has a form field")
        field?.widgetStringValue = "Ada Lovelace"

        // Pages: blank page after page 1, rotate it, duplicate, then delete the duplicate.
        view.go(to: p0)
        session.insertBlankPage()
        check(doc.pageCount == 4, "insert blank page")
        if let blank = doc.page(at: 1) { view.go(to: blank) }
        session.rotatePages(clockwise: true)
        check(doc.page(at: 1)?.rotation == 90, "rotate page right")
        session.duplicatePages()
        check(doc.pageCount == 5, "duplicate page")
        if let dup = doc.page(at: 2) { view.go(to: dup) }
        session.deletePages()
        check(doc.pageCount == 4, "delete page")
        if let last = doc.page(at: 3) {
            view.go(to: last)
            session.movePage(by: -1)
            check(doc.index(for: last) == 2, "move page up")
        }

        // Undo / redo everything.
        let changes = session.changeCount
        var undos = 0
        while session.undoManager.canUndo && undos < 100 { session.undoManager.undo(); undos += 1 }
        check(session.changeCount == 0, "undo all → no changes", "\(session.changeCount)")
        check(doc.pageCount == 3 && p0.annotations.allSatisfy { $0.type == "Widget" }, "undo all → original pages and annotations",
              "\(doc.pageCount) \(p0.annotations.compactMap(\.type))")
        var redos = 0
        while session.undoManager.canRedo && redos < 100 { session.undoManager.redo(); redos += 1 }
        check(session.changeCount == changes && doc.pageCount == 4, "redo all", "\(session.changeCount)/\(changes) pages \(doc.pageCount)")

        // Metadata + password, then save over the file.
        session.title = "Signed form"
        session.author = "Ada Lovelace"
        session.keywords = "form, signed"
        session.passwordChange = .set("pw123")
        guard let data = session.renderedData() else { print("FAIL  renderedData"); return 1 }
        check(ViewerWindowController.verify(data, pageCount: 4, password: "pw123"), "written data verifies")
        do {
            let (result, _) = try ViewerWindowController.commit(data, over: url)
            check(result.savedURL == url, "saved in place")
            let backup = root.appendingPathComponent("original/form.pdf")
            check(result.originalURL.standardizedFileURL == backup.standardizedFileURL, "original kept in original/")
            check((try? Data(contentsOf: backup)) == fixtureBytes, "original/ holds the untouched bytes")
        } catch { check(false, "save in place", error.localizedDescription) }

        // Reopen and check everything survived.
        guard let re = PDFDocument(url: url) else { print("FAIL  saved file unreadable"); return 1 }
        check(re.isLocked, "saved file is password-protected")
        check(re.unlock(withPassword: "pw123"), "password unlocks")
        check(re.pageCount == 4, "saved: 4 pages")
        check(re.page(at: 1)?.rotation == 90, "saved: page rotation")
        let rp0 = re.page(at: 0)!
        let savedTypes = rp0.annotations.compactMap(\.type)
        for t in ["Highlight", "Underline", "StrikeOut", "FreeText", "Text", "Ink", "Square", "Circle", "Line", "Stamp", "Widget"] {
            check(savedTypes.contains(t), "saved: \(t) annotation", "\(savedTypes)")
        }
        check(rp0.annotations.first { $0.type == "Widget" }?.widgetStringValue == "Ada Lovelace", "saved: form field value")
        let attrs = re.documentAttributes ?? [:]
        check(attrs[PDFDocumentAttribute.titleAttribute] as? String == "Signed form", "saved: title")
        check(attrs[PDFDocumentAttribute.authorAttribute] as? String == "Ada Lovelace", "saved: author")
        if let st = rp0.annotations.first(where: { $0.type == "Stamp" }) {
            // The signature's appearance was written: render the page and look for ink in the stamp.
            let dark = darkPixels(rp0, in: st.bounds)
            check(dark > 20, "saved: signature appearance renders", "\(dark) dark px")
        }

        // Second save reuses the backup and leaves it untouched.
        let session2 = PDFEditSession(url: url, document: re, password: "pw123")
        session2.passwordChange = .remove
        if let data2 = session2.renderedData() {
            do {
                let (r2, _) = try ViewerWindowController.commit(data2, over: url)
                check(r2.originalURL.lastPathComponent == "form.pdf", "re-save reuses original/form.pdf")
                check((try? Data(contentsOf: r2.originalURL)) == fixtureBytes, "re-save: original still untouched")
                let backups = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("original").path)) ?? []
                check(backups.filter { $0.hasSuffix(".pdf") }.count == 1, "re-save: no second backup", "\(backups)")
                check(PDFDocument(url: url)?.isLocked == false, "password removed")
            } catch { check(false, "re-save", error.localizedDescription) }
        }

        // Save a Copy: flatten burns annotations into the page.
        if let flat = PDFDocument(url: url) {
            let s3 = PDFEditSession(url: url, document: flat, password: nil)
            var o = PDFEditSession.WriteOptions()
            o.flatten = true
            if let d = s3.renderedData(o), let f = PDFDocument(data: d) {
                let remaining = f.page(at: 0)?.annotations.filter { $0.type != "Link" }.count ?? -1
                check(remaining == 0, "flattened copy has no live annotations", "\(remaining)")
                check(f.pageCount == 4, "flattened copy keeps pages")
            } else { check(false, "flattened copy written") }
        }

        // An encrypted PDF with separate user / owner passwords keeps both when annotated.
        let secured = root.appendingPathComponent("secured.pdf")
        makeFixture(secured)
        if let d = PDFDocument(url: secured),
           let data = d.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "user1",
                                                     PDFDocumentWriteOption.ownerPasswordOption: "owner1"]) {
            try? data.write(to: secured)
        }
        if let d = PDFDocument(url: secured), d.unlock(withPassword: "user1") {
            let s4 = PDFEditSession(url: secured, document: d, password: "user1")
            s4.makeShape(.rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60), on: d.page(at: 0)!)
            if let data = s4.renderedData(),
               ViewerWindowController.verify(data, pageCount: d.pageCount, password: "user1") {
                _ = try? ViewerWindowController.commit(data, over: secured)
            }
            let a = PDFDocument(url: secured), b = PDFDocument(url: secured)
            check(a?.isLocked == true, "secured: still needs a password after save")
            check(a?.unlock(withPassword: "user1") == true && a?.permissionsStatus == .user, "secured: user password unchanged")
            check(b?.unlock(withPassword: "owner1") == true && b?.permissionsStatus == .owner, "secured: owner password unchanged")
            check(a?.page(at: 0)?.annotations.contains { $0.type == "Square" } == true, "secured: annotation saved")
        } else { check(false, "secured fixture") }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Fixtures

    private static func makeFixture(_ url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for i in 1...3 {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: "Hello world from Pixlok, page \(i)",
                                          attributes: [.font: NSFont(name: "Helvetica", size: 18)!])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        // Add a text form field with PDFKit.
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return }
        let w = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 220, height: 24), forType: .widget, withProperties: nil)
        w.widgetFieldType = .text
        w.fieldName = "name"
        w.backgroundColor = NSColor.white
        page.addAnnotation(w)
        doc.write(to: url)
    }

    private static func makePaperPhoto() -> CGImage? {
        guard let ctx = SignatureStore.rgbaContext(width: 400, height: 200) else { return nil }
        ctx.setFillColor(CGColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1))   // off-white paper
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1))   // ink
        ctx.fill(CGRect(x: 150, y: 80, width: 100, height: 40))
        return ctx.makeImage()
    }

    private static func alpha(_ image: CGImage, x: Int, y: Int) -> Int {
        guard let ctx = SignatureStore.rgbaContext(width: image.width, height: image.height) else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return -1 }
        return Int(data.load(fromByteOffset: y * ctx.bytesPerRow + x * 4 + 3, as: UInt8.self))
    }

    private static func darkPixels(_ page: PDFPage, in rect: CGRect) -> Int {
        let pageBox = page.bounds(for: .mediaBox)
        let img = page.thumbnail(of: pageBox.size, for: .mediaBox)
        guard let rep = img.representations.first.flatMap({ _ in NSBitmapImageRep(data: img.tiffRepresentation ?? Data()) }) else { return 0 }
        let sx = CGFloat(rep.pixelsWide) / pageBox.width, sy = CGFloat(rep.pixelsHigh) / pageBox.height
        var n = 0
        for y in stride(from: Int(rect.minY * sy), to: Int(rect.maxY * sy), by: 2) {
            for x in stride(from: Int(rect.minX * sx), to: Int(rect.maxX * sx), by: 2) {
                // NSBitmapImageRep rows are top-down.
                guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y) else { continue }
                if c.brightnessComponent < 0.4 { n += 1 }
            }
        }
        return n
    }
}
