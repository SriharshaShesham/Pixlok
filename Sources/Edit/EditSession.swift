import Foundation
import Combine
import CoreGraphics
import CoreImage

extension Notification.Name {
    /// Posted (object: the changed file URL; userInfo["urls"]: [URL] of every affected path)
    /// after an edit was saved or reverted, so caches can drop stale decodes.
    /// Same string as the pipeline's `fileDidChange`, spelled out to avoid a compile-time dependency.
    static let editFileDidChange = Notification.Name("Pixlok.fileDidChange")
}

/// What the preview currently shows: the rendered image and whether it was rendered
/// without the crop (crop tool active), so the crop overlay only aligns to matching frames.
struct EditPreviewFrame {
    let image: CGImage
    let uncropped: Bool
}

/// Non-Sendable values carried into a detached render task (CIImage is immutable).
private struct RenderJob: @unchecked Sendable {
    let image: CIImage
    let recipe: EditRecipe
    let includeCrop: Bool
}

/// Per-window edit-mode state: the recipe being edited, the decoded source, the live preview
/// (coalesced background renders, latest wins, at most one in flight) and the crop tool.
@MainActor
final class EditSession: ObservableObject {
    @Published var recipe = EditRecipe() { didSet { if recipe != oldValue { scheduleRender() } } }
    @Published var isCropping = false { didSet { if isCropping != oldValue { scheduleRender() } } }
    @Published var cropAspect: CropAspect = .free
    /// Orientation of the fixed-ratio presets: nil follows the picture, true = portrait (e.g. 9:16).
    @Published var cropPortrait: Bool? = nil
    /// Crop rectangle being edited (normalized, top-left origin, in the uncropped geometry image).
    @Published var draftCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published private(set) var isLoading = true
    /// Holding "\" or the Compare button shows the unedited image.
    @Published var showingOriginal = false
    @Published private(set) var preview: EditPreviewFrame?
    @Published private(set) var beforeImage: CGImage?
    @Published private(set) var hasOriginal = false

    let url: URL
    /// The recipe the session started with (seeded from the view rotation); "dirty" is relative to it.
    let initialRecipe: EditRecipe
    private(set) var source: EditSource?

    private var loadTask: Task<Void, Never>?
    private var renderInFlight = false
    private var renderPending = false
    private static let previewRenderError = "The preview couldn’t be rendered."

    init(url: URL) {
        self.url = url
        self.initialRecipe = EditRecipe()
    }

    init(url: URL, initialRecipe: EditRecipe) {
        self.url = url
        self.initialRecipe = initialRecipe
        self.recipe = initialRecipe
    }

    deinit { loadTask?.cancel() }

    // MARK: State

    /// Unsaved changes worth a "Discard changes?" prompt.
    var isDirty: Bool {
        if recipe != initialRecipe { return true }
        if isCropping, !Self.isFullRect(draftCrop), draftCrop != recipe.crop { return true }
        return false
    }

    /// Something to write (Save enabled).
    var canSave: Bool { source != nil && !isSaving && (!recipe.isIdentity || (isCropping && !Self.isFullRect(draftCrop))) }

    /// Pixel size of the full-resolution image after rotation/flip/straighten (before crop).
    var geometryPixelSize: CGSize {
        guard let full = source?.full.extent.size, full.width > 0, full.height > 0 else { return CGSize(width: 1, height: 1) }
        return recipe.rotationQuarterTurns % 2 == 0 ? full : CGSize(width: full.height, height: full.width)
    }

    /// Pixel size of the full-resolution result (after crop), for the panel's info line.
    var outputPixelSize: CGSize {
        let g = geometryPixelSize
        guard let c = recipe.crop else { return g }
        return CGSize(width: (g.width * c.width).rounded(), height: (g.height * c.height).rounded())
    }

    func refreshHasOriginal() { hasOriginal = EditSaveService.hasOriginal(for: url) }

    // MARK: Loading

