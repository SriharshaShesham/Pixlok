import AppKit
import QuartzCore

// MARK: - Scroll-to-zoom

/// Pure math for scroll-wheel zoom (kept free of AppKit state so it can be tested headlessly).
///
/// Direction: "wheel rolled away from you / fingers pushed up" always zooms IN, whatever the
/// system's natural-scrolling setting. `scrollingDeltaY` is already flipped by macOS when
/// natural scrolling is on (`isDirectionInvertedFromDevice`), so we undo that flip to get the
/// physical direction.
enum ScrollZoomMath {
    /// Zoom per mouse-wheel line (one notch ≈ 10 %).
    static let lineFactor: CGFloat = 1.1
    /// Exponential rate per point of precise (trackpad / Magic Mouse) scroll.
    static let preciseRate: CGFloat = 0.005
    /// Per-event caps so one accelerated event can't jump the zoom.
    static let maxLines: CGFloat = 4
    static let maxPoints: CGFloat = 80

    /// Multiplicative zoom factor for one scroll event (>1 zooms in, <1 out, 1 = nothing).
    static func factor(deltaY: CGFloat, precise: Bool, inverted: Bool) -> CGFloat {
        guard deltaY.isFinite, deltaY != 0 else { return 1 }
        let physical = inverted ? -deltaY : deltaY   // > 0: wheel away / fingers up
        if precise {
            let d = min(max(physical, -maxPoints), maxPoints)
            return exp(d * preciseRate)
        }
        let d = min(max(physical, -maxLines), maxLines)
        return pow(lineFactor, d)
    }

    /// New visible-rect origin (document coordinates) that keeps `anchor` (document coordinates)
    /// at the same on-screen position when the scale changes from `oldScale` to `newScale`.
    static func anchoredOrigin(origin: CGPoint, anchor: CGPoint, oldScale: CGFloat, newScale: CGFloat) -> CGPoint {
        guard oldScale > 0, newScale > 0 else { return origin }
        let r = oldScale / newScale
        return CGPoint(x: anchor.x - (anchor.x - origin.x) * r,
                       y: anchor.y - (anchor.y - origin.y) * r)
    }

    /// Scroll-zoom target. Returns `.fit` when zooming out reaches the fit scale from above,
    /// `nil` when nothing should change, otherwise the clamped scale.
    /// - `minScale`/`maxScale`: range for scroll zoom (widened to include `fit` and `current`,
    ///   so after a pinch beyond the range a clamp can only stop a zoom, never reverse it).
    static func target(current: CGFloat, factor: CGFloat, fit: CGFloat, isFit: Bool,
                       minScale: CGFloat, maxScale: CGFloat) -> ZoomMode? {
        guard factor.isFinite, factor > 0, factor != 1, current > 0 else { return nil }
        let eps: CGFloat = 0.0005
        let lo = min(minScale, fit, current), hi = max(maxScale, fit, current)
        if factor < 1 {
            if isFit { return nil }                              // already as small as "fit" goes
            if current > fit + eps && current * factor <= fit + eps { return .fit }
        }
        let s = min(max(current * factor, lo), hi)
        guard abs(s - current) > 1e-6 else { return nil }
        return .scale(s)
    }
}

/// Per-view state that decides whether a scroll event zooms or pans. A trackpad gesture is
/// locked to one behaviour from its first non-zero event (horizontal-dominant → pan), and
/// the momentum that follows a zoom gesture is ignored so the zoom stops when the fingers lift.
@MainActor
final class ScrollZoomTracker {
    enum Action: Equatable {
        case zoom(CGFloat)
        case pan
        case ignore
    }

    private enum Mode { case zoom, pan }
    private var gestureMode: Mode?
    private var momentumMode: Mode?

    func action(for event: NSEvent, zoomsByDefault: Bool) -> Action {
        let mods = event.modifierFlags
        let forced = mods.contains(.command) || mods.contains(.option)
        return action(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                      precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice,
                      phase: event.phase, momentumPhase: event.momentumPhase,
                      forcedZoom: forced, zoomsByDefault: zoomsByDefault)
    }

