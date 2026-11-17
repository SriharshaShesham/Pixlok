import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A decoded raster image ready for display.
///
/// `pixelSize` is always the full, orientation-corrected pixel size of the file,
/// even when `image` holds a downsampled copy, so geometry stays identical when
/// the full-resolution version replaces the display copy.
final class ImageContent {
    let url: URL
    let modificationDate: Date?
    /// Full image size in pixels after applying EXIF orientation.
    let pixelSize: CGSize
    /// Static image (nil when `animatedImage` is set).
    let cgImage: CGImage?
    /// Multi-frame image (GIF / APNG / animated WebP) for NSImageView animation.
    let animatedImage: NSImage?
    /// True when `cgImage` holds every pixel of the file (or the image is animated).
    let isFullResolution: Bool
    let cost: Int

    init(url: URL, modificationDate: Date?, pixelSize: CGSize, cgImage: CGImage?,
         animatedImage: NSImage?, isFullResolution: Bool, cost: Int) {
        self.url = url
        self.modificationDate = modificationDate
        self.pixelSize = pixelSize
        self.cgImage = cgImage
        self.animatedImage = animatedImage
        self.isFullResolution = isFullResolution
        self.cost = cost
    }

    var isAnimated: Bool { animatedImage != nil }

    /// Pixel width of the decoded bitmap actually held in memory.
    var decodedPixelWidth: CGFloat {
        if let cg = cgImage { return CGFloat(cg.width) }
        return pixelSize.width
    }
}

enum ImageLoadError: Error {
    case missing
    case unreadable
    case cancelled

    var message: String {
        switch self {
        case .missing: return "This file is no longer available."
        case .unreadable: return "The file may be damaged, or it's in a format macOS can't read."
        case .cancelled: return ""
        }
    }
}

/// Shared decoded-image cache with de-duplicated, cancellable, prioritised
/// background decoding. All bookkeeping happens on the main actor; decoding
/// runs on a private OperationQueue.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    typealias LoadResult = Result<ImageContent, ImageLoadError>

    private let cache = NSCache<NSString, ImageContent>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "ImageCache.decode"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    private final class Request {
        let operation: BlockOperation
        var waiters: [UUID: CheckedContinuation<LoadResult, Never>] = [:]
        var isPrefetch: Bool
        init(operation: BlockOperation, isPrefetch: Bool) {
            self.operation = operation
            self.isPrefetch = isPrefetch
        }
    }

    private var inFlight: [String: Request] = [:]

    private init() {
        cache.totalCostLimit = 768 * 1024 * 1024
        cache.countLimit = 64
        // A saved / reverted edit rewrote a file: drop its decodes (same URL, new pixels).
        NotificationCenter.default.addObserver(forName: Notification.Name("Picsl.fileDidChange"),
                                               object: nil, queue: .main) { [weak self] note in
            var urls = (note.userInfo?["urls"] as? [URL]) ?? []
            if let url = note.object as? URL { urls.append(url) }
            if let url = note.userInfo?["url"] as? URL { urls.append(url) }
            MainActor.assumeIsolated { self?.invalidate(urls) }
        }
    }

    /// Forgets cached decodes of `urls` (an in-flight decode is re-checked against the
    /// file's modification date when it is looked up).
    func invalidate(_ urls: [URL]) {
        for url in urls {
            cache.removeObject(forKey: Self.key(url, full: true) as NSString)
            cache.removeObject(forKey: Self.key(url, full: false) as NSString)
        }
    }

    // MARK: Sizing

    /// Longest edge (in device pixels) of the display copy: the largest screen in pixels.
    var displayMaxPixel: Int {
        let longest = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 3000
        return max(2048, Int(longest.rounded(.up)))
    }

    // MARK: Lookup

    private static func key(_ url: URL, full: Bool) -> String {
        url.standardizedFileURL.path + (full ? "|full" : "|display")
    }

    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Returns a cached decode if present and still matching the file on disk.
    func cached(_ url: URL, requireFull: Bool) -> ImageContent? {
        let keys = requireFull ? [Self.key(url, full: true)] : [Self.key(url, full: true), Self.key(url, full: false)]
        let modDate = Self.modificationDate(of: url)
        for k in keys {
            guard let hit = cache.object(forKey: k as NSString) else { continue }
            if hit.modificationDate == modDate { return hit }
            cache.removeObject(forKey: k as NSString)
        }
        return nil
    }

    // MARK: Loading

    /// Loads (or returns cached) content. `full == false` returns a copy sized for the
    /// screen (which is the full image when it is small enough). Cancelling the calling
    /// task returns `.failure(.cancelled)` promptly and drops the decode if nobody else
    /// is waiting for it.
    func load(_ url: URL, full: Bool) async -> LoadResult {
        if let hit = cached(url, requireFull: full) { return .success(hit) }
        if Task.isCancelled { return .failure(.cancelled) }
        let key = Self.key(url, full: full)
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<LoadResult, Never>) in
                let request = self.request(for: key, url: url, full: full, prefetch: false)
                request.waiters[waiterID] = cont
            }
        } onCancel: {
            Task { @MainActor in self.dropWaiter(waiterID, key: key) }
        }
    }

    /// Decodes display copies of `urls` in the background (low priority). Pending
    /// prefetches for URLs not in this list are cancelled.
    func prefetch(_ urls: [URL]) {
        let wanted = Set(urls.map { Self.key($0, full: false) })
        for (k, req) in inFlight where req.isPrefetch && req.waiters.isEmpty && !wanted.contains(k) {
            if !req.operation.isExecuting {
                req.operation.cancel()
                inFlight[k] = nil
            }
        }
        for url in urls where cached(url, requireFull: false) == nil {
            _ = request(for: Self.key(url, full: false), url: url, full: false, prefetch: true)
        }
    }

    func removeAll() { cache.removeAllObjects() }

    private func request(for key: String, url: URL, full: Bool, prefetch: Bool) -> Request {
        if let existing = inFlight[key] {
            if !prefetch && existing.isPrefetch {
                existing.isPrefetch = false
                existing.operation.queuePriority = .veryHigh
            }
            return existing
        }
        let maxPixel = displayMaxPixel
        let op = BlockOperation()
        op.addExecutionBlock { [weak op] in
            if op?.isCancelled == true { return }
            let result = ImageDecoder.decode(url: url, full: full, maxPixel: maxPixel)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ImageCache.shared.finish(key: key, result: result) }
            }
        }
        op.queuePriority = prefetch ? .low : .veryHigh
        op.qualityOfService = prefetch ? .utility : .userInitiated
        let req = Request(operation: op, isPrefetch: prefetch)
        inFlight[key] = req
        queue.addOperation(op)
        return req
    }

    private func finish(key: String, result: LoadResult) {
        if case .success(let content) = result {
            cache.setObject(content, forKey: key as NSString, cost: content.cost)
        }
        guard let req = inFlight.removeValue(forKey: key) else { return }
        for (_, cont) in req.waiters { cont.resume(returning: result) }
    }

    private func dropWaiter(_ id: UUID, key: String) {
        guard let req = inFlight[key], let cont = req.waiters.removeValue(forKey: id) else { return }
        cont.resume(returning: .failure(.cancelled))
        if req.waiters.isEmpty && !req.isPrefetch && !req.operation.isExecuting {
            req.operation.cancel()
            inFlight[key] = nil
        }
    }
}

