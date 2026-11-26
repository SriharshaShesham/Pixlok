import SwiftUI
import AppKit

/// Main viewer window content: top bar, media area (routed by file category),
/// ‹ › overlay buttons, position badge, bottom toolbar pill and the info panel.
struct ViewerView: View {
    @ObservedObject var browser: FolderBrowser
    @ObservedObject var state: ViewerState
    @ObservedObject var settings: AppSettings
    @ObservedObject var chrome: ViewerChrome
    @ObservedObject var editHost: EditHost
    weak var handler: ViewerCommandHandler?

    init(browser: FolderBrowser, state: ViewerState, settings: AppSettings,
         chrome: ViewerChrome? = nil, editHost: EditHost? = nil, handler: ViewerCommandHandler? = nil) {
        self.browser = browser
        self.state = state
        self.settings = settings
        self._chrome = ObservedObject(wrappedValue: chrome ?? ViewerChrome())
        self._editHost = ObservedObject(wrappedValue: editHost ?? EditHost())
        self.handler = handler
    }

    /// The active edit session for the file on screen (nil when not editing).
    private var editSession: EditSession? {
        guard let session = editHost.session, session.url == browser.current else { return nil }
        return session
    }
    private var editHandler: EditCommandHandler? { handler as? EditCommandHandler }

    /// The PDF edit session for the file on screen (nil when not editing it).
    private var pdfSession: PDFEditSession? {
        guard let s = editHost.pdfSession, s.url == browser.current else { return nil }
        return s
    }
    private var isEditingAnything: Bool { editSession != nil || pdfSession != nil }

    private var category: MediaCategory? {
        browser.current.flatMap { FormatRegistry.format(for: $0)?.category }
    }

    private var slideshow: Bool { state.isSlideshowRunning }
    /// Bars/arrows/toolbar visible (always, except while a slideshow hides them).
    private var controlsShown: Bool { !slideshow || chrome.controlsVisible }
    /// ‹ ›, badge and toolbar pill are hidden while editing.
    private var navigationShown: Bool { controlsShown && !isEditingAnything }
    /// Images float the toolbar over the picture; STL and video keep their own
    /// bottom controls visible, so the toolbar gets a strip of its own there.
    private var toolbarFloats: Bool { category == .raster || category == .svg || category == .pdf || category == nil }
    /// STL draws its own side panel on the right, and PDFs a vertical scroller; keep the badge
    /// and › button clear of them.
    private var trailingOverlayInset: CGFloat {
        switch category {
        case .model3D: return STLView.sidePanelWidth
        case .pdf: return 14
        default: return 0
        }
    }
    /// The PDF view's own strip (sidebar, layout, search) at the top of the media area.
    private let pdfStripInset: CGFloat = 36
    /// Height of AVPlayerView's inline top control row, which the position badge must clear.
    private let videoTopControlsInset: CGFloat = 48
    /// Space kept clear under the media for the floating toolbar pill (≈40pt pill + 18pt
    /// bottom padding + margin), so "Fit" never hides part of the picture.
    private let floatingToolbarReserve: CGFloat = 66

    var body: some View {
        VStack(spacing: 0) {
            if !slideshow {
                ViewerTopBar(browser: browser, settings: settings, showInfo: $state.showInfo,
                             isEditing: isEditingAnything, handler: handler)
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    mediaArea
                    if !toolbarFloats && navigationShown && browser.current != nil {
                        toolbar
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(slideshow ? Color.black : ViewerPalette.background)
                    }
                }
                if let session = editSession {
                    EditPanelView(session: session, handler: editHandler)
                        .transition(.move(edge: .trailing))
                } else if let pdf = pdfSession {
                    PDFEditPanelView(session: pdf, handler: editHandler, pdfHandler: handler as? PDFEditCommandHandler)
                        .id(ObjectIdentifier(pdf))
                        .transition(.move(edge: .trailing))
                } else if state.showInfo && !slideshow, let url = browser.current {
                    InfoPanelView(url: url)
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(slideshow ? Color.black : ViewerPalette.background)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: controlsShown)
        .animation(.easeInOut(duration: 0.2), value: state.showInfo)
        .animation(.easeInOut(duration: 0.2), value: isEditingAnything)
        .onChange(of: browser.current) { state.resetForNewItem() }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            if let handler {
                handler.viewerOpenFiles(files)
            } else if let first = files.first {
                browser.reload(selecting: first)
            }
            return true
        }
    }

    // MARK: - Media area

