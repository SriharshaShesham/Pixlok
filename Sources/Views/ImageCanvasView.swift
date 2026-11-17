import SwiftUI
import AppKit

/// Raster image display: zoom (ViewerState.zoom), pan, rotation, animated GIFs,
/// downsampled display copy with lazy full-resolution upgrade.
struct ImageCanvasView: View {
    let url: URL
    @ObservedObject var state: ViewerState
    @StateObject private var model = ImageCanvasModel()

    var body: some View {
        ZStack {
            Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)
            ImageScrollRepresentable(content: model.url == url ? model.content : nil, state: state,
                                     requestFullResolution: { model.requestFullResolution() })
            switch model.url == url ? model.phase : .loading {
            case .loading:
                ImageLoadingIndicator()
            case .failed(let error):
                ImageMessageView(detail: error.message, fileName: url.lastPathComponent)
            case .idle, .loaded:
                EmptyView()
            }
        }
        .task(id: url) { await model.load(url) }
    }

    /// Decode display copies of `urls` (e.g. the previous/next files) in the
    /// background so stepping to them is instant. Non-raster URLs are ignored.
    @MainActor
    static func prefetch(_ urls: [URL]) {
        let raster = urls.filter { FormatRegistry.format(for: $0)?.category == .raster }
        ImageCache.shared.prefetch(raster)
    }
}

@MainActor
final class ImageCanvasModel: ObservableObject {
    enum Phase {
        case idle, loading, loaded
        case failed(ImageLoadError)
    }

    @Published private(set) var content: ImageContent?
    @Published private(set) var phase: Phase = .idle
    private(set) var url: URL?
    private var fullResTask: Task<Void, Never>?

    func load(_ url: URL) async {
        self.url = url
        fullResTask?.cancel()
        fullResTask = nil
        if let hit = ImageCache.shared.cached(url, requireFull: false) {
            content = hit
            phase = .loaded
            return
        }
        content = nil
        phase = .loading
        let result = await ImageCache.shared.load(url, full: false)
        guard self.url == url, !Task.isCancelled else { return }
        switch result {
        case .success(let c):
            content = c
            phase = .loaded
        case .failure(.cancelled):
            break
        case .failure(let error):
            content = nil
            phase = .failed(error)
        }
    }

    /// Called by the canvas when the on-screen scale needs more pixels than the display copy has.
    func requestFullResolution() {
        guard let current = content, let url, current.url == url,
              !current.isFullResolution, fullResTask == nil else { return }
        fullResTask = Task { [weak self] in
            let result = await ImageCache.shared.load(url, full: true)
            guard let self, !Task.isCancelled, self.url == url else { return }
            if case .success(let full) = result { self.content = full }
            // On failure keep the display copy; leave fullResTask set so we don't retry in a loop.
        }
    }
}

/// Bridges ImageScrollView to SwiftUI and keeps it in sync with ViewerState.
struct ImageScrollRepresentable: NSViewRepresentable {
    let content: ImageContent?
    @ObservedObject var state: ViewerState
    let requestFullResolution: () -> Void

    final class Coordinator {
        var appliedZoom: ZoomMode?
        var state: ViewerState?
        var requestFullResolution: (() -> Void)?
        var pendingScale: CGFloat?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ImageScrollView {
        let view = ImageScrollView(frame: .zero)
        let coordinator = context.coordinator
        view.onUserZoom = { [weak coordinator] mode in
            guard let coordinator, let state = coordinator.state else { return }
            coordinator.appliedZoom = mode
            if state.zoom != mode { state.zoom = mode }
        }
        view.onMagnificationChanged = { [weak coordinator, weak view] m in
            guard let coordinator, let view else { return }
            // Never publish during a SwiftUI view update; coalesce to the next runloop turn.
            let needsSchedule = coordinator.pendingScale == nil
            coordinator.pendingScale = m
            if needsSchedule {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let scale = coordinator.pendingScale else { return }
                        coordinator.pendingScale = nil
                        if let state = coordinator.state, abs(state.effectiveScale - scale) > 0.0001 {
                            state.effectiveScale = scale
                        }
                    }
                }
            }
            if let c = view.content, !c.isFullResolution {
                let backing = view.window?.backingScaleFactor ?? 2
                let needed = m * backing * c.pixelSize.width
                if needed > c.decodedPixelWidth * 1.05 { coordinator.requestFullResolution?() }
            }
        }
        return view
    }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.state = state
        coordinator.requestFullResolution = requestFullResolution

        let geometryChanged = view.setContent(content)
        let turnsChanged = view.quarterTurns != ((state.rotationQuarterTurns % 4) + 4) % 4
        if turnsChanged { view.setQuarterTurns(state.rotationQuarterTurns) }

        guard content != nil else {
            coordinator.appliedZoom = nil
            return
        }
        if geometryChanged || coordinator.appliedZoom != state.zoom || (turnsChanged && state.zoom == .fit) {
            switch state.zoom {
            case .fit:
                view.applyFit()
            case .scale(let s):
                view.applyScale(s, recenter: geometryChanged)
            }
            coordinator.appliedZoom = state.zoom
        }
    }
}
