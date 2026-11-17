import SwiftUI
import AppKit

/// Media area while editing: the live preview (aspect-fit), the crop tool on top of it,
/// "Before" badge while comparing, scroll / pinch zoom and drag-to-pan when zoomed.
struct EditPreviewView: View {
    @ObservedObject var session: EditSession
    @ObservedObject var settings: AppSettings

    /// Zoom relative to "fit" (1 = fit), and pan offset of the image centre in points.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var magnifyStart: CGFloat?
    @State private var scrollTracker = ScrollZoomTracker()

    private static let margin: CGFloat = 24
    private static let maxZoom: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let area = CGRect(origin: .zero, size: geo.size).insetBy(dx: Self.margin, dy: Self.margin)
            ZStack(alignment: .topLeading) {
                ViewerPalette.background
                if let shown = shownImage {
                    let frame = imageFrame(pixelSize: shown.size, maxPoints: shown.maxPoints, area: area)
                    Image(decorative: shown.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                    if session.isCropping && !session.showingOriginal && shown.uncropped {
                        CropOverlayView(session: session, imageFrame: frame)
                    }
                }
                overlays
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(panGesture(area: area), including: session.isCropping ? .subviews : .all)
            .simultaneousGesture(magnifyGesture(area: area))
            .background(
                EditScrollCatcher { event, location in
                    handleScroll(event, at: location, area: area)
                }
            )
            .gesture(TapGesture(count: 2).onEnded { resetZoom() },
                     including: session.isCropping ? .subviews : .all)
            .onChange(of: session.isCropping) { resetZoom() }
            .onChange(of: session.recipe.rotationQuarterTurns) { resetZoom() }
        }
        .clipped()
    }

    // MARK: Image choice & layout

    private struct Shown {
        let image: CGImage
        let size: CGSize
        let maxPoints: CGSize
        let uncropped: Bool
    }

    private var shownImage: Shown? {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let fullScale = previewToFullScale
        if session.showingOriginal, let before = session.beforeImage {
            let size = CGSize(width: before.width, height: before.height)
            return Shown(image: before, size: size,
                         maxPoints: CGSize(width: size.width * fullScale / backing, height: size.height * fullScale / backing),
                         uncropped: true)
        }
        guard let frame = session.preview else { return nil }
        let size = CGSize(width: frame.image.width, height: frame.image.height)
        return Shown(image: frame.image, size: size,
                     maxPoints: CGSize(width: size.width * fullScale / backing, height: size.height * fullScale / backing),
                     uncropped: frame.uncropped)
    }

    /// Full-resolution pixels per preview pixel.
    private var previewToFullScale: CGFloat {
        guard let src = session.source, src.preview.extent.width > 0 else { return 1 }
        return max(src.full.extent.width / src.preview.extent.width, 1)
    }

