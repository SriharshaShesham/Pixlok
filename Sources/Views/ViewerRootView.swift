import SwiftUI
import AppKit

/// What a viewer window is currently showing. `browser == nil` → empty-state window.
@MainActor
final class ViewerWindowModel: ObservableObject {
    @Published var browser: FolderBrowser?
    /// Edit mode state for this window.
    let editHost = EditHost()
}

/// Root of every viewer window: either the viewer or the "Open a file" empty state.
struct ViewerRootView: View {
    @ObservedObject var model: ViewerWindowModel
    let state: ViewerState
    let settings: AppSettings
    let chrome: ViewerChrome
    weak var handler: ViewerCommandHandler?

    var body: some View {
        Group {
            if let browser = model.browser {
                ViewerView(browser: browser, state: state, settings: settings, chrome: chrome,
                           editHost: model.editHost, handler: handler)
                    .id(ObjectIdentifier(browser))
            } else {
                ViewerEmptyWindowView(handler: handler)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Shown when no file is open: "Open a file or drop one here".
struct ViewerEmptyWindowView: View {
    weak var handler: ViewerCommandHandler?
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ViewerWindowDragArea()
                Text("Pixlok")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ViewerPalette.primaryText)
                    .allowsHitTesting(false)
            }
            .frame(height: 44)
            .background(ViewerPalette.bar)
            .overlay(alignment: .bottom) { Rectangle().fill(ViewerPalette.border).frame(height: 1) }

            ZStack {
                ViewerPalette.background
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(ViewerPalette.secondaryText)
                    Text("Open a file or drop one here")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(ViewerPalette.primaryText)
                    Text("Images, SVG, STL models and videos. Use ← → to browse the folder.")
                        .font(.system(size: 12))
                        .foregroundStyle(ViewerPalette.secondaryText)
                    Button("Open…") { handler?.viewerShowOpenPanel() }
                        .buttonStyle(ViewerAccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 4)
                }
                .padding(40)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(isTargeted ? ViewerPalette.accent : ViewerPalette.border,
                                      style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                )
            }
        }
        .ignoresSafeArea()
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            handler?.viewerOpenFiles(files)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Blue filled button used for primary actions in the viewer.
struct ViewerAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(ViewerPalette.accent.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Rectangle())
    }
}
