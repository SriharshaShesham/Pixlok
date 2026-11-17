import CoreGraphics

/// Which part of the crop rectangle is being dragged.
enum CropHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// Position on a rect (unit coordinates, top-left origin).
    var unitPoint: CGPoint {
        CGPoint(x: movesLeft ? 0 : (movesRight ? 1 : 0.5), y: movesTop ? 0 : (movesBottom ? 1 : 0.5))
    }
}

/// Pure crop-drag math in view points (top-left origin). `bounds` is the image rect,
/// `ratio` = width/height to keep (nil = free), `minSize` the smallest edge.
enum CropGeometry {
    static func drag(_ handle: CropHandle, start r0: CGRect, translation t: CGSize,
                     bounds b: CGRect, ratio: CGFloat?, minSize: CGFloat) -> CGRect {
        if handle == .move {
            var r = r0.offsetBy(dx: t.width, dy: t.height)
            r.origin.x = min(max(r.minX, b.minX), b.maxX - r.width)
            r.origin.y = min(max(r.minY, b.minY), b.maxY - r.height)
            return r
        }
        let minW = min(minSize, b.width)
        let minH = min(minSize, b.height)
        guard let ratio, ratio > 0 else {
            var minX = r0.minX, maxX = r0.maxX, minY = r0.minY, maxY = r0.maxY
            if handle.movesLeft { minX = min(max(r0.minX + t.width, b.minX), maxX - minW) }
            if handle.movesRight { maxX = max(min(r0.maxX + t.width, b.maxX), minX + minW) }
            if handle.movesTop { minY = min(max(r0.minY + t.height, b.minY), maxY - minH) }
            if handle.movesBottom { maxY = max(min(r0.maxY + t.height, b.maxY), minY + minH) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        // Smallest allowed width honouring both minimum edges.
        let minWidth = max(minW, minH * ratio)

        if handle.isCorner {
            // Anchor = opposite corner.
            let ax = handle.movesLeft ? r0.maxX : r0.minX
            let ay = handle.movesTop ? r0.maxY : r0.minY
            let px = (handle.movesLeft ? r0.minX : r0.maxX) + t.width
            let py = (handle.movesTop ? r0.minY : r0.maxY) + t.height
            let dx = handle.movesLeft ? ax - px : px - ax
            let dy = handle.movesTop ? ay - py : py - ay
            // Follow whichever axis moved further from the starting size, growing or shrinking.
            let wx = dx, wy = dy * ratio
            var w = abs(wx - r0.width) >= abs(wy - r0.width) ? wx : wy
            let maxW = handle.movesLeft ? ax - b.minX : b.maxX - ax
            let maxH = handle.movesTop ? ay - b.minY : b.maxY - ay
            w = min(w, maxW, maxH * ratio)
            w = max(w, min(minWidth, maxW, maxH * ratio))
            let h = w / ratio
            return CGRect(x: handle.movesLeft ? ax - w : ax, y: handle.movesTop ? ay - h : ay, width: w, height: h)
        }

        if handle.movesLeft || handle.movesRight {
            // Horizontal edge drag: width follows the pointer; the height stays centred on the
            // old vertical centre when possible, otherwise it shifts to stay inside the image.
            let ax = handle.movesLeft ? r0.maxX : r0.minX
            let cy = r0.midY
            var w = handle.movesLeft ? r0.width - t.width : r0.width + t.width
            let maxW = handle.movesLeft ? ax - b.minX : b.maxX - ax
            let maxH = b.height
            w = min(w, maxW, maxH * ratio)
            w = max(w, min(minWidth, maxW, maxH * ratio))
            let h = w / ratio
            let y = min(max(cy - h / 2, b.minY), b.maxY - h)
            return CGRect(x: handle.movesLeft ? ax - w : ax, y: y, width: w, height: h)
        }

        // Vertical edge drag: height follows the pointer; the width stays centred on the old
        // horizontal centre when possible, otherwise it shifts to stay inside the image.
        let ay = handle.movesTop ? r0.maxY : r0.minY
        let cx = r0.midX
        var h = handle.movesTop ? r0.height - t.height : r0.height + t.height
        let maxH = handle.movesTop ? ay - b.minY : b.maxY - ay
        let maxW = b.width
        h = min(h, maxH, maxW / ratio)
        h = max(h, min(minWidth / ratio, maxH, maxW / ratio))
        let w = h * ratio
        let x = min(max(cx - w / 2, b.minX), b.maxX - w)
        return CGRect(x: x, y: handle.movesTop ? ay - h : ay, width: w, height: h)
    }

    /// Normalized (0…1) ↔ view rect conversions for an image drawn in `frame`.
    static func toView(_ n: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + n.minX * frame.width, y: frame.minY + n.minY * frame.height,
               width: n.width * frame.width, height: n.height * frame.height)
    }

    static func toNormalized(_ v: CGRect, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let r = CGRect(x: (v.minX - frame.minX) / frame.width, y: (v.minY - frame.minY) / frame.height,
                       width: v.width / frame.width, height: v.height / frame.height)
        return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
