import AppKit
import CoreImage
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers

/// A decoded image ready for editing.
final class EditSource {
    /// Full-resolution image with EXIF orientation applied (pixel units, extent origin at 0,0).
    let full: CIImage
    /// Downsampled copy (long edge ≈ 2× screen, ≤ 3000 px, origin 0,0) used for live preview.
    /// Already materialised (decoded once), so re-rendering it per slider tick is cheap.
    let preview: CIImage
    /// Colour space of the source file (nil → sRGB/Display P3 is used when saving).
    let colorSpace: CGColorSpace?
    /// Whether the source has an alpha channel.
    let hasAlpha: Bool
    /// Size of `full` in pixels (after orientation).
    var pixelSize: CGSize { full.extent.size }

    init(full: CIImage, preview: CIImage) {
        self.full = full; self.preview = preview; self.colorSpace = nil; self.hasAlpha = false
    }
    init(full: CIImage, preview: CIImage, colorSpace: CGColorSpace?, hasAlpha: Bool) {
        self.full = full; self.preview = preview; self.colorSpace = colorSpace; self.hasAlpha = hasAlpha
    }
}

enum ImageEditPipeline {
    // MARK: - Capability

    /// Whether `url` can be edited: a raster format from FormatRegistry, readable by ImageIO,
    /// with exactly one frame (animated GIF/APNG and multi-image ICO/TIFF are excluded).
    static func canEdit(_ url: URL) -> Bool {
        guard let format = FormatRegistry.format(for: url), format.category == .raster else { return false }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        if CGImageSourceGetStatus(src) != .statusComplete { return false }
        if isRaw(src, url: url) { return true }   // RAW containers may report >1 image (embedded previews)
        return CGImageSourceGetCount(src) == 1
    }

    static func isRaw(_ src: CGImageSource, url: URL) -> Bool {
        if let id = CGImageSourceGetType(src) as String?, let t = UTType(id), t.conforms(to: .rawImage) { return true }
        return FormatRegistry.format(for: url)?.id == "raw"
    }

    // MARK: - Loading

    enum LoadError: LocalizedError {
        case unreadable(URL)
        var errorDescription: String? {
            switch self { case .unreadable(let u): return "“\(u.lastPathComponent)” could not be decoded for editing." }
        }
    }

    /// Decode off the main thread.
    static func loadSource(_ url: URL) async throws -> EditSource {
        let maxPreview = await MainActor.run { previewMaxPixelSize() }
        return try await Task.detached(priority: .userInitiated) {
            try loadSourceSync(url, previewMaxPixel: maxPreview)
        }.value
    }

    /// Long edge for the preview: 2 × the largest screen's backing width/height, clamped 1024…3000.
    @MainActor static func previewMaxPixelSize() -> Int {
        let longest = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2560
        return Int(min(3000, max(1024, longest * 2)))
    }

    /// Synchronous loader (any thread). `previewMaxPixel` = 0 skips building a separate preview
    /// (preview === full), which is what saving uses.
    static func loadSourceSync(_ url: URL, previewMaxPixel: Int) throws -> EditSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw LoadError.unreadable(url) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false