    /// Aspect-fit (never larger than 100 %), then zoom + pan.
    private func imageFrame(pixelSize: CGSize, maxPoints: CGSize, area: CGRect) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, area.width > 0, area.height > 0 else { return .zero }
        var s = min(area.width / pixelSize.width, area.height / pixelSize.height)
        if maxPoints.width > 0 { s = min(s, max(maxPoints.width / pixelSize.width, 0.0001)) }
        let w = pixelSize.width * s * zoom
        let h = pixelSize.height * s * zoom
        let p = clampedPan(pan, size: CGSize(width: w, height: h), area: area)
        return CGRect(x: area.midX + p.width - w / 2, y: area.midY + p.height - h / 2, width: w, height: h)
    }

    private func fittedSize(area: CGRect) -> CGSize {
        guard let shown = shownImage else { return .zero }
        let r = imageFrame(pixelSize: shown.size, maxPoints: shown.maxPoints, area: area)
        return CGSize(width: r.width / zoom, height: r.height / zoom)
    }

    private func clampedPan(_ p: CGSize, size: CGSize, area: CGRect) -> CGSize {
        let maxX = max((size.width - area.width) / 2, 0)
        let maxY = max((size.height - area.height) / 2, 0)
        return CGSize(width: min(max(p.width, -maxX), maxX), height: min(max(p.height, -maxY), maxY))
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        if session.isLoading || session.preview == nil && session.errorMessage == nil {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if session.showingOriginal {
            Text("Before")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .top)
                .allowsHitTesting(false)
        } else if session.isCropping {
            Text("Drag the corners or edges · Return to apply · Esc to cancel")
                .font(.system(size: 11))
                .foregroundStyle(ViewerPalette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        } else if zoom > 1.001 {
            Text("\(Int((zoom * 100).rounded()))% of fit · double-click to fit")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(ViewerPalette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        }
    }

    // MARK: Zoom & pan

    private func resetZoom() {
        zoom = 1
        pan = .zero
    }

    private func setZoom(_ newZoom: CGFloat, anchor: CGPoint, area: CGRect) {
        let z = min(max(newZoom, 1), Self.maxZoom)
        guard z != zoom else { return }
        let fitted = fittedSize(area: area)
        // Keep the point under the cursor fixed.
        let center = CGPoint(x: area.midX + pan.width, y: area.midY + pan.height)
        let k = z / zoom
        let newCenter = CGPoint(x: anchor.x + (center.x - anchor.x) * k, y: anchor.y + (center.y - anchor.y) * k)
        zoom = z
        pan = clampedPan(CGSize(width: newCenter.x - area.midX, height: newCenter.y - area.midY),
                         size: CGSize(width: fitted.width * z, height: fitted.height * z), area: area)
    }

    private func handleScroll(_ event: NSEvent, at location: CGPoint, area: CGRect) -> Bool {
        guard !session.isCropping, shownImage != nil else { return false }
        switch scrollTracker.action(for: event, zoomsByDefault: settings.scrollWheelZooms) {
        case .zoom(let f):
            setZoom(zoom * f, anchor: location, area: area)
            return true
        case .pan:
            guard zoom > 1 else { return true }
            let fitted = fittedSize(area: area)
            pan = clampedPan(CGSize(width: pan.width + event.scrollingDeltaX, height: pan.height + event.scrollingDeltaY),
                             size: CGSize(width: fitted.width * zoom, height: fitted.height * zoom), area: area)
            return true
        case .ignore:
            return true
        }
    }

    private func panGesture(area: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard !session.isCropping, zoom > 1 else { return }
                if panStart == nil { panStart = pan }
                let fitted = fittedSize(area: area)
                let start = panStart ?? .zero
                pan = clampedPan(CGSize(width: start.width + g.translation.width, height: start.height + g.translation.height),
                                 size: CGSize(width: fitted.width * zoom, height: fitted.height * zoom), area: area)
            }
            .onEnded { _ in panStart = nil }
    }

    private func magnifyGesture(area: CGRect) -> some Gesture {
        MagnifyGesture()
            .onChanged { g in
                guard !session.isCropping else { return }
                if magnifyStart == nil { magnifyStart = zoom }
                let anchor = CGPoint(x: area.minX + g.startAnchor.x * area.width, y: area.minY + g.startAnchor.y * area.height)
                setZoom((magnifyStart ?? 1) * g.magnification, anchor: anchor, area: area)
            }
            .onEnded { _ in magnifyStart = nil }
    }
}

/// Catches scroll-wheel events over its area (a local monitor, so the SwiftUI content above
/// keeps receiving clicks and drags). The handler returns true to consume the event;
/// `location` is in top-left view coordinates.
struct EditScrollCatcher: NSViewRepresentable {
    let handler: (NSEvent, CGPoint) -> Bool

    final class CatcherView: NSView {
        var handler: ((NSEvent, CGPoint) -> Bool)?
        private var monitor: Any?
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                return (self.handler?(event, p) ?? false) ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.handler = handler
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.handler = handler }
}
