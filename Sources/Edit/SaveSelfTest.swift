import Foundation
import CoreGraphics
import ImageIO

/// Headless edit/save checks (used by SelfTest):
///   --selftest-edit <file> <recipe-json>   saves IN PLACE (use copies!) and prints
///       savedURL=…, originalURL=…, size=WxH, type=<UTType>, mean=<0…255 luminance-ish mean of RGB>
///   --selftest-revert <file>               reverts and prints restoredURL=… (the edited file is
///       deleted, not trashed, so test runs don't fill the Trash)
/// recipe-json keys are optional: exposure, brightness, contrast, highlights, shadows, saturation,
/// vibrance, temperature, tint, sharpness, rotationQuarterTurns, flipHorizontal, flipVertical,
/// straighten, crop ([x, y, w, h] normalized, top-left origin).
enum SaveSelfTest {
    static func recipe(fromJSON text: String) throws -> EditRecipe {
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var r = EditRecipe()
        func d(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
        if let v = d("exposure") { r.exposure = v }
        if let v = d("brightness") { r.brightness = v }
        if let v = d("contrast") { r.contrast = v }
        if let v = d("highlights") { r.highlights = v }
        if let v = d("shadows") { r.shadows = v }
        if let v = d("saturation") { r.saturation = v }
        if let v = d("vibrance") { r.vibrance = v }
        if let v = d("temperature") { r.temperature = v }
        if let v = d("tint") { r.tint = v }
        if let v = d("sharpness") { r.sharpness = v }
        if let v = d("straighten") { r.straighten = v }
        if let v = d("rotationQuarterTurns") { r.rotationQuarterTurns = Int(v) }
        if let v = obj["flipHorizontal"] as? Bool { r.flipHorizontal = v }
        if let v = obj["flipVertical"] as? Bool { r.flipVertical = v }
        if let a = obj["crop"] as? [NSNumber], a.count == 4 {
            r.crop = CGRect(x: a[0].doubleValue, y: a[1].doubleValue, width: a[2].doubleValue, height: a[3].doubleValue)
        }
        return r
    }

    /// Mean of R, G, B over a 64×64 downsample (0…255).
    static func meanRGB(_ url: URL) -> (Double, Double, Double)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let p = data.bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(64 * 64) { r += Double(p[i * 4]); g += Double(p[i * 4 + 1]); b += Double(p[i * 4 + 2]) }
        let n = Double(64 * 64)
        return (r / n, g / n, b / n)
    }

    static func describe(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "unreadable" }
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        let type = CGImageSourceGetType(src) as String? ?? "?"
        var s = "size=\(w)x\(h) type=\(type) orientation=\(o) depth=\(p[kCGImagePropertyDepth] as? Int ?? 0)"
        s += " alpha=\((p[kCGImagePropertyHasAlpha] as? Bool) ?? false)"
        if let prof = p[kCGImagePropertyProfileName] as? String { s += " profile=\"\(prof)\"" }
        if let m = meanRGB(url) { s += String(format: " mean=%.1f,%.1f,%.1f", m.0, m.1, m.2) }
        if p[kCGImagePropertyGPSDictionary] != nil { s += " gps=yes" }
        return s
    }

    static func runEdit(path: String, recipeJSON: String) async -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        do {
            guard ImageEditPipeline.canEdit(url) else { print("error: not editable: \(url.path)"); return 1 }
            let recipe = try recipe(fromJSON: recipeJSON)
            let r = try await EditSaveService.save(recipe, source: url)
            print("savedURL=\(r.savedURL.path)")
            print("originalURL=\(r.originalURL.path)")
            print(describe(r.savedURL))
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    static func runRevert(path: String) -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        EditSaveService.trashEditedOnRevert = false
        do {
            let restored = try EditSaveService.revert(url)
            print("restoredURL=\(restored.path)")
            print(describe(restored))
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }
}