        if isRaw(src, url: url) {
            guard let raw = CIRAWFilter(imageURL: url), let out = raw.outputImage else { throw LoadError.unreadable(url) }
            let full = normalized(out)
            let p3 = CGColorSpace(name: CGColorSpace.displayP3)
            guard previewMaxPixel > 0 else { return EditSource(full: full, preview: full, colorSpace: p3, hasAlpha: false) }
            let preview = materializedPreview(of: full, maxPixel: previewMaxPixel) ?? full
            return EditSource(full: full, preview: preview, colorSpace: p3, hasAlpha: false)
        }

        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw LoadError.unreadable(url)
        }
        let full = normalized(ci)
        let cs = ci.colorSpace
        guard previewMaxPixel > 0 else { return EditSource(full: full, preview: full, colorSpace: cs, hasAlpha: hasAlpha) }

        let longEdge = max(full.extent.width, full.extent.height)
        var preview = full
        if longEdge > CGFloat(previewMaxPixel) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: previewMaxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                preview = CIImage(cgImage: thumb)
            } else {
                preview = materializedPreview(of: full, maxPixel: previewMaxPixel) ?? full
            }
        } else if let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            // Small image: decode once and orient, so slider ticks don't re-decode the file.
            let orientation = (props[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
            preview = normalized(CIImage(cgImage: cg).oriented(orientation))
        }
        return EditSource(full: full, preview: normalized(preview), colorSpace: cs, hasAlpha: hasAlpha)
    }

    /// Lanczos-downscale and render once into a half-float bitmap (keeps wide-gamut / RAW range).
    private static func materializedPreview(of image: CIImage, maxPixel: Int) -> CIImage? {
        let longEdge = max(image.extent.width, image.extent.height)
        var img = image
        if longEdge > CGFloat(maxPixel) {
            let f = CIFilter(name: "CILanczosScaleTransform")!
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(Double(maxPixel) / Double(longEdge), forKey: kCIInputScaleKey)
            f.setValue(1.0, forKey: kCIInputAspectRatioKey)
            guard let out = f.outputImage else { return nil }
            img = out
        }
        let rect = img.extent.integral
        img = img.cropped(to: rect)
        guard let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let cg = context.createCGImage(img, from: rect, format: .RGBAh, colorSpace: cs) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Moves the extent origin to (0,0).
    static func normalized(_ image: CIImage) -> CIImage {
        let o = image.extent.origin
        if o == .zero { return image }
        return image.transformed(by: CGAffineTransform(translationX: -o.x, y: -o.y))
    }

    // MARK: - Recipe application

    /// Apply the recipe. `includeCrop: false` → everything except the crop (used while the crop tool is active).
    /// Order: colour/light → sharpness → quarter turns → flips → straighten → crop.
    /// All parameters are resolution-independent, so preview and full render look the same.
    /// An identity recipe returns `image` unchanged.
    static func apply(_ recipe: EditRecipe, to image: CIImage, includeCrop: Bool = true) -> CIImage {
        if recipe.isIdentity { return image }
        var img = image
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)

        // Light
        if recipe.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: recipe.exposure])
        }
        if recipe.brightness != 0 || recipe.contrast != 0 || recipe.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: recipe.brightness * 0.25,
                kCIInputContrastKey: 1 + recipe.contrast * 0.5,
                kCIInputSaturationKey: 1 + recipe.saturation,
            ])
        }
        if recipe.highlights < 0 || recipe.shadows != 0 {
            // highlightAmount: 1 = neutral, down to 0.3 recovers (darkens) highlights.
            // shadowAmount: -1…1, positive lifts shadows.
            img = img.clampedToExtent().applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": recipe.highlights < 0 ? 1 + recipe.highlights * 0.7 : 1.0,
                "inputShadowAmount": recipe.shadows,
                kCIInputRadiusKey: Double(longEdge) * 0.004,
            ]).cropped(to: extent)
        }
        if recipe.highlights > 0 {
            // CIHighlightShadowAdjust can't brighten highlights; lift the upper tones with a curve.
            let h = recipe.highlights
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.04 * h),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.12 * h),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        // Colour
        if recipe.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": recipe.vibrance])
        }
        if recipe.temperature != 0 || recipe.tint != 0 {
            // Neutral 6500 K. Declaring the source warmer (higher K) than the 6500 K target
            // makes the result warmer; ±1 ≈ ±2000 K. Tint ±1 ≈ ±50 (+ = magenta).
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + recipe.temperature * 2000, y: recipe.tint * 50),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        // Detail
        if recipe.sharpness > 0 {
            img = img.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: recipe.sharpness * 1.5,
                kCIInputRadiusKey: max(0.5, Double(longEdge) / 2000 * 1.7),
            ]).cropped(to: extent)
        }
        // Geometry
        switch ((recipe.rotationQuarterTurns % 4) + 4) % 4 {
        case 1: img = normalized(img.oriented(.right))   // 90° clockwise
        case 2: img = normalized(img.oriented(.down))
        case 3: img = normalized(img.oriented(.left))    // 90° counter-clockwise
        default: break
        }
        if recipe.flipHorizontal { img = normalized(img.oriented(.upMirrored)) }
        if recipe.flipVertical { img = normalized(img.oriented(.downMirrored)) }
        if recipe.straighten != 0 { img = straightened(img, degrees: recipe.straighten) }
        if includeCrop, let crop = recipe.crop { img = cropped(img, normalizedTopLeft: crop) }
        return img
    }

    /// Scale factor needed so a W×H image rotated by `degrees` still covers a W×H frame.
    static func straightenScale(size: CGSize, degrees: Double) -> CGFloat {
        let t = abs(degrees) * .pi / 180
        guard size.width > 0, size.height > 0 else { return 1 }
        let r = max(size.width / size.height, size.height / size.width)
        return CGFloat(cos(t)) + r * CGFloat(sin(t))
    }

    /// Rotate around the centre (positive = clockwise), scale to fill, keep the same extent.
    private static func straightened(_ image: CIImage, degrees: Double) -> CIImage {
        let e = image.extent
        let k = straightenScale(size: e.size, degrees: degrees)
        let t = CGAffineTransform(translationX: e.midX, y: e.midY)
            .rotated(by: CGFloat(-degrees * .pi / 180))   // CI is y-up: negative angle = clockwise
            .scaledBy(x: k, y: k)
            .translatedBy(x: -e.midX, y: -e.midY)
        return image.clampedToExtent().transformed(by: t).cropped(to: e)
    }

    /// Pixel rect (CI bottom-left coordinates, integral, inside `extent`) for a normalized top-left crop.
    static func cropPixelRect(_ crop: CGRect, in extent: CGRect) -> CGRect {
        let c = crop.standardized
        let x0 = max(0, min(1, c.minX)), x1 = max(0, min(1, c.maxX))
        let yTop = max(0, min(1, c.minY)), yBot = max(0, min(1, c.maxY))
        let minX = (extent.minX + x0 * extent.width).rounded()
        let maxX = (extent.minX + x1 * extent.width).rounded()
        let minY = (extent.minY + (1 - yBot) * extent.height).rounded()
        let maxY = (extent.minY + (1 - yTop) * extent.height).rounded()
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
            .intersection(extent)
    }

    private static func cropped(_ image: CIImage, normalizedTopLeft crop: CGRect) -> CIImage {
        let r = cropPixelRect(crop, in: image.extent)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return image }
        return normalized(image.cropped(to: r))
    }

    /// Output size of `apply` for an input of `size` (useful for UI layout / aspect of "Original").
    static func outputSize(_ recipe: EditRecipe, for size: CGSize, includeCrop: Bool = true) -> CGSize {
        var s = size
        if ((recipe.rotationQuarterTurns % 4) + 4) % 2 == 1 { s = CGSize(width: s.height, height: s.width) }
        if includeCrop, let crop = recipe.crop {
            s = cropPixelRect(crop, in: CGRect(origin: .zero, size: s)).size
        }
        return s
    }

    // MARK: - Rendering

    /// Shared Metal-backed context (thread-safe; used for preview and save).
    static let context: CIContext = {
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: opts) }
        return CIContext(options: opts)
    }()

    /// Render to a CGImage (shared Metal-backed CIContext), 8-bit Display P3 — for on-screen preview.
    static func render(_ image: CIImage) -> CGImage? {
        render(image, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
    }

    /// Render the image's extent into `colorSpace`. `opaque: true` produces a bitmap without alpha
    /// (so e.g. PNG/TIFF writers don't add an alpha channel). `format` is `.RGBA8` or `.RGBA16`.
    static func render(_ image: CIImage, colorSpace: CGColorSpace, format: CIFormat = .RGBA8, opaque: Bool = false) -> CGImage? {
        let rect = image.extent
        guard !rect.isInfinite, !rect.isEmpty, rect.width.isFinite, rect.height.isFinite else { return nil }
        let cs = colorSpace.model == .rgb ? colorSpace : CGColorSpace(name: CGColorSpace.sRGB)!
        if !opaque {
            return context.createCGImage(image, from: rect, format: format, colorSpace: cs)
        }
        // Opaque: render RGBA, then describe the buffer as RGBX.
        let sixteen = format == .RGBA16
        let width = Int(rect.width), height = Int(rect.height)
        let bpc = sixteen ? 16 : 8
        let rowBytes = width * 4 * (bpc / 8)
        guard let data = NSMutableData(length: rowBytes * height) else { return nil }
        context.render(image, toBitmap: data.mutableBytes, rowBytes: rowBytes, bounds: rect,
                       format: sixteen ? .RGBA16 : .RGBA8, colorSpace: cs)
        guard let provider = CGDataProvider(data: data) else { return nil }
        let info: CGBitmapInfo = sixteen
            ? [CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), .byteOrder16Little]
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc * 4,
                       bytesPerRow: rowBytes, space: cs, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
