import SwiftUI
import AppKit

/// Colours of the dark graphite viewer design.
enum ViewerPalette {
    static let background = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)   // #141416
    static let bar = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x21 / 255)          // #1E1E21
    static let border = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2E / 255)       // #2A2A2E
    static let pill = Color(red: 0x23 / 255, green: 0x23 / 255, blue: 0x27 / 255)         // #232327
    static let secondaryText = Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA8 / 255) // #A0A0A8
    static let accent = Color(red: 0x4A / 255, green: 0x9E / 255, blue: 0xFF / 255)       // #4A9EFF
    static let danger = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x80 / 255)       // #FF8A80
    static let primaryText = Color(white: 0.93)

    static let nsBackground = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
}

/// Window-level presentation state that is not part of `ViewerState`
/// (controls auto-hide during a slideshow, full-screen status).
@MainActor
final class ViewerChrome: ObservableObject {
    /// During a slideshow the bars/arrows/toolbar are hidden until the mouse moves.
    @Published var controlsVisible = true
    @Published var isFullScreen = false
    /// Height of the system title bar + tab bar while the window's tab bar is shown (the viewer
    /// sits below it); 0 otherwise, when our own top bar holds the traffic lights.
    @Published var tabBarInset: CGFloat = 0
}

private struct ViewerTopBarLeadingKey: EnvironmentKey {
    static let defaultValue: CGFloat = 80
}

extension EnvironmentValues {
    /// Leading space the top bar keeps free: room for the traffic lights, unless a tab bar moved
    /// them out of our bar.
    var viewerTopBarLeading: CGFloat {
        get { self[ViewerTopBarLeadingKey.self] }
        set { self[ViewerTopBarLeadingKey.self] = newValue }
    }
}

/// Actions the SwiftUI viewer forwards to its window controller.
/// When no handler is attached, `ViewerView` falls back to simple built-in behaviour.
@MainActor
protocol ViewerCommandHandler: AnyObject {
    /// Ask for confirmation, then move the current file to the Trash.
    func viewerRequestTrash()
    func viewerToggleSlideshow()
    func viewerOpenInPrimaryEditor()
    func viewerOpen(with app: URL)
    func viewerChooseApplication()
    func viewerShowSettings()
    func viewerOpenFiles(_ urls: [URL])
    func viewerShowOpenPanel()
    /// Open / New window / New tab commands from the top bar's open button.
    func viewerPerform(_ action: ViewerOpenAction)
}

/// What the top bar's "Open ▾" button can do.
enum ViewerOpenAction {
    /// Choose a file or folder and show it in this window.
    case openHere
    /// Choose a folder and show it in this window.
    case openFolderHere
    /// Choose a file or folder and show it in a new window / new tab.
    case openInNewWindow, openInNewTab
    /// Empty new window / tab.
    case newWindow, newTab
}

/// Lets a SwiftUI area start a window drag (our own top bar replaces the hidden title bar).
struct ViewerWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