    /// Testable core of `action(for:zoomsByDefault:)`.
    func action(deltaX: CGFloat, deltaY: CGFloat, precise: Bool, inverted: Bool,
                phase: NSEvent.Phase, momentumPhase: NSEvent.Phase,
                forcedZoom: Bool, zoomsByDefault: Bool) -> Action {
        // Momentum after the fingers lift: follow whatever the gesture did.
        if !momentumPhase.isEmpty {
            if momentumPhase.contains(.began) { momentumMode = gestureMode ?? momentumMode }
            let mode = momentumMode
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { momentumMode = nil }
            return mode == .zoom ? .ignore : .pan
        }

        let wantsZoom = forcedZoom || zoomsByDefault
        let zoomFactor = { ScrollZoomMath.factor(deltaY: deltaY, precise: precise, inverted: inverted) }

        // Phase-less events: classic mouse wheels (and some third-party devices). Decide per event.
        if phase.isEmpty {
            gestureMode = nil
            guard wantsZoom else { return .pan }
            if abs(deltaX) > abs(deltaY) && !forcedZoom { return .pan }   // shift-wheel / tilt wheel
            let f = zoomFactor()
            return f == 1 ? .ignore : .zoom(f)
        }

        if phase.contains(.began) || phase.contains(.mayBegin) {
            gestureMode = nil
            momentumMode = nil
        }
        let ending = phase.contains(.ended) || phase.contains(.cancelled)
        defer { if ending { momentumMode = gestureMode; gestureMode = nil } }

        if gestureMode == nil, deltaX != 0 || deltaY != 0 {
            if !wantsZoom { gestureMode = .pan }
            else if forcedZoom { gestureMode = .zoom }
            else { gestureMode = abs(deltaX) > abs(deltaY) ? .pan : .zoom }
        }
        // Zero-delta began/ended events move nothing; hand them to the scroll view so its
        // own gesture bookkeeping stays balanced whichever way the gesture goes.
        if deltaX == 0 && deltaY == 0 { return .pan }
        switch gestureMode {
        case .zoom?:
            let f = zoomFactor()
            return f == 1 ? .ignore : .zoom(f)
        case .pan?, nil:
            return .pan
        }
    }
}

/// Clip view that keeps a document smaller than the viewport centred.
final class ImageCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let frame = doc.frame
        if rect.width > frame.width { rect.origin.x = frame.midX - rect.width / 2 }
        if rect.height > frame.height { rect.origin.y = frame.midY - rect.height / 2 }
        return rect
    }
}

