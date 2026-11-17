import SwiftUI
import AppKit

/// Crop tool drawn over the (geometry-transformed, uncropped) preview.
/// `imageFrame` is where the image is drawn, in this view's coordinates.
/// Dark scrim outside the crop, rule-of-thirds lines, 8 handles, drag inside to move.
struct CropOverlayView: View {
    @ObservedObject var session: EditSession
    let imageFrame: CGRect

    @State private var dragStart: CGRect?
    @State private var activeHandle: CropHandle?

    private static let minSize: CGFloat = 32
    private static let hitSize: CGFloat = 26

    private var cropRect: CGRect { CropGeometry.toView(session.draftCrop, in: imageFrame) }

    /// Ratio expressed in view points (the image is drawn undistorted, so it equals the pixel ratio).
    private var ratio: CGFloat? { session.cropRatio }

    var body: some View {
        let rect = cropRect
        ZStack(alignment: .topLeading) {
            // Scrim over the image outside the crop rect.
            Path { p in
                p.addRect(imageFrame)
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Thirds + border.
            Path { p in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                    p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(activeHandle == nil ? 0.35 : 0.6), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)

            // Move area (inside, minus the handle zones which sit on top).
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
                .gesture(dragGesture(.move))
                // Cursors are set (never pushed/popped): handles sit on top and re-set their own
                // cursor on every move, so overlapping enter/exit order can't leave a stale one.
                .onContinuousHover { phase in
                    guard activeHandle == nil else { return }
                    switch phase {
                    case .active: NSCursor.openHand.set()
                    case .ended: NSCursor.arrow.set()
                    }
                }

            ForEach(CropHandle.allCases.filter { $0 != .move }, id: \.self) { handle in
                handleView(handle, in: rect)
            }

            sizeLabel(rect)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onContinuousHover { phase in
            if case .ended = phase, activeHandle == nil { NSCursor.arrow.set() }
        }
        // Return / Esc / Apply Crop / leaving edit mode with the pointer inside the crop.
        .onDisappear { NSCursor.arrow.set() }
    }

    // MARK: Handles

    @ViewBuilder
    private func handleView(_ handle: CropHandle, in rect: CGRect) -> some View {
        let u = handle.unitPoint
        let center = CGPoint(x: rect.minX + rect.width * u.x, y: rect.minY + rect.height * u.y)
        ZStack {
            if handle.isCorner {
                CornerMark(handle: handle)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.5), radius: 1)
            } else {
                let horizontal = handle == .top || handle == .bottom
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white)
                    .frame(width: horizontal ? 20 : 4, height: horizontal ? 4 : 20)
                    .shadow(color: .black.opacity(0.5), radius: 1)
            }
        }
        .frame(width: Self.hitSize, height: Self.hitSize)
        .contentShape(Rectangle())
        .position(center)
        .gesture(dragGesture(handle))
        .onContinuousHover { phase in
            if case .active = phase, activeHandle == nil || activeHandle == handle { cursor(for: handle).set() }
        }
    }

    private func cursor(for handle: CropHandle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .move: return .openHand
        default: return .crosshair
        }
    }

    private func dragGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragStart == nil {
                    dragStart = cropRect
                    activeHandle = handle
                    if handle == .move { NSCursor.closedHand.set() }
                }
                guard let start = dragStart else { return }
                let bounds = imageFrame
                let minSize = min(Self.minSize, bounds.width, bounds.height)
                let r = CropGeometry.drag(handle, start: start, translation: g.translation,
                                          bounds: bounds, ratio: ratio, minSize: minSize)
                session.draftCrop = CropGeometry.toNormalized(r, in: bounds)
            }
            .onEnded { _ in
                dragStart = nil
                activeHandle = nil
                // The next hover event re-sets the cursor for whatever region is under the pointer.
                cursor(for: handle).set()
            }
    }

    // MARK: Size label

    @ViewBuilder
    private func sizeLabel(_ rect: CGRect) -> some View {
        if activeHandle != nil {
            let g = session.geometryPixelSize
            let w = Int((session.draftCrop.width * g.width).rounded())
            let h = Int((session.draftCrop.height * g.height).rounded())
            Text(verbatim: "\(w) × \(h)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .fixedSize()
                .position(x: rect.midX, y: max(rect.minY - 16, imageFrame.minY + 12))
                .allowsHitTesting(false)
        }
    }
}

/// L-shaped corner mark pointing into the crop rect.
private struct CornerMark: Shape {
    let handle: CropHandle
    func path(in r: CGRect) -> Path {
        // Corner of the mark sits on the rect corner = centre of `r`.
        let c = CGPoint(x: r.midX, y: r.midY)
        let len = r.width / 2 + 4
        let dx: CGFloat = handle.movesLeft ? 1 : -1
        let dy: CGFloat = handle.movesTop ? 1 : -1
        var p = Path()
        p.move(to: CGPoint(x: c.x + dx * len, y: c.y))
        p.addLine(to: c)
        p.addLine(to: CGPoint(x: c.x, y: c.y + dy * len))
        return p
    }
}
