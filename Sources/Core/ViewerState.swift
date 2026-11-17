import Foundation
import Combine
import CoreGraphics

enum ZoomMode: Equatable {
    case fit                 // scale to fit the window (never upscale beyond 100%)
    case scale(CGFloat)      // 1.0 = actual pixels
}

/// Per-window view state shared between the toolbar (ViewerView) and the
/// content views (ImageCanvasView, SVGView). Reset when the file changes.
@MainActor
final class ViewerState: ObservableObject {
    @Published var zoom: ZoomMode = .fit
    /// Clockwise quarter turns, 0...3 (view-only rotation).
    @Published var rotationQuarterTurns: Int = 0
    /// Actual scale currently on screen, reported by the content view (for the "Fit"/"150%" label).
    @Published var effectiveScale: CGFloat = 1
    @Published var isSlideshowRunning = false
    @Published var showInfo = false

    static let zoomSteps: [CGFloat] = [0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16]

    func resetForNewItem() {
        zoom = .fit
        rotationQuarterTurns = 0
    }

    func zoomIn() {
        let cur = effectiveScale
        zoom = .scale(Self.zoomSteps.first { $0 > cur + 0.001 } ?? Self.zoomSteps.last!)
    }

    func zoomOut() {
        let cur = effectiveScale
        zoom = .scale(Self.zoomSteps.last { $0 < cur - 0.001 } ?? Self.zoomSteps.first!)
    }

    func actualSize() { zoom = .scale(1) }
    func fit() { zoom = .fit }
    func rotateLeft() { rotationQuarterTurns = (rotationQuarterTurns + 3) % 4 }
    func rotateRight() { rotationQuarterTurns = (rotationQuarterTurns + 1) % 4 }

    var zoomLabel: String {
        if zoom == .fit { return "Fit" }
        return "\(Int((effectiveScale * 100).rounded()))%"
    }
}