/// Draws a CGImage via its backing layer (fast GPU scaling, trilinear minification).
final class ImageLayerView: NSView {
    var cgImage: CGImage? { didSet { needsDisplay = true } }
    var usesNearestNeighbour = false { didSet { if oldValue != usesNearestNeighbour { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = cgImage
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = usesNearestNeighbour ? .nearest : .linear
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// NSImageView used for animated images; ignores the mouse so panning works.
final class ImageAnimatedView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Document view: sized to the (rotated) image in image pixels, so the scroll
/// view's magnification equals "screen points per image pixel".
final class ImageDocumentView: NSView {
    override var isFlipped: Bool { false }
}

/// Scroll view hosting the image. Magnification 1.0 = one image pixel per point.
final class ImageScrollView: NSScrollView {
    /// Called when the user zooms by gesture / wheel / double-click (new magnification),
    /// or with nil when the user toggles back to fit.
    var onUserZoom: ((ZoomMode) -> Void)?
    /// Called whenever the on-screen magnification changes.
    var onMagnificationChanged: ((CGFloat) -> Void)?

    let documentContainer = ImageDocumentView(frame: .zero)
    private let layerView = ImageLayerView(frame: .zero)
    private let animatedView: ImageAnimatedView = {
        let v = ImageAnimatedView(frame: .zero)
        v.imageScaling = .scaleAxesIndependently
        v.animates = true
        v.isEditable = false
        v.allowsCutCopyPaste = false
        return v
    }()

    private(set) var content: ImageContent?
    private(set) var quarterTurns = 0
    /// True while the zoom mode is "fit" (refit on resize).
    var isFitMode = true
    private var lastDragPoint: NSPoint?
    private var lastReportedMagnification: CGFloat = -1
    private let scrollTracker = ScrollZoomTracker()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let clip = ImageCenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        drawsBackground = true
        backgroundColor = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        usesPredominantAxisScrolling = false
        allowsMagnification = true
        minMagnification = 0.01
        maxMagnification = 32
        documentView = documentContainer
        documentContainer.addSubview(layerView)
        documentContainer.addSubview(animatedView)
        layerView.isHidden = true
        animatedView.isHidden = true

        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Content

    /// Size of the document in image pixels after view rotation.
    var rotatedPixelSize: CGSize {
        guard let size = content?.pixelSize else { return .zero }
        return quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// Installs new content. Returns true when the geometry changed (caller must re-apply zoom).
    @discardableResult
    func setContent(_ newContent: ImageContent?) -> Bool {
        let old = content
        guard old !== newContent else { return false }
        content = newContent
        let sameGeometry = old != nil && newContent != nil
            && old?.url == newContent?.url && old?.pixelSize == newContent?.pixelSize

        if let c = newContent {
            if let animated = c.animatedImage {
                layerView.cgImage = nil
                layerView.isHidden = true
                animatedView.image = animated
                animatedView.isHidden = false
            } else {
                animatedView.image = nil
                animatedView.isHidden = true
                layerView.cgImage = c.cgImage
                layerView.isHidden = false
            }
            let name = c.url.lastPathComponent
            documentContainer.setAccessibilityLabel(name)
            documentContainer.setAccessibilityRole(.image)
        } else {
            layerView.cgImage = nil
            animatedView.image = nil
            layerView.isHidden = true
            animatedView.isHidden = true
        }
        if !sameGeometry { layoutDocument() }
        return !sameGeometry
    }

    func setQuarterTurns(_ turns: Int) {
        let t = ((turns % 4) + 4) % 4
        guard t != quarterTurns else { return }
        quarterTurns = t
        layoutDocument()
        if !isFitMode { applyScale(magnification, recenter: true) }
    }

    private func layoutDocument() {
        let size = content?.pixelSize ?? .zero
        let rotated = rotatedPixelSize
        documentContainer.frame = NSRect(origin: .zero, size: rotated)
        let imageFrame = NSRect(x: (rotated.width - size.width) / 2, y: (rotated.height - size.height) / 2,
                                width: size.width, height: size.height)
        for view in [layerView, animatedView] as [NSView] {
            view.frameCenterRotation = 0
            view.frame = imageFrame
            // AppKit rotation is counter-clockwise for positive angles.
            view.frameCenterRotation = -90 * CGFloat(quarterTurns)
        }
    }

    // MARK: Zoom

    /// Scale that fits the rotated image in the viewport without upscaling.
    var fitMagnification: CGFloat {
        let doc = rotatedPixelSize
        let view = contentView.frame.size
        guard doc.width > 0, doc.height > 0, view.width > 0, view.height > 0 else { return 1 }
        return min(1, min(view.width / doc.width, view.height / doc.height))
    }

    func applyFit() {
        isFitMode = true
        let fit = fitMagnification
        minMagnification = min(0.01, fit * 0.5)
        setMagnification(fit, centeredAt: NSPoint(x: documentContainer.bounds.midX, y: documentContainer.bounds.midY))
        reportMagnification()
    }

    /// Zoom to `scale`, keeping the point at the viewport centre fixed
    /// (or the document centre when `recenter`).
    func applyScale(_ scale: CGFloat, recenter: Bool = false) {
        isFitMode = false
        let s = min(max(scale, 0.01), maxMagnification)
        minMagnification = min(minMagnification, s)
        let bounds = contentView.bounds
        let center = recenter
            ? NSPoint(x: documentContainer.bounds.midX, y: documentContainer.bounds.midY)
            : NSPoint(x: bounds.midX, y: bounds.midY)
        setMagnification(s, centeredAt: center)
        reportMagnification()
    }

    private func userZoom(to scale: CGFloat, at docPoint: NSPoint) {
        let s = min(max(scale, minMagnification), maxMagnification)
        isFitMode = false
        setMagnification(s, centeredAt: docPoint)
        reportMagnification()
        onUserZoom?(.scale(magnification))
    }

    private func toggleFit(at docPoint: NSPoint) {
        if isFitMode && abs(magnification - 1) > 0.001 {
            userZoom(to: 1, at: docPoint)
        } else {
            applyFit()
            onUserZoom?(.fit)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if isFitMode && content != nil { applyFit() }
    }

    @objc private func clipBoundsChanged(_ note: Notification) { reportMagnification() }

    @objc private func liveMagnifyEnded(_ note: Notification) {
        isFitMode = false
        reportMagnification()
        onUserZoom?(.scale(magnification))
    }

    private func reportMagnification() {
        let m = magnification
        layerView.usesNearestNeighbour = m >= 3
        guard abs(m - lastReportedMagnification) > 0.0001 else { return }
        lastReportedMagnification = m
        onMagnificationChanged?(m)
    }

    // MARK: Events

    override func scrollWheel(with event: NSEvent) {
        switch scrollTracker.action(for: event, zoomsByDefault: AppSettings.shared.scrollWheelZooms) {
        case .pan:
            super.scrollWheel(with: event)
        case .ignore:
            break
        case .zoom(let factor):
            scrollZoom(by: factor, atWindowPoint: event.locationInWindow)
        }
    }

    /// Zoom by `factor`, keeping the image point under `windowPoint` under the cursor.
    /// Zooming out to the fit size snaps back to fit (image recentred).
    func scrollZoom(by factor: CGFloat, atWindowPoint windowPoint: NSPoint) {
        guard content != nil else { return }
        let current = magnification
        let fit = fitMagnification
        guard let target = ScrollZoomMath.target(
            current: current, factor: factor, fit: fit, isFit: isFitMode,
            minScale: ViewerState.zoomSteps.first ?? 0.05,
            maxScale: min(ViewerState.zoomSteps.last ?? 16, maxMagnification)) else { return }
        switch target {
        case .fit:
            applyFit()
            onUserZoom?(.fit)
        case .scale(let s):
            let anchor = documentContainer.convert(windowPoint, from: nil)
            let bounds = contentView.bounds
            let origin = ScrollZoomMath.anchoredOrigin(origin: bounds.origin, anchor: anchor,
                                                       oldScale: current, newScale: s)
            isFitMode = false
            minMagnification = min(minMagnification, s)
            magnification = s
            let size = contentView.bounds.size
            let constrained = contentView.constrainBoundsRect(NSRect(origin: origin, size: size))
            contentView.scroll(to: constrained.origin)
            reflectScrolledClipView(contentView)
            reportMagnification()
            onUserZoom?(.scale(magnification))
        }
    }

    override func smartMagnify(with event: NSEvent) {
        toggleFit(at: documentContainer.convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            toggleFit(at: documentContainer.convert(event.locationInWindow, from: nil))
            lastDragPoint = nil
            return
        }
        lastDragPoint = event.locationInWindow
        if canPan { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragPoint, canPan else { return }
        let p = event.locationInWindow
        lastDragPoint = p
        let m = max(magnification, 0.0001)
        var origin = contentView.bounds.origin
        origin.x -= (p.x - last.x) / m
        origin.y -= (p.y - last.y) / m
        let constrained = contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size))
        contentView.scroll(to: constrained.origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if lastDragPoint != nil && canPan { NSCursor.pop() }
        lastDragPoint = nil
    }

    private var canPan: Bool {
        let doc = documentContainer.frame.size
        let visible = contentView.bounds.size
        return doc.width > visible.width + 0.5 || doc.height > visible.height + 0.5
    }

}
