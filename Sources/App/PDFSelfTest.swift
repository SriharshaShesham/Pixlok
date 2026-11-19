import Foundation
import AppKit
import PDFKit

/// `Pixlok --selftest-pdf <empty scratch folder>`: builds PDF fixtures there and checks PDF loading
/// (normal, rotated page, locked + unlock, damaged, empty), the info panel's PDF fields, folder
/// listing, and the "new formats start enabled" settings migration. Never touches real settings.
@MainActor
enum PDFSelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String, _ why: @autoclosure () -> String = "") {
        if ok {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)\(why().isEmpty ? "" : " — \(why())")")
        }
    }

    static func run(root path: String) async -> Int32 {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        guard existing.isEmpty else {
            print("FAIL  scratch folder must be empty: \(root.path)")
            return 1
        }

        // Fixtures.
        let multi = root.appendingPathComponent("multi.pdf")
        makePDF(multi, pages: 3, size: CGSize(width: 595, height: 842))
        if let doc = PDFDocument(url: multi) {
            doc.page(at: 1)?.rotation = 90
            doc.write(to: multi)
        }
        let plain = root.appendingPathComponent("plain.pdf")
        makePDF(plain, pages: 2, size: CGSize(width: 612, height: 792))
        let locked = root.appendingPathComponent("locked.pdf")
        PDFDocument(url: plain)?.write(to: locked, withOptions: [.userPasswordOption: "secret",
                                                                 .ownerPasswordOption: "owner"])
        let broken = root.appendingPathComponent("broken.pdf")
        try? Data("not a pdf".utf8).write(to: broken)
        let bleed = root.appendingPathComponent("bleed.pdf")
        makePDF(bleed, pages: 1, size: CGSize(width: 650, height: 900))
        if let doc = PDFDocument(url: bleed) {
            doc.page(at: 0)?.setBounds(CGRect(x: 27, y: 29, width: 595, height: 842), for: .cropBox)
            doc.write(to: bleed)
        }
        let upper = root.appendingPathComponent("UPPER.PDF")
        try? FileManager.default.copyItem(at: plain, to: upper)

        // Registry.
        check(FormatRegistry.format(for: multi)?.category == .pdf, "registry: .pdf is a PDF")
        check(FormatRegistry.format(for: upper)?.category == .pdf, "registry: .PDF (upper case) is a PDF")
        check(FormatRegistry.format(id: "pdf")?.utTypes == ["com.adobe.pdf"], "registry: UTType com.adobe.pdf")

        // Viewer model.
        let model = PDFModel()
        await model.load(multi)
        check(model.phase == .loaded, "load: multi-page PDF loads", "\(model.phase)")
        check(model.document?.pageCount == 3, "load: 3 pages", "\(model.document?.pageCount ?? -1)")
        check(model.document?.page(at: 1)?.rotation == 90, "load: page rotation preserved")

        await model.load(broken)
        check(model.phase == .failed("The file isn't a valid PDF document, or it is damaged."), "load: damaged file fails",
              "\(model.phase)")
        check(model.document == nil, "load: damaged file has no document")

        await model.load(root.appendingPathComponent("missing.pdf"))
        check(model.phase == .failed("This file is no longer available."), "load: missing file fails", "\(model.phase)")

        await model.load(locked)
        check(model.phase == .locked, "locked: asks for a password", "\(model.phase)")
        if let doc = model.document {
            check(!model.unlock(doc, password: "wrong"), "locked: wrong password rejected")
            check(model.phase == .locked, "locked: still locked after a wrong password")
            check(model.unlock(doc, password: "secret"), "locked: right password accepted")
            check(model.phase == .loaded, "locked: shown after unlocking", "\(model.phase)")
            check(doc.pageCount == 2, "locked: 2 pages after unlocking")
        } else {
            check(false, "locked: document kept while locked")
        }
        // A stale document must not be unlocked into the current file's state.
        let stale = model.document
        await model.load(plain)
        if let stale { check(!model.unlock(stale, password: "secret"), "locked: stale document ignored") }
        check(model.phase == .loaded, "load: plain PDF after locked one", "\(model.phase)")

        // Never written back: loading and rotating in memory leaves the file unchanged.
        let before = try? Data(contentsOf: multi)
        if let doc = PDFDocument(url: multi) { doc.page(at: 0)?.rotation = 270 }
        check(before == (try? Data(contentsOf: multi)), "view rotation never touches the file")

        // Info panel.
        let info = await InfoPanelFileInfo.load(multi)
        check(info.pageCount == 3, "info: page count", "\(info.pageCount ?? -1)")
        check(info.pageSize.map { abs($0.width - 595) < 1 && abs($0.height - 842) < 1 } == true,
              "info: first page size 595 × 842 pt", "\(String(describing: info.pageSize))")
        let bleedInfo = await InfoPanelFileInfo.load(bleed)
        check(bleedInfo.pageSize.map { abs($0.width - 595) < 1 && abs($0.height - 842) < 1 } == true,
              "info: page size is the visible crop box, not the media box", "\(String(describing: bleedInfo.pageSize))")
        let lockedInfo = await InfoPanelFileInfo.load(locked)
        check(lockedInfo.pageSize == nil, "info: no page size for a locked PDF")
        check(InfoPanelView.formatPageSize(CGSize(width: 595.28, height: 841.89)).contains("×"), "info: page size text")

        // Folder listing includes PDFs (case-insensitive extension) with all formats on.
        let suite = SelfTest.makeSuiteName()
        defer { SelfTest.removeSuite(suite) }
        guard let defaults = UserDefaults(suiteName: suite) else {
            print("FAIL  cannot create preferences suite")
            return 1
        }
        let fresh = AppSettings(defaults: defaults)
        check(fresh.enabledFormatIDs.contains("pdf"), "settings: fresh install enables PDF")
        check(defaults.persistentDomain(forName: suite)?.isEmpty ?? true,
              "settings: reading settings writes nothing to an empty domain",
              "\(defaults.persistentDomain(forName: suite) ?? [:])")
        let listed = FolderBrowser.list(folder: root, settings: fresh).map(\.lastPathComponent)
        check(Set(listed) == ["multi.pdf", "plain.pdf", "locked.pdf", "broken.pdf", "bleed.pdf", "UPPER.PDF"],
              "listing: all PDFs listed", "\(listed)")

        // Migration: a selection saved by 1.1.x (no knownFormatIDs) gains PDF, keeps what was off.
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["jpeg", "png"], forKey: "enabledFormatIDs")
        let upgraded = AppSettings(defaults: defaults)
        check(upgraded.enabledFormatIDs == ["jpeg", "png", "pdf"], "settings: 1.1.x selection gains PDF only",
              "\(upgraded.enabledFormatIDs.sorted())")
        check(Set(defaults.array(forKey: "enabledFormatIDs") as? [String] ?? []) == ["jpeg", "png", "pdf"],
              "settings: merged selection saved")
        check(Set(defaults.array(forKey: "knownFormatIDs") as? [String] ?? [])
              == Set(FormatRegistry.all.map(\.id)), "settings: known formats recorded")
        // A selection saved by this version records the known formats, so PDF switched off stays off
        // even when the record was missing before.
        defaults.removePersistentDomain(forName: suite)
        let fresh2 = AppSettings(defaults: defaults)
        fresh2.enabledFormatIDs.remove("pdf")
        check(Set(defaults.array(forKey: "knownFormatIDs") as? [String] ?? []) == Set(FormatRegistry.all.map(\.id)),
              "settings: saving a selection records known formats")
        check(!AppSettings(defaults: defaults).enabledFormatIDs.contains("pdf"), "settings: fresh install, PDF off stays off")
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["jpeg", "png"], forKey: "enabledFormatIDs")
        let upgraded2 = AppSettings(defaults: defaults)
        // Turning PDF off afterwards sticks.
        upgraded2.enabledFormatIDs.remove("pdf")
        let again = AppSettings(defaults: defaults)
        check(!again.enabledFormatIDs.contains("pdf"), "settings: PDF switched off stays off")
        check(again.enabledFormatIDs == ["jpeg", "png"], "settings: other choices kept")
        let offListed = FolderBrowser.list(folder: root, settings: again)
        check(offListed.isEmpty, "listing: PDFs hidden when switched off", "\(offListed)")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    private static func makePDF(_ url: URL, pages: Int, size: CGSize) {
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: CGFloat(i % 3) / 2, green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 40, y: 40, width: size.width - 80, height: size.height / 3))
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

}