    private var mediaArea: some View {
        ZStack {
            (slideshow ? Color.black : ViewerPalette.background)
            if let session = editSession {
                EditPreviewView(session: session, settings: settings)
                    .id(ObjectIdentifier(session))
            } else if let url = browser.current {
                // The revision re-creates the view (and re-decodes) after an edit was saved over `url`.
                mediaView(for: url)
                    .id("\(url.path)#\(editHost.contentRevision)")
                    .padding(.bottom, (toolbarFloats && !slideshow && navigationShown) ? floatingToolbarReserve : 0)
            } else {
                emptyFolder
            }
            if navigationShown && browser.count > 1 {
                navigationButtons
                    .padding(.trailing, trailingOverlayInset)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if navigationShown && browser.current != nil {
                positionBadge
                    .padding(12)
                    .padding(.trailing, trailingOverlayInset)
                    // AVKit's inline player draws its own top control row (full screen, AirPlay,
                    // volume) in the corners; sit the badge below it instead of on top of it.
                    .padding(.top, category == .video ? videoTopControlsInset : (category == .pdf ? pdfStripInset : 0))
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if toolbarFloats && navigationShown && browser.current != nil {
                toolbar
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func mediaView(for url: URL) -> some View {
        switch FormatRegistry.format(for: url)?.category {
        case .raster: ImageCanvasView(url: url, state: state)
        case .svg: SVGView(url: url, state: state)
        case .model3D: STLView(url: url)
        case .video: VideoView(url: url)
        case .pdf: PDFDocumentView(url: url, state: state, editHost: editHost, handler: handler)
        case nil:
            ViewerMessageView(symbol: "questionmark.square.dashed",
                              title: "Can’t show “\(url.lastPathComponent)”",
                              detail: "This file type isn’t supported.")
        }
    }

    private var emptyFolder: some View {
        VStack(spacing: 14) {
            ViewerMessageView(symbol: "photo.on.rectangle.angled",
                              title: "No viewable files in “\(browser.folder.lastPathComponent)”",
                              detail: "Tick more types under Files Pixlok opens in Settings, or open another file.")
            HStack(spacing: 10) {
                Button("Open…") { handler?.viewerShowOpenPanel() }
                    .buttonStyle(ViewerAccentButtonStyle())
                Button("Settings…") { handler?.viewerShowSettings() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Overlays

    private var canGoPrevious: Bool { settings.wrapAround || browser.index > 0 }
    private var canGoNext: Bool { settings.wrapAround || browser.index < browser.count - 1 }

    private var navigationButtons: some View {
        HStack {
            ViewerNavButton(symbol: "chevron.left", help: "Previous (←)", enabled: canGoPrevious) {
                browser.previous()
            }
            Spacer()
            ViewerNavButton(symbol: "chevron.right", help: "Next (→)", enabled: canGoNext) {
                browser.next()
            }
        }
        .padding(.horizontal, 16)
    }

    private var positionBadge: some View {
        Text("\(browser.positionText) · \(settings.sortKey.label) \(settings.sortAscending ? "↑" : "↓")")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(ViewerPalette.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
            .help("Position in folder · sort order (change in Settings)")
    }

    private var toolbar: some View {
        ToolbarPill(state: state,
                    zoomEnabled: category == .raster || category == .svg || category == .pdf,
                    canGoPrevious: canGoPrevious && browser.count > 1,
                    canGoNext: canGoNext && browser.count > 1,
                    onPrevious: { browser.previous() },
                    onNext: { browser.next() },
                    onSlideshow: {
                        if let handler { handler.viewerToggleSlideshow() } else { state.isSlideshowRunning.toggle() }
                    },
                    onDelete: {
                        if let handler { handler.viewerRequestTrash() } else { ViewerFallback.confirmAndTrash(browser) }
                    },
                    editEnabled: browser.current.map { editHost.canEdit($0) } ?? false,
                    editHelp: editHost.editHelp(for: browser.current),
                    onEdit: {
                        if let editHandler {
                            editHandler.editBegin()
                        } else if let url = browser.current, editHost.canEdit(url) {
                            let session = EditSession(url: url)
                            editHost.session = session
                            session.load()
                        }
                    })
    }
}

/// Semi-transparent ‹ › button at the media edges (44×64, rounded).
struct ViewerNavButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.92 : 0.3))
                .frame(width: 44, height: 64)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(hovering && enabled ? 0.6 : 0.38)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Centered icon + title + detail, used for empty / error states.
struct ViewerMessageView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(ViewerPalette.secondaryText)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ViewerPalette.primaryText)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(ViewerPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

/// Behaviour used when `ViewerView` is hosted without a window controller.
@MainActor
enum ViewerFallback {
    static func confirmAndTrash(_ browser: FolderBrowser) {
        guard let url = browser.current else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try browser.trashCurrent() } catch { NSAlert(error: error).runModal() }
    }
}
