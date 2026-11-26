import AppKit
import PDFKit

/// The PDFView used for every PDF. In view mode it behaves like a plain PDFView (text selection,
/// links); clicking a form field asks to enter edit mode. In edit mode the session's tool decides
/// what clicks and drags do; an overlay draws the selection handles and live previews.
@MainActor
final class PDFCanvasView: PDFView {
    weak var session: PDFEditSession? {
        didSet {
            overlay.needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// View mode: a click on a form field (fill it in) or a request from the context menu.
    var onRequestEdit: (() -> Void)?
    /// Set by the sidebar so page commands can act on the selected thumbnails.
    weak var thumbnailView: PDFThumbnailView?
    var thumbnailSelection: [PDFPage] { thumbnailView?.selectedPages ?? [] }
    /// Edit mode asks the panel to focus the selected item's text field.
    var onRequestTextEditing: (() -> Void)?

    private let overlay = PDFEditOverlay()
    private var scrollObserver: NSObjectProtocol?

    private enum Drag {
        case none
        case passThrough
        case move(PDFAnnotation, start: CGPoint, original: CGRect)
        case resize(PDFAnnotation, corner: Int, original: CGRect)
        case create(PDFTool, page: PDFPage, start: CGPoint)
        case ink(page: PDFPage, points: [CGPoint])
    }
    private var drag: Drag = .none

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.canvas = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep the overlay on top and redraw it while scrolling / zooming.
        if overlay.superview === self { addSubview(overlay, positioned: .above, relativeTo: nil) }
        if scrollObserver == nil, let clip = scrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.overlay.needsDisplay = true }
            }
        }
    }

    override func layout() {
        super.layout()
        overlay.needsDisplay = true
    }

    var scrollView: NSScrollView? {
        func find(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return find(self)
    }

    func selectionDidChange() { overlay.needsDisplay = true }

    func annotationsDidChange() {
        overlay.needsDisplay = true
        needsDisplay = true
        documentView?.needsDisplay = true
    }

    func requestTextEditing() { onRequestTextEditing?() }

    // MARK: - Geometry

    func pageAndPoint(for event: NSEvent) -> (PDFPage, CGPoint)? {
        let p = convert(event.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: true) else { return nil }
        return (page, convert(p, to: page))
    }

    /// Annotations we let people select and move (not form fields, links or popups).
    static func isEditable(_ a: PDFAnnotation) -> Bool {
        !["Widget", "Link", "Popup"].contains(a.type ?? "")
    }

    static func isResizable(_ a: PDFAnnotation) -> Bool {
        a is PDFImageStampAnnotation || ["Stamp", "Square", "Circle", "FreeText"].contains(a.type ?? "")
    }

    /// The selected annotation's rectangle in view coordinates.
    func viewRect(of a: PDFAnnotation) -> CGRect? {
        guard let page = a.page, document?.index(for: page) != NSNotFound else { return nil }
        return convert(a.bounds, from: page)
    }

    /// Handle squares at the four corners (view coordinates): 0 = bottom-left, 1 = bottom-right,
    /// 2 = top-right, 3 = top-left.
    static func handles(for r: CGRect) -> [CGRect] {
        let s: CGFloat = 8
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            .map { CGRect(x: $0.x - s / 2, y: $0.y - s / 2, width: s, height: s) }
    }

    private func topEditableAnnotation(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        page.annotations.reversed().first { a in
            guard Self.isEditable(a) else { return false }
            // Lines and ink: a loose hit box is fine; small notes get a minimum target.
            return a.bounds.insetBy(dx: -3, dy: -3).contains(point)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let session else {
            // View mode: clicking a form field switches to edit mode so it can be filled in.
            if let (page, point) = pageAndPoint(for: event),
               let a = page.annotation(at: point), a.type == "Widget", !a.isReadOnly {
                onRequestEdit?()
            }
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        guard let (page, point) = pageAndPoint(for: event) else { super.mouseDown(with: event); return }
        let viewPoint = convert(event.locationInWindow, from: nil)

        switch session.tool {
        case .select:
            // Resize handle of the current selection?
            if let sel = session.selected, Self.isResizable(sel), let r = viewRect(of: sel) {
                if let corner = Self.handles(for: r).firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(viewPoint) }) {
                    drag = .resize(sel, corner: corner, original: sel.bounds)
                    return
                }
            }
            if let a = topEditableAnnotation(on: page, at: point) {
                session.selected = a
                if event.clickCount == 2, a.type == "FreeText" || a.type == "Text" { requestTextEditing() }
                drag = .move(a, start: point, original: a.bounds)
                return
            }
            session.selected = nil
            drag = .passThrough
            super.mouseDown(with: event)   // text selection, links, form fields
        case .highlight, .underline, .strikeOut:
            // PDFView selects the text; the markup is applied once the selection is finished
            // (here if PDFView tracked the drag itself, else on mouse-up).
            drag = .passThrough
            super.mouseDown(with: event)
            applyMarkupToSelection()
        case .text:
            session.makeTextBox(at: point, on: page)
        case .note:
            session.makeNote(at: point, on: page)
        case .signature(let id):
            session.placeSignature(id, at: point, on: page)
        case .ink:
            drag = .ink(page: page, points: [point])
        case .rectangle, .oval, .line, .arrow:
            drag = .create(session.tool, page: page, start: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch drag {
        case .none:
            return
        case .passThrough:
            super.mouseDragged(with: event)
        case .move(let a, let start, let original):
            guard let page = a.page else { return }
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            a.bounds = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            annotationsDidChange()
        case .resize(let a, let corner, let original):
            guard let page = a.page else { return }
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            a.bounds = Self.resized(original, corner: corner, to: p,
                                    keepAspect: a is PDFImageStampAnnotation || a.type == "Stamp" || event.modifierFlags.contains(.shift))
            if a.type == "FreeText" { a.bounds.size.height = max(a.bounds.height, 14) }
            annotationsDidChange()
        case .create(let tool, let page, let start):
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            overlay.preview = .shape(tool, page: page, start: start, end: p)
        case .ink(let page, var points):
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 0.8 { return }
            points.append(p)
            drag = .ink(page: page, points: points)
            overlay.preview = .ink(page: page, points: points)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = .none
            overlay.preview = nil
        }
        guard let session else { super.mouseUp(with: event); return }
        switch drag {
        case .none:
            return
        case .passThrough:
            super.mouseUp(with: event)
            applyMarkupToSelection()
        case .move(let a, _, let original):
            session.commitBounds(of: a, from: original, name: "Move")
        case .resize(let a, _, let original):
            session.commitBounds(of: a, from: original, name: "Resize")
        case .create(let tool, let page, let start):
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            session.makeShape(tool, from: start, to: p, on: page)
        case .ink(let page, let points):
            session.makeInk(points, on: page)
        }
    }

    private func applyMarkupToSelection() {
        guard let session, session.tool.isTextMarkup, let sel = currentSelection,
              !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.markup(sel, as: session.tool)
        clearSelection()
    }

    static func resized(_ r: CGRect, corner: Int, to p: CGPoint, keepAspect: Bool) -> CGRect {
        // The corner opposite the dragged one stays put.
        let anchor: CGPoint
        switch corner {
        case 0: anchor = CGPoint(x: r.maxX, y: r.maxY)
        case 1: anchor = CGPoint(x: r.minX, y: r.maxY)
        case 2: anchor = CGPoint(x: r.minX, y: r.minY)
        default: anchor = CGPoint(x: r.maxX, y: r.minY)
        }
        var w = max(abs(p.x - anchor.x), 8), h = max(abs(p.y - anchor.y), 8)
        if keepAspect, r.width > 0, r.height > 0 {
            let aspect = r.height / r.width
            if h / w > aspect { w = h / aspect } else { h = w * aspect }
        }
        let x = p.x < anchor.x ? anchor.x - w : anchor.x
        let y = p.y < anchor.y ? anchor.y - h : anchor.y
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Cursor

    override func mouseMoved(with event: NSEvent) {
        guard let session, session.tool.isCreation else { super.mouseMoved(with: event); return }
        NSCursor.crosshair.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        if let session, session.tool.isCreation { NSCursor.crosshair.set() } else { super.cursorUpdate(with: event) }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if session == nil, onRequestEdit != nil {
            menu.insertItem(.separator(), at: 0)
            let edit = NSMenuItem(title: "Annotate, Sign or Fill In…", action: #selector(requestEditFromMenu), keyEquivalent: "")
            edit.target = self
            menu.insertItem(edit, at: 0)
        } else if let session, let (page, point) = pageAndPoint(for: event),
                  let a = topEditableAnnotation(on: page, at: point) {
            session.selected = a
            menu.insertItem(.separator(), at: 0)
            let del = NSMenuItem(title: "Delete \(Self.displayName(a))", action: #selector(deleteSelectedFromMenu), keyEquivalent: "")
            del.target = self
            menu.insertItem(del, at: 0)
        }
        return menu
    }

    @objc private func requestEditFromMenu() { onRequestEdit?() }
    @objc private func deleteSelectedFromMenu() { session?.deleteSelected() }

    static func displayName(_ a: PDFAnnotation) -> String {
        if a is PDFImageStampAnnotation || (a.type == "Stamp" && a.contents == "Signature") { return "Signature" }
        switch a.type ?? "" {
        case "FreeText": return "Text Box"
        case "Text": return "Note"
        case "Ink": return "Drawing"
        case "Square": return "Rectangle"
        case "Circle": return "Oval"
        case "Line": return a.endLineStyle == .openArrow || a.endLineStyle == .closedArrow ? "Arrow" : "Line"
        case "Highlight": return "Highlight"
        case "Underline": return "Underline"
        case "StrikeOut": return "Strikethrough"
        case "Stamp": return "Stamp"
        default: return "Annotation"
        }
    }
}

/// Transparent layer over the PDF view: selection outline and handles, and the shape / ink being
/// drawn. Never takes mouse events.
@MainActor
final class PDFEditOverlay: NSView {
    enum Preview {
        case shape(PDFTool, page: PDFPage, start: CGPoint, end: CGPoint)
        case ink(page: PDFPage, points: [CGPoint])
    }
    weak var canvas: PDFCanvasView?
    var preview: Preview? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let session = canvas.session else { return }
        // Canvas coordinates == ours (same frame, both unflipped).
        if let a = session.selected, let r = canvas.viewRect(of: a) {
            let outline = NSBezierPath(rect: r.insetBy(dx: -2, dy: -2))
            outline.lineWidth = 1.5
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
            if PDFCanvasView.isResizable(a) {
                for h in PDFCanvasView.handles(for: r) {
                    let p = NSBezierPath(rect: h)
                    NSColor.white.setFill(); p.fill()
                    NSColor.controlAccentColor.setStroke(); p.lineWidth = 1.5; p.stroke()
                }
            }
        }
        guard let preview else { return }
        let color = session.color
        let scale = canvas.scaleFactor
        switch preview {
        case .shape(let tool, let page, let start, let end):
            let s = canvas.convert(start, from: page), e = canvas.convert(end, from: page)
            let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y))
            let path: NSBezierPath
            switch tool {
            case .oval: path = NSBezierPath(ovalIn: rect)
            case .line, .arrow:
                path = NSBezierPath()
                path.move(to: s); path.line(to: e)
                if tool == .arrow {
                    let angle = atan2(e.y - s.y, e.x - s.x), len = max(10, session.lineWidth * scale * 4)
                    for d in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
                        path.move(to: e)
                        path.line(to: CGPoint(x: e.x + len * cos(angle + d), y: e.y + len * sin(angle + d)))
                    }
                }
            default: path = NSBezierPath(rect: rect)
            }
            path.lineWidth = session.lineWidth * scale
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        case .ink(let page, let points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: canvas.convert(first, from: page))
            for p in points.dropFirst() { path.line(to: canvas.convert(p, from: page)) }
            path.lineWidth = session.lineWidth * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
    }
}