/// Stateless ImageIO decoding (runs off the main thread).
enum ImageDecoder {
    /// Above this many pixels the "full resolution" copy is itself downsampled
    /// to keep memory bounded (200 MP ≈ 800 MB of RGBA).
    static let maxFullPixels: CGFloat = 200_000_000

    private static let animatableTypes: Set<String> = [
        UTType.gif.identifier, UTType.png.identifier, "org.webmproject.webp",
    ]

    static func decode(url: URL, full: Bool, maxPixel: Int) -> Result<ImageContent, ImageLoadError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        let modDate = ImageCache.modificationDate(of: url)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetStatus(source) == .statusComplete || CGImageSourceGetStatus(source) == .statusIncomplete,
              CGImageSourceGetCount(source) > 0
        else { return .failure(.unreadable) }

        let frameCount = CGImageSourceGetCount(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) { swap(&width, &height) }

        // Animated images: let NSImageView play them.
        if frameCount > 1, let type = CGImageSourceGetType(source) as String?, animatableTypes.contains(type),
           let animated = animatedImage(url: url), width > 0, height > 0 {
            let size = CGSize(width: width, height: height)
            animated.size = size
            let cost = Int(width * height * 4) * min(frameCount, 64)
            return .success(ImageContent(url: url, modificationDate: modDate, pixelSize: size, cgImage: nil,
                                         animatedImage: animated, isFullResolution: true, cost: cost))
        }

        let longest = max(width, height)
        var target: Double
        if longest <= 0 {
            target = 0 // unknown size: decode as-is
        } else if full {
            let area = width * height
            target = area > maxFullPixels ? longest * (maxFullPixels / area).squareRoot() : longest
        } else {
            target = min(longest, Double(maxPixel))
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if target > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = Int(target.rounded(.up)) }

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? fallbackImage(source: source)
        else { return .failure(.unreadable) }

        if width <= 0 || height <= 0 {
            width = Double(image.width)
            height = Double(image.height)
        }
        let isFull = Double(max(image.width, image.height)) >= max(width, height) - 1 || full
        let cost = max(image.bytesPerRow * image.height, image.width * image.height * 4)
        return .success(ImageContent(url: url, modificationDate: modDate,
                                     pixelSize: CGSize(width: width, height: height),
                                     cgImage: image, animatedImage: nil, isFullResolution: isFull, cost: cost))
    }

    /// Plain decode when the thumbnail path fails (rare formats); orientation not applied.
    private static func fallbackImage(source: CGImageSource) -> CGImage? {
        CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func animatedImage(url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let rep = NSBitmapImageRep(data: data),
              let frames = rep.value(forProperty: .frameCount) as? Int, frames > 1
        else { return nil }
        let image = NSImage()
        image.addRepresentation(rep)
        return image
    }
}
