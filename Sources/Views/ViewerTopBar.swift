import SwiftUI
import AppKit

/// 44pt top bar: centered "filename — folder", "Edit in …" split button and Info toggle.
struct ViewerTopBar: View {
    @ObservedObject var browser: FolderBrowser
    @ObservedObject var settings: AppSettings
    @Binding var showInfo: Bool
    /// Edit mode: the edit panel takes the Info slot, and opening the file elsewhere is blocked.
    var isEditing: Bool = false
    weak var handler: ViewerCommandHandler?

    var body: some View {
        ZStack {
            ViewerWindowDragArea()
            title
                .padding(.leading, 90)
                .padding(.trailing, 230)
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                Spacer()
                if let url = browser.current {
                    ViewerEditButton(url: url, settings: settings, handler: handler)
                        .disabled(isEditing)
                        .opacity(isEditing ? 0.5 : 1)
                }
                Button {
                    showInfo.toggle()
                } label: {
                    let on = showInfo && !isEditing
                    Image(systemName: on ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(on ? ViewerPalette.accent : ViewerPalette.primaryText)
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(browser.current == nil || isEditing)
                .help("File info (⌘I)")
            }
            .padding(.trailing, 12)
        }
        .frame(height: 44)
        .background(ViewerPalette.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(ViewerPalette.border).frame(height: 1) }
    }

    private var title: some View {
        let folder = browser.folder.lastPathComponent
        let text: Text
        if let url = browser.current {
            text = Text(url.lastPathComponent).foregroundColor(ViewerPalette.primaryText)
                + Text(" — \(folder)").foregroundColor(ViewerPalette.secondaryText)
        } else {
            text = Text(folder).foregroundColor(ViewerPalette.primaryText)
        }
        return text
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// "Edit in GIMP ▾" split button. Main part opens the file in the primary editor;
/// the ▾ menu lists configured editors, other installed apps, and settings shortcuts.
struct ViewerEditButton: View {
    let url: URL
    @ObservedObject var settings: AppSettings
    weak var handler: ViewerCommandHandler?
    /// Other apps that can open `url` (loaded off the main thread).
    @State private var otherApps: [(url: URL, name: String)] = []

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if isEditable, let editor = settings.primaryEditor {
                    open(with: editor.url)
                } else if !isEditable, let first = otherApps.first {
                    open(with: first.url)
                } else {
                    choose()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paintbrush.pointed")
                        .font(.system(size: 11, weight: .medium))
                    Text(mainTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(ViewerPalette.primaryText)
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(mainHelp)

            Rectangle().fill(ViewerPalette.border).frame(width: 1, height: 16)

            Menu {
                menuContent
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ViewerPalette.primaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .fixedSize()
            .help("Choose an app")
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(ViewerPalette.pill))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ViewerPalette.border))
        .task(id: url) {
            let target = url
            let apps = await Task.detached(priority: .utility) { () -> [(url: URL, name: String)] in
                EditorService.installedApps(for: target).prefix(20).map { ($0, EditorService.appName($0)) }
            }.value
            if !Task.isCancelled { otherApps = apps }
        }
    }

    /// The configured image editors are offered only for raster and SVG files; STL and video
    /// files get "Open in <first capable app>" instead.
    private var isEditable: Bool {
        let c = FormatRegistry.format(for: url)?.category
        return c == .raster || c == .svg
    }

    private var mainTitle: String {
        if isEditable { return settings.primaryEditor.map { "Edit in \($0.name)" } ?? "Open With" }
        return otherApps.first.map { "Open in \($0.name)" } ?? "Open With"
    }

    private var mainHelp: String {
        if isEditable {
            return settings.primaryEditor.map { "Open this file in \($0.name) (⌘E)" } ?? "Open this file in another app"
        }
        return otherApps.first.map { "Open this file in \($0.name) (⌘E)" } ?? "Open this file in another app"
    }

    @ViewBuilder
    private var menuContent: some View {
        let configured: Set<String> = isEditable ? Set(settings.editors.map(\.path)) : []
        let primaryPath = settings.primaryEditor?.path
        if isEditable {
            ForEach(settings.editors) { editor in
                Button(editor.path == primaryPath ? "\(editor.name) (Default)" : editor.name) {
                    open(with: editor.url)
                }
            }
            if !settings.editors.isEmpty { Divider() }
        }
        let others = otherApps.filter { !configured.contains($0.url.standardizedFileURL.path) }
        if !others.isEmpty {
            Section("Other apps") {
                ForEach(others, id: \.url) { app in
                    Button(app.name) { open(with: app.url) }
                }
            }
            Divider()
        }
        Button("Choose Application…") { choose() }
        Button("Edit list in Settings…") { handler?.viewerShowSettings() }
    }

    private func open(with app: URL) {
        if let handler { handler.viewerOpen(with: app) } else { EditorService.open(url, with: app) }
    }

    private func choose() {
        if let handler {
            handler.viewerChooseApplication()
        } else if let app = EditorService.chooseApplication() {
            EditorService.open(url, with: app)
        }
    }
}
