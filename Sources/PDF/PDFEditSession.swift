import AppKit
import PDFKit
import UniformTypeIdentifiers

/// What a click/drag on the page does in PDF edit mode.
enum PDFTool: Hashable {
    case select
    case highlight, underline, strikeOut
    case text, note
    case ink, rectangle, oval, line, arrow
    case signature(UUID)

    var isTextMarkup: Bool { self == .highlight || self == .underline || self == .strikeOut }
    /// Tools that place something with a click or drag (crosshair cursor, no text selection).
    var isCreation: Bool { self != .select && !isTextMarkup }

    static let markupTools: [PDFTool] = [.highlight, .underline, .strikeOut]
    static let drawTools: [PDFTool] = [.text, .note, .ink, .rectangle, .oval, .line, .arrow]

    var label: String {
        switch self {
        case .select: return "Select"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeOut: return "Strikethrough"
        case .text: return "Text box"
        case .note: return "Note"
        case .ink: return "Draw"
        case .rectangle: return "Rectangle"
        case .oval: return "Oval"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .signature: return "Signature"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        case .text: return "character.textbox"
        case .note: return "note.text"
        case .ink: return "scribble"
        case .rectangle: return "rectangle"
        case .oval: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .signature: return "signature"
        }
    }
}

/// A placed signature (or any picture): drawn by us, and saved by PDFKit as the annotation's
/// appearance stream, so other PDF apps show it too. Counter-rotated on rotated pages so it
/// appears upright the way it was placed.
final class PDFImageStampAnnotation: PDFAnnotation {
    let image: CGImage

    init(image: CGImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let rotation = page?.rotation ?? 0
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: CGFloat(rotation) * .pi / 180)
        let upright = rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: -upright.width / 2, y: -upright.height / 2,
                                       width: upright.width, height: upright.height))
        context.restoreGState()
    }
}

/// Per-window PDF editing state: the live document (edited in memory, written on Save), the
/// current tool and style, the selected annotation, undo, and document settings.
@MainActor
final class PDFEditSession: ObservableObject {
    let url: URL
    let document: PDFDocument
    /// The password the file was unlocked with; the saved file keeps it unless changed.
    let openPassword: String?
    weak var pdfView: PDFCanvasView?
    let undoManager = UndoManager()

    @Published var tool: PDFTool = .select { didSet { if tool != .select { selected = nil } } }
    /// Colour per kind of tool: highlights yellow, text black, drawings and shapes red.
    @Published var markupColorIndex = 0
    @Published var textColorIndex = 5
    @Published var drawColorIndex = 1
    /// The colour the tool row shows and new items use, for the current tool.
    var colorIndex: Int {
        get { tool.isTextMarkup ? markupColorIndex : (tool == .text ? textColorIndex : drawColorIndex) }
        set {
            if tool.isTextMarkup { markupColorIndex = newValue }
            else if tool == .text { textColorIndex = newValue }
            else { drawColorIndex = newValue }
        }
    }
    @Published var lineWidth: CGFloat = 2
    @Published var fontSize: CGFloat = 14
    @Published var selected: PDFAnnotation? { didSet { pdfView?.selectionDidChange() } }
    /// Bumped whenever an annotation's properties change, so the inspector refreshes.
    @Published private(set) var revision = 0
    @Published private(set) var changeCount = 0
    @Published var isSaving = false
    @Published var errorMessage: String?
    /// Text for the next text box (e.g. today's date); nil → "Text".
    var pendingText: String?
    /// Typing not yet recorded as an undo step still counts as an unsaved change.
    private var hasLiveTextEdits = false

    // Document settings (applied when saving).
    @Published var title: String
    @Published var author: String
    @Published var subject: String
    @Published var keywords: String
    enum PasswordChange: Equatable { case keep, set(String), remove }
    @Published var passwordChange: PasswordChange = .keep