    func load() {
        refreshHasOriginal()
        loadTask?.cancel()
        isLoading = true
        cropPortrait = nil
        let url = url
        loadTask = Task { [weak self] in
            do {
                let src = try await ImageEditPipeline.loadSource(url)
                guard let self, !Task.isCancelled else { return }
                self.source = src
                self.isLoading = false
                self.scheduleRender()
                self.renderBefore(src)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoading = false
                self.errorMessage = "Couldn’t open “\(url.lastPathComponent)” for editing. \(error.localizedDescription)"
            }
        }
    }

    /// The "Before" image: the source with only the seeded view geometry (rotation/flips), so
    /// Compare toggles the adjustments without changing the picture's orientation.
    private func renderBefore(_ src: EditSource) {
        var before = EditRecipe()
        before.rotationQuarterTurns = initialRecipe.rotationQuarterTurns
        before.flipHorizontal = initialRecipe.flipHorizontal
        before.flipVertical = initialRecipe.flipVertical
        let job = RenderJob(image: src.preview, recipe: before, includeCrop: true)
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                ImageEditPipeline.render(ImageEditPipeline.apply(job.recipe, to: job.image, includeCrop: true))
            }.value
            self?.beforeImage = image
        }
    }

    // MARK: Rendering (latest wins, at most one in flight)

    func scheduleRender() {
        guard source != nil else { return }
        if renderInFlight { renderPending = true; return }
        startRender()
    }

    private func startRender() {
        guard let src = source else { return }
        renderInFlight = true
        renderPending = false
        let job = RenderJob(image: src.preview, recipe: recipe, includeCrop: !isCropping)
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                ImageEditPipeline.render(ImageEditPipeline.apply(job.recipe, to: job.image, includeCrop: job.includeCrop))
            }.value
            guard let self else { return }
            self.renderInFlight = false
            // Show every finished frame (keeps drags live); a newer one follows if pending.
            if let image {
                self.preview = EditPreviewFrame(image: image, uncropped: !job.includeCrop)
                if self.errorMessage == Self.previewRenderError { self.errorMessage = nil }
            } else if !self.renderPending {
                self.errorMessage = Self.previewRenderError
            }
            if self.renderPending { self.startRender() }
        }
    }

    // MARK: Adjustments

    func resetLight() {
        guard !isSaving else { return }
        recipe.exposure = 0; recipe.brightness = 0; recipe.contrast = 0; recipe.highlights = 0; recipe.shadows = 0
    }
    func resetColor() { guard !isSaving else { return }; recipe.saturation = 0; recipe.vibrance = 0; recipe.temperature = 0; recipe.tint = 0 }
    func resetDetail() { guard !isSaving else { return }; recipe.sharpness = 0 }
    func resetGeometry() {
        guard !isSaving else { return }
        var r = recipe
        r.rotationQuarterTurns = 0; r.flipHorizontal = false; r.flipVertical = false; r.straighten = 0; r.crop = nil
        recipe = r
        draftCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        if cropAspect != .free { applyAspectToDraft() }
    }
    func resetAll() {
        guard !isSaving else { return }
        let wasCropping = isCropping
        recipe = .identity
        cropAspect = .free
        draftCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        isCropping = wasCropping
    }

    // MARK: Geometry (keeps the crop on the same picture content)

    /// Rotates the displayed image a quarter turn (clockwise when `clockwise`).
    func rotate(clockwise: Bool) {
        guard !isSaving else { return }
        var r = recipe
        // Rotation is applied before the flips, so with exactly one flip active the
        // stored rotation must go the other way for the display to turn as asked.
        let oneFlip = r.flipHorizontal != r.flipVertical
        let delta = (clockwise != oneFlip) ? 1 : 3
        r.rotationQuarterTurns = (r.rotationQuarterTurns + delta) % 4
        r.crop = r.crop.map { Self.rotated($0, clockwise: clockwise) }
        recipe = r
        draftCrop = Self.rotated(draftCrop, clockwise: clockwise)
        if cropAspect != .free && cropAspect != .original { applyAspectToDraft() }
    }

    func flip(horizontal: Bool) {
        guard !isSaving else { return }
        var r = recipe
        if horizontal { r.flipHorizontal.toggle() } else { r.flipVertical.toggle() }
        // Straighten is applied after the flips: mirroring the result mirrors the tilt too.
        if r.straighten != 0 { r.straighten = -r.straighten }
        r.crop = r.crop.map { Self.flipped($0, horizontal: horizontal) }
        recipe = r
        draftCrop = Self.flipped(draftCrop, horizontal: horizontal)
    }

    nonisolated static func rotated(_ c: CGRect, clockwise: Bool) -> CGRect {
        clockwise
            ? CGRect(x: 1 - c.maxY, y: c.minX, width: c.height, height: c.width)
            : CGRect(x: c.minY, y: 1 - c.maxX, width: c.height, height: c.width)
    }

    nonisolated static func flipped(_ c: CGRect, horizontal: Bool) -> CGRect {
        horizontal
            ? CGRect(x: 1 - c.maxX, y: c.minY, width: c.width, height: c.height)
            : CGRect(x: c.minX, y: 1 - c.maxY, width: c.width, height: c.height)
    }

    nonisolated static func isFullRect(_ r: CGRect) -> Bool {
        abs(r.minX) < 0.0005 && abs(r.minY) < 0.0005 && abs(r.width - 1) < 0.0005 && abs(r.height - 1) < 0.0005
    }

    // MARK: Crop tool

    /// Width / height of the selected aspect in pixels, nil = free.
    var cropRatio: CGFloat? {
        switch cropAspect {
        case .free: return nil
        case .original:
            guard let full = source?.full.extent.size, full.height > 0 else { return nil }
            // "Original" follows the orientation of the (rotated) picture.
            let r = full.width / full.height
            return recipe.rotationQuarterTurns % 2 == 0 ? r : 1 / r
        default:
            guard let r = cropAspect.ratio else { return nil }
            // Presets follow the picture's orientation unless the user swapped it.
            let g = geometryPixelSize
            let portrait = cropPortrait ?? (g.height > g.width)
            return portrait && r != 1 ? 1 / r : r
        }
    }

    func beginCrop() {
        guard source != nil, !isCropping, !isSaving else { return }
        draftCrop = recipe.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        isCropping = true
        if cropAspect != .free { applyAspectToDraft(onlyIfMismatched: true) }
    }

    func commitCrop() {
        guard isCropping, !isSaving else { return }
        let c = draftCrop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        recipe.crop = (c.isNull || c.isEmpty || Self.isFullRect(c)) ? nil : c
        isCropping = false
    }

    func cancelCrop() {
        guard isCropping else { return }
        draftCrop = recipe.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        isCropping = false
    }

    func toggleCrop() { isCropping ? commitCrop() : beginCrop() }

    /// Whether the selected preset can swap between landscape and portrait.
    var cropAspectCanSwap: Bool {
        switch cropAspect { case .free, .original, .square: return false; default: return true }
    }

    /// The effective portrait orientation of the fixed-ratio presets.
    var cropIsPortrait: Bool {
        let g = geometryPixelSize
        return cropPortrait ?? (g.height > g.width)
    }

    /// Swaps the fixed-ratio presets between landscape and portrait (e.g. 16:9 ↔ 9:16).
    func toggleCropOrientation() {
        guard !isSaving else { return }
        cropPortrait = !cropIsPortrait
        if !isCropping { beginCrop() }
        applyAspectToDraft()
    }

    func setCropAspect(_ aspect: CropAspect) {
        guard !isSaving else { return }
        if aspect == cropAspect, cropAspectCanSwap { toggleCropOrientation(); return }
        cropAspect = aspect
        if !isCropping { beginCrop() }
        applyAspectToDraft()
    }

    /// Fits the largest rect of the selected aspect, centered on the current draft, inside the image.
    func applyAspectToDraft(onlyIfMismatched: Bool = false) {
        guard let ratio = cropRatio else { return }
        let g = geometryPixelSize
        // Work in pixel units so the aspect is exact.
        let d = CGRect(x: draftCrop.minX * g.width, y: draftCrop.minY * g.height,
                       width: draftCrop.width * g.width, height: draftCrop.height * g.height)
        if onlyIfMismatched, d.height > 0, abs(d.width / d.height - ratio) < 0.01 { return }
        let fitted = Self.fit(ratio: ratio, around: CGPoint(x: d.midX, y: d.midY),
                              preferredArea: d.width * d.height, in: CGRect(origin: .zero, size: g))
        draftCrop = CGRect(x: fitted.minX / g.width, y: fitted.minY / g.height,
                           width: fitted.width / g.width, height: fitted.height / g.height)
    }

    /// Largest rect with `ratio` inside `bounds` not bigger than ~`preferredArea`, centered as close to `center` as fits.
    nonisolated static func fit(ratio: CGFloat, around center: CGPoint, preferredArea: CGFloat, in bounds: CGRect) -> CGRect {
        var w = bounds.width
        var h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        // Prefer roughly the current crop's area (but never smaller than half of the max).
        let maxArea = w * h
        if preferredArea > 0 && preferredArea < maxArea {
            let scale = max(sqrt(preferredArea / maxArea), 0.5)
            w *= scale; h *= scale
        }
        var x = center.x - w / 2
        var y = center.y - h / 2
        x = min(max(x, bounds.minX), bounds.maxX - w)
        y = min(max(y, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Saving

    /// Renders and writes the edit (EditSaveService), then posts `editFileDidChange`.
    func save() async throws -> EditSaveResult {
        if isCropping { commitCrop() }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let recipe = recipe
        let url = url
        do {
            let result = try await EditSaveService.save(recipe, source: url)
            Self.postFileDidChange([url, result.savedURL, result.originalURL])
            hasOriginal = true
            return result
        } catch {
            errorMessage = "Couldn’t save: \(error.localizedDescription)"
            throw error
        }
    }

    static func postFileDidChange(_ urls: [URL]) {
        var seen = Set<String>()
        let unique = urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        NotificationCenter.default.post(name: .editFileDidChange, object: unique.first, userInfo: ["urls": unique])
    }

    func cancel() {
        loadTask?.cancel()
        renderPending = false
    }
}

/// Holds the window's edit session (nil when not editing) for the SwiftUI views.
@MainActor
final class EditHost: ObservableObject {
    @Published var session: EditSession?
    /// Bumped after a save/revert so media views re-decode a file whose URL didn't change.
    @Published var contentRevision = 0
    private var editableCache: [String: Bool] = [:]

    var isEditing: Bool { session != nil }

    /// Memoized `ImageEditPipeline.canEdit` (it may read the file header).
    func canEdit(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        if let hit = editableCache[key] { return hit }
        let ok = FormatRegistry.format(for: url)?.category == .raster && ImageEditPipeline.canEdit(url)
        editableCache[key] = ok
        return ok
    }

    func forgetEditability(_ urls: [URL]) {
        for u in urls { editableCache.removeValue(forKey: u.standardizedFileURL.path) }
    }

    /// Tooltip for the Edit button.
    func editHelp(for url: URL?) -> String {
        guard let url else { return "Edit" }
        if canEdit(url) { return "Edit (E)" }
        switch FormatRegistry.format(for: url)?.category {
        case .svg: return "Editing isn’t available for SVG files"
        case .model3D: return "Editing isn’t available for 3D models"
        case .video: return "Editing isn’t available for videos"
        default: return "Editing isn’t available for this image (animated or unsupported)"
        }
    }
}

/// Edit actions the SwiftUI views forward to the window controller (alerts, file system, browser).
@MainActor
protocol EditCommandHandler: AnyObject {
    func editBegin()
    func editRequestCancel()
    func editSave()
    func editRequestRevert()
}