    private let initialMetadata: [String]
    private let initialFormState: [String]
    private let wasEncrypted: Bool

    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),   // yellow
        NSColor(srgbRed: 0.93, green: 0.23, blue: 0.20, alpha: 1),   // red
        NSColor(srgbRed: 0.20, green: 0.48, blue: 0.96, alpha: 1),   // blue
        NSColor(srgbRed: 0.20, green: 0.70, blue: 0.35, alpha: 1),   // green
        NSColor(srgbRed: 0.60, green: 0.35, blue: 0.85, alpha: 1),   // purple
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1),   // black
    ]
    var color: NSColor { Self.palette[colorIndex] }
    /// Highlights default to yellow; ink/shapes/text default to red/black looks wrong on yellow,
    /// so the colour is simply whatever is picked.

    init(url: URL, document: PDFDocument, password: String?) {
        self.url = url
        self.document = document
        self.openPassword = password
        let attrs = document.documentAttributes ?? [:]
        let t = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        let a = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""
        let su = attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        let k = (attrs[PDFDocumentAttribute.keywordsAttribute] as? [String])?.joined(separator: ", ")
            ?? attrs[PDFDocumentAttribute.keywordsAttribute] as? String ?? ""
        title = t; author = a; subject = su; keywords = k
        initialMetadata = [t, a, su, k]
        wasEncrypted = document.isEncrypted
        initialFormState = Self.formState(of: document)
    }

    // MARK: - State

    var isDirty: Bool {
        changeCount != 0 || hasLiveTextEdits || passwordChange != .keep
            || [title, author, subject, keywords] != initialMetadata
            || Self.formState(of: document) != initialFormState
    }

    var isEncrypted: Bool {
        switch passwordChange {
        case .keep: return wasEncrypted
        case .set: return true
        case .remove: return false
        }
    }

    /// Values of every form field, to notice fields filled in directly in the PDF view.
    private static func formState(of doc: PDFDocument) -> [String] {
        var out: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.type == "Widget" {
                out.append("\(i)|\(a.fieldName ?? "")|\(a.widgetStringValue ?? "")|\(a.buttonWidgetState.rawValue)")
            }
        }
        return out
    }

    // MARK: - Undo

    /// Runs `apply` now and registers `revert` for ⌘Z (and `apply` again for ⇧⌘Z).
    func perform(_ name: String, apply: @escaping () -> Void, revert: @escaping () -> Void) {
        apply()
        changeCount += 1
        revision += 1
        register(name, undo: revert, redo: apply, delta: -1)
    }

    private func register(_ name: String, undo: @escaping () -> Void, redo: @escaping () -> Void, delta: Int) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { s in
            undo()
            s.changeCount += delta
            s.revision += 1
            s.register(name, undo: redo, redo: undo, delta: -delta)
            s.pdfView?.annotationsDidChange()
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        pdfView?.annotationsDidChange()
    }

    // MARK: - Annotations

    func add(_ annotation: PDFAnnotation, to page: PDFPage, name: String, select: Bool = true) {
        perform(name, apply: { [weak self] in
            page.addAnnotation(annotation)
            if select { self?.selected = annotation }
        }, revert: { [weak self] in
            if self?.selected === annotation { self?.selected = nil }
            page.removeAnnotation(annotation)
        })
    }

    func deleteSelected() {
        guard let a = selected, let page = a.page else { return }
        perform("Delete", apply: { [weak self] in
            if self?.selected === a { self?.selected = nil }
            page.removeAnnotation(a)
        }, revert: { page.addAnnotation(a) })
    }

    /// Final position after a drag/resize (the live drag already moved it; this records undo).
    func commitBounds(of a: PDFAnnotation, from old: CGRect, name: String) {
        let new = a.bounds
        guard new != old else { return }
        perform(name, apply: { a.bounds = new }, revert: { a.bounds = old })
    }

    /// Live typing: updates the annotation without an undo step (see `commitContents`).
    func liveSetContents(_ text: String, of a: PDFAnnotation) {
        guard text != (a.contents ?? "") else { return }
        hasLiveTextEdits = true
        a.contents = text
        fitFreeText(a)
        pdfView?.annotationsDidChange()
    }

    /// Records one undo step for a finished text edit that started from `old`.
    func commitContents(of a: PDFAnnotation, from old: String) {
        let text = a.contents ?? ""
        guard text != old else { return }
        perform("Edit Text", apply: { [weak self] in
            a.contents = text
            self?.fitFreeText(a)
        }, revert: { [weak self] in
            a.contents = old
            self?.fitFreeText(a)
        })
    }

    func setContents(_ text: String, of a: PDFAnnotation) {
        let old = a.contents ?? ""
        guard text != old else { return }
        perform("Edit Text", apply: { [weak self] in
            a.contents = text
            self?.fitFreeText(a)
        }, revert: { [weak self] in
            a.contents = old
            self?.fitFreeText(a)
        })
    }

    func setColor(_ index: Int, of a: PDFAnnotation) {
        let new = Self.palette[index]
        let isText = a.type == "FreeText"
        let old = isText ? (a.fontColor ?? .black) : a.color
        perform("Change Color", apply: {
            if isText { a.fontColor = new } else { a.color = Self.styled(new, for: a.type) }
        }, revert: {
            if isText { a.fontColor = old } else { a.color = old }
        })
    }

    func setFontSize(_ size: CGFloat, of a: PDFAnnotation) {
        guard a.type == "FreeText", let font = a.font, abs(font.pointSize - size) > 0.01 else { return }
        let old = font
        let new = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        perform("Change Font Size", apply: { [weak self] in
            a.font = new
            self?.fitFreeText(a)
        }, revert: { [weak self] in
            a.font = old
            self?.fitFreeText(a)
        })
    }

    func setLineWidth(_ width: CGFloat, of a: PDFAnnotation) {
        guard Self.hasStroke(a.type) else { return }
        let old = a.border?.lineWidth ?? 1
        guard abs(old - width) > 0.01 else { return }
        perform("Change Line Width", apply: { a.border = Self.border(width) },
                revert: { a.border = Self.border(old) })
    }

    /// Grows/shrinks a text box to fit its text (keeps the top-left corner).
    func fitFreeText(_ a: PDFAnnotation) {
        guard a.type == "FreeText" else { return }
        let size = Self.freeTextSize(a.contents ?? "", font: a.font ?? .systemFont(ofSize: fontSize))
        let top = a.bounds.maxY
        a.bounds = CGRect(x: a.bounds.minX, y: top - size.height, width: size.width, height: size.height)
    }

    static func freeTextSize(_ text: String, font: NSFont) -> CGSize {
        let measured = (text.isEmpty ? " " : text as NSString).boundingRect(
            with: CGSize(width: 600, height: 10_000), options: [.usesLineFragmentOrigin],
            attributes: [.font: font])
        return CGSize(width: ceil(measured.width) + 12, height: ceil(measured.height) + 8)
    }

    static func border(_ width: CGFloat) -> PDFBorder {
        let b = PDFBorder()
        b.lineWidth = width
        return b
    }

    static func hasStroke(_ type: String?) -> Bool {
        ["Ink", "Square", "Circle", "Line"].contains(type ?? "")
    }

    /// Markup colours are see-through so the text stays readable.
    static func styled(_ color: NSColor, for type: String?) -> NSColor {
        type == "Highlight" ? color.withAlphaComponent(0.45) : color
    }

    // MARK: - Creating annotations

    /// Highlight / underline / strike the text in `selection`, one annotation per line.
    func markup(_ selection: PDFSelection, as tool: PDFTool) {
        let type: PDFAnnotationSubtype
        switch tool {
        case .highlight: type = .highlight
        case .underline: type = .underline
        case .strikeOut: type = .strikeOut
        default: return
        }
        var made: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                let a = PDFAnnotation(bounds: r, forType: type, withProperties: nil)
                a.color = Self.styled(color, for: a.type)
                a.quadrilateralPoints = [
                    NSValue(point: NSPoint(x: 0, y: r.height)), NSValue(point: NSPoint(x: r.width, y: r.height)),
                    NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: r.width, y: 0)),
                ]
                made.append((page, a))
            }
        }
        guard !made.isEmpty else { return }
        perform(tool.label, apply: { made.forEach { $0.0.addAnnotation($0.1) } },
                revert: { made.forEach { $0.0.removeAnnotation($0.1) } })
    }

    func makeTextBox(at point: CGPoint, on page: PDFPage) {
        let text = pendingText ?? "Text"
        pendingText = nil
        let font = NSFont(name: "Helvetica", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let size = Self.freeTextSize(text, font: font)
        let a = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height),
                              forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = font
        a.fontColor = Self.palette[textColorIndex]
        a.color = .clear
        a.border = Self.border(0)
        add(a, to: page, name: "Add Text")
        tool = .select
        selected = a
        pdfView?.requestTextEditing()
    }

    func makeNote(at point: CGPoint, on page: PDFPage) {
        let a = PDFAnnotation(bounds: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20),
                              forType: .text, withProperties: nil)
        a.iconType = .comment
        a.color = color
        a.contents = ""
        add(a, to: page, name: "Add Note")
        tool = .select
        selected = a
        pdfView?.requestTextEditing()
    }

    /// `points` in page space.
    func makeInk(_ points: [CGPoint], on page: PDFPage) {
        guard points.count > 1 else { return }
        let pad = lineWidth + 2
        let box = Self.boundingBox(points).insetBy(dx: -pad, dy: -pad)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: points[0].x - box.minX, y: points[0].y - box.minY))
        for p in points.dropFirst() { path.line(to: CGPoint(x: p.x - box.minX, y: p.y - box.minY)) }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let a = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
        a.add(path)
        a.color = color
        a.border = Self.border(lineWidth)
        add(a, to: page, name: "Draw", select: false)
    }

    func makeShape(_ tool: PDFTool, from start: CGPoint, to end: CGPoint, on page: PDFPage) {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch tool {
        case .rectangle, .oval:
            guard rect.width > 3, rect.height > 3 else { return }
            let a = PDFAnnotation(bounds: rect, forType: tool == .oval ? .circle : .square, withProperties: nil)
            a.color = color
            a.border = Self.border(lineWidth)
            add(a, to: page, name: tool.label, select: false)
        case .line, .arrow:
            guard hypot(end.x - start.x, end.y - start.y) > 4 else { return }
            let pad = lineWidth * 4 + 4
            let box = rect.insetBy(dx: -pad, dy: -pad)
            let a = PDFAnnotation(bounds: box, forType: .line, withProperties: nil)
            a.startPoint = CGPoint(x: start.x - box.minX, y: start.y - box.minY)
            a.endPoint = CGPoint(x: end.x - box.minX, y: end.y - box.minY)
            a.endLineStyle = tool == .arrow ? .openArrow : .none
            a.color = color
            a.border = Self.border(lineWidth)
            add(a, to: page, name: tool.label, select: false)
        default:
            break
        }
    }

    /// Places a signature centred on `point`, 160pt wide (or less on small pages), upright as seen.
    func placeSignature(_ id: UUID, at point: CGPoint, on page: PDFPage, store: SignatureStore? = nil) {
        guard let sig = (store ?? .shared).signature(id), let image = sig.cgImage else { return }
        let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
        let pageBox = page.bounds(for: .cropBox)
        var w: CGFloat = min(160, pageBox.width * 0.4)
        var h = w * aspect
        if h > 90 { h = 90; w = h / aspect }
        let size = page.rotation % 180 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        let a = PDFImageStampAnnotation(image: image, bounds: rect)
        a.contents = "Signature"
        add(a, to: page, name: "Add Signature")
        tool = .select
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        var r = CGRect(origin: points[0], size: .zero)
        for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    // MARK: - Pages

    /// Pages the page commands act on: the thumbnails' selection, else the current page.
    var targetPages: [PDFPage] {
        let chosen = pdfView?.thumbnailSelection ?? []
        if !chosen.isEmpty { return chosen.sorted { document.index(for: $0) < document.index(for: $1) } }
        return pdfView?.currentPage.map { [$0] } ?? []
    }

    var currentIndex: Int { pdfView?.currentPage.map { document.index(for: $0) } ?? 0 }

    func rotatePages(clockwise: Bool) {
        let pages = targetPages
        guard !pages.isEmpty else { return }
        let delta = clockwise ? 90 : 270
        perform(clockwise ? "Rotate Right" : "Rotate Left", apply: {
            pages.forEach { $0.rotation = ($0.rotation + delta) % 360 }
        }, revert: {
            pages.forEach { $0.rotation = ($0.rotation + 360 - delta) % 360 }
        })
        pdfView?.layoutDocumentView()
    }

    func deletePages() {
        let pages = targetPages
        guard !pages.isEmpty, pages.count < document.pageCount else { NSSound.beep(); return }
        let doc = document
        let indexed = pages.map { (doc.index(for: $0), $0) }.sorted { $0.0 < $1.0 }
        selected = nil
        perform(pages.count == 1 ? "Delete Page" : "Delete Pages", apply: {
            for (i, _) in indexed.reversed() { doc.removePage(at: i) }
        }, revert: {
            for (i, p) in indexed { doc.insert(p, at: min(i, doc.pageCount)) }
        })
    }

    func movePage(by offset: Int) {
        guard let page = pdfView?.currentPage else { return }
        let doc = document
        let from = doc.index(for: page), to = from + offset
        guard to >= 0, to < doc.pageCount else { NSSound.beep(); return }
        perform("Move Page", apply: { doc.exchangePage(at: from, withPageAt: to) },
                revert: { doc.exchangePage(at: from, withPageAt: to) })
        pdfView?.go(to: page)
    }

    func insertBlankPage() {
        let size = pdfView?.currentPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: size.size), for: .mediaBox)
        insert([page], name: "Insert Page")
    }

    func duplicatePages() {
        let copies = targetPages.compactMap { $0.copy() as? PDFPage }
        insert(copies, name: "Duplicate Page")
    }

    /// Inserts pages from PDFs and images after the current page.
    func insertPages(from urls: [URL]) {
        var pages: [PDFPage] = []
        for u in urls {
            if let doc = PDFDocument(url: u), !doc.isLocked {
                for i in 0..<doc.pageCount { if let p = doc.page(at: i)?.copy() as? PDFPage { pages.append(p) } }
            } else if let image = NSImage(contentsOf: u), let p = PDFPage(image: image) {
                pages.append(p)
            }
        }
        guard !pages.isEmpty else {
            errorMessage = "Those files couldn’t be read as PDFs or pictures (or a PDF is password-protected)."
            return
        }
        insert(pages, name: pages.count == 1 ? "Insert Page" : "Insert Pages")
    }

    private func insert(_ pages: [PDFPage], name: String) {
        guard !pages.isEmpty else { return }
        let doc = document
        let at = currentIndex + 1
        perform(name, apply: {
            for (k, p) in pages.enumerated() { doc.insert(p, at: min(at + k, doc.pageCount)) }
        }, revert: {
            for p in pages { let i = doc.index(for: p); if i != NSNotFound, i < doc.pageCount { doc.removePage(at: i) } }
        })
        pdfView?.go(to: pages[0])
    }

    /// A new PDF holding copies of the target pages (for "Extract Pages…").
    func extractedDocument() -> PDFDocument {
        let out = PDFDocument()
        for (k, p) in targetPages.enumerated() {
            if let c = p.copy() as? PDFPage { out.insert(c, at: k) }
        }
        return out
    }

    // MARK: - Writing

    struct WriteOptions {
        var flatten = false
        var ocr = false
        var optimizeImages = false
    }

    /// The document's bytes with metadata, password and options applied.
    func renderedData(_ options: WriteOptions = WriteOptions()) -> Data? {
        var attrs = document.documentAttributes ?? [:]
        func put(_ key: PDFDocumentAttribute, _ value: String) {
            if value.trimmingCharacters(in: .whitespaces).isEmpty { attrs.removeValue(forKey: key) } else { attrs[key] = value }
        }
        put(.titleAttribute, title)
        put(.authorAttribute, author)
        put(.subjectAttribute, subject)
        let kw = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if kw.isEmpty { attrs.removeValue(forKey: PDFDocumentAttribute.keywordsAttribute) } else { attrs[PDFDocumentAttribute.keywordsAttribute] = kw }
        attrs[PDFDocumentAttribute.modificationDateAttribute] = Date()
        attrs[PDFDocumentAttribute.producerAttribute] = "Pixlok (macOS PDFKit)"
        document.documentAttributes = attrs

        var opts: [PDFDocumentWriteOption: Any] = [:]
        switch passwordChange {
        case .keep:
            // No options: PDFKit keeps the file's own encryption (user password, owner password
            // and permissions) exactly as it was.
            break
        case .set(let p):
            opts[.userPasswordOption] = p
            opts[.ownerPasswordOption] = p
        case .remove:
            // Empty passwords: the file opens without asking and allows everything.
            opts[.userPasswordOption] = ""
            opts[.ownerPasswordOption] = ""
        }
        if options.flatten { opts[.burnInAnnotationsOption] = true }
        if options.ocr { opts[.saveTextFromOCROption] = true }
        if options.optimizeImages { opts[.optimizeImagesForScreenOption] = true }
        let previous = selected
        selected = nil
        defer { selected = previous }
        return document.dataRepresentation(options: opts)
    }
}
