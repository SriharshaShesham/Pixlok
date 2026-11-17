import SwiftUI
import AppKit

/// Settings window content. Hosted by the shell in an NSWindow (NSHostingController/NSHostingView).
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                SettingsBrowsingSection(settings: settings)
                SettingsFileTypesSection(settings: settings)
                SettingsEditorsSection(settings: settings)
                SettingsDefaultViewerSection(settings: settings)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 760)
        .frame(minHeight: 420, idealHeight: 720, maxHeight: .infinity)
        .background(SettingsPalette.background)
        .tint(SettingsPalette.accent)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Browsing

struct SettingsBrowsingSection: View {
    @ObservedObject var settings: AppSettings
    private static let intervals: [Double] = [2, 3, 5, 10, 20]

    var body: some View {
        SettingsSection(title: "Browsing",
                        subtitle: "How the ← → arrow keys step through the files in a folder.") {
            SettingsRow(label: "Sort files by") {
                Picker("Sort files by", selection: $settings.sortKey) {
                    ForEach(SortKey.allCases) { key in Text(key.label).tag(key) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170, alignment: .leading)

                Picker("Order", selection: $settings.sortAscending) {
                    ForEach(Self.orderOptions(for: settings.sortKey), id: \.ascending) { option in
                        Text(option.label).tag(option.ascending)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150, alignment: .leading)
            }

            SettingsRow(label: "Slideshow interval") {
                Picker("Slideshow interval", selection: $settings.slideshowInterval) {
                    ForEach(intervalChoices, id: \.self) { s in
                        Text(Self.intervalLabel(s)).tag(s)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170, alignment: .leading)
            }

            SettingsRow(label: "") {
                Toggle("Wrap around at the end of the folder", isOn: $settings.wrapAround)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.white)
            }

            SettingsRow(label: "") {
                Toggle("Scroll wheel zooms (off: scroll pans)", isOn: $settings.scrollWheelZooms)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.white)
                    .help("When off, scrolling pans a zoomed image; hold ⌘ or ⌥ while scrolling to zoom.")
            }
        }
    }

    private var intervalChoices: [Double] {
        var list = Self.intervals
        if !list.contains(settings.slideshowInterval) {
            list.append(settings.slideshowInterval)
            list.sort()
        }
        return list
    }

    private static func intervalLabel(_ s: Double) -> String {
        let n = s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
        return "\(n) seconds"
    }

    struct OrderOption { let ascending: Bool; let label: String }

    /// Order labels adapted to the sort key; the natural default comes first.
    static func orderOptions(for key: SortKey) -> [OrderOption] {
        switch key {
        case .dateModified, .dateCreated:
            return [OrderOption(ascending: false, label: "Newest first"),
                    OrderOption(ascending: true, label: "Oldest first")]
        case .name, .type:
            return [OrderOption(ascending: true, label: "A → Z"),
                    OrderOption(ascending: false, label: "Z → A")]
        case .size:
            return [OrderOption(ascending: false, label: "Largest first"),
                    OrderOption(ascending: true, label: "Smallest first")]
        }
    }
}

// MARK: - File types

struct SettingsFileTypesSection: View {
    @ObservedObject var settings: AppSettings
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 4)

    var body: some View {
        SettingsSection(title: "File types to show",
                        subtitle: "Only checked types appear when browsing a folder.") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(FormatRegistry.all) { format in
                    Toggle(isOn: binding(for: format)) {
                        Text(format.label).foregroundStyle(.white)
                    }
                    .toggleStyle(.checkbox)
                    .help(format.extensions.map { "." + $0 }.joined(separator: " "))
                }
            }
            HStack(spacing: 14) {
                SettingsLinkButton(title: "Select all") {
                    settings.enabledFormatIDs = Set(FormatRegistry.all.map(\.id))
                }
                SettingsLinkButton(title: "Select none") {
                    settings.enabledFormatIDs = []
                }
                Spacer()
                Text("\(settings.enabledFormatIDs.count) of \(FormatRegistry.all.count) selected")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
        }
    }

    private func binding(for format: FileFormat) -> Binding<Bool> {
        Binding(
            get: { settings.enabledFormatIDs.contains(format.id) },
            set: { on in
                if on { settings.enabledFormatIDs.insert(format.id) }
                else { settings.enabledFormatIDs.remove(format.id) }
            }
        )
    }
}

// MARK: - Edit in

struct SettingsEditorsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var selectedPath: String?
    @State private var installedApps: [URL] = []
    @State private var iconCache: [String: NSImage] = [:]

    var body: some View {
        SettingsSection(title: "Edit in",
                        subtitle: "Apps offered by the “Edit in” button. The default app is used when you click the button itself.") {
            editorList
            HStack(spacing: 8) {
                addMenu
                Button("Make default") { makeDefault() }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!canMakeDefault)
                Button("Remove") { removeSelected() }
                    .buttonStyle(SettingsButtonStyle(destructive: true))
                    .disabled(selectedPath == nil)
                Spacer()
            }
        }
        .task { await loadInstalledApps() }
    }

    // List

    @ViewBuilder private var editorList: some View {
        VStack(spacing: 0) {
            if settings.editors.isEmpty {
                Text("No apps yet. Use “Add from installed apps…” to add one.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ForEach(Array(settings.editors.enumerated()), id: \.element.id) { index, editor in
                    if index > 0 { Divider().overlay(SettingsPalette.border) }
                    row(editor)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.background))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsPalette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ editor: EditorApp) -> some View {
        let isSelected = selectedPath == editor.path
        let isDefault = settings.primaryEditor?.path == editor.path
        let missing = !FileManager.default.fileExists(atPath: editor.path)
        return HStack(spacing: 10) {
            Image(nsImage: icon(for: editor.path))
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(editor.name).foregroundStyle(.white)
                if missing {
                    Text("Not found — it may have been moved or deleted")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SettingsPalette.danger)
                }
            }
            if isDefault {
                Text("Default")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SettingsPalette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(SettingsPalette.accent.opacity(0.16)))
            }
            Spacer()
            Text(editor.path)
                .font(.system(size: 10.5))
                .foregroundStyle(SettingsPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? SettingsPalette.accent.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectedPath = editor.path
            makeDefault()
        }
        .onTapGesture { selectedPath = editor.path }
        .contextMenu {
            Button("Make default") { selectedPath = editor.path; makeDefault() }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([editor.url])
            }
            Divider()
            Button("Remove") { selectedPath = editor.path; removeSelected() }
        }
    }

    // Add menu

    private var addMenu: some View {
        Menu {
            let available = installedApps.filter { app in
                !settings.editors.contains { $0.path == app.standardizedFileURL.path }
            }
            if available.isEmpty {
                Text(installedApps.isEmpty ? "Looking for apps…" : "All image apps already added")
            } else {
                ForEach(available, id: \.self) { app in
                    Button {
                        add(app)
                    } label: {
                        Label {
                            Text(EditorService.appName(app))
                        } icon: {
                            Image(nsImage: EditorService.icon(app).settingsResized(to: 16))
                        }
                    }
                }
            }
            Divider()
            Button("Choose…") {
                if let app = EditorService.chooseApplication() { add(app) }
            }
        } label: {
            Text("Add from installed apps…")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(SettingsPalette.control))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.border, lineWidth: 1))
    }

    // Actions

    private var canMakeDefault: Bool {
        guard let selectedPath else { return false }
        return settings.primaryEditor?.path != selectedPath
    }

    private func add(_ app: URL) {
        let path = app.standardizedFileURL.path
        if let existing = settings.editors.first(where: { $0.path == path }) {
            selectedPath = existing.path
            return
        }
        // Same app at a different path (e.g. chosen via a symlink) → treat as duplicate too.
        if let bid = Bundle(url: app)?.bundleIdentifier,
           let existing = settings.editors.first(where: { Bundle(path: $0.path)?.bundleIdentifier == bid }) {
            selectedPath = existing.path
            return
        }
        settings.editors.append(EditorApp(path: path, name: EditorService.appName(app)))
        selectedPath = path
    }

    private func makeDefault() {
        guard let selectedPath else { return }
        settings.defaultEditorPath = selectedPath
    }

    private func removeSelected() {
        guard let path = selectedPath,
              let idx = settings.editors.firstIndex(where: { $0.path == path }) else { return }
        settings.editors.remove(at: idx)
        if settings.defaultEditorPath == path { settings.defaultEditorPath = nil }
        if settings.editors.isEmpty {
            selectedPath = nil
        } else {
            selectedPath = settings.editors[min(idx, settings.editors.count - 1)].path
        }
        iconCache[path] = nil
    }

    private func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        return NSWorkspace.shared.icon(forFile: path)
    }

    private func loadInstalledApps() async {
        let apps = await Task.detached(priority: .userInitiated) { () -> [(URL, String)] in
            EditorService.installedImageApps().map { ($0, EditorService.appName($0)) }
        }.value
        installedApps = apps
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map(\.0)
        var cache: [String: NSImage] = [:]
        for e in settings.editors { cache[e.path] = NSWorkspace.shared.icon(forFile: e.path) }
        iconCache = cache
    }
}

// MARK: - Default viewer

struct SettingsDefaultViewerSection: View {
    @ObservedObject var settings: AppSettings
    @State private var defaultCount: Int?
    @State private var isWorking = false
    @State private var resultMessage: String?
    @State private var resultIsError = false
    @State private var statusGeneration = 0

    var body: some View {
        SettingsSection(title: "Default viewer") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open the checked file types with Picsl when double-clicked in Finder.")
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("macOS may ask you to confirm each file type. Choose “Use” to switch.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    statusLine
                }
                Spacer(minLength: 8)
                Button {
                    makeDefault()
                } label: {
                    HStack(spacing: 6) {
                        if isWorking { ProgressView().controlSize(.small) }
                        Text("Make default viewer")
                    }
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .disabled(isWorking || settings.enabledFormatIDs.isEmpty)
            }
            if let resultMessage {
                Text(resultMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(resultIsError ? SettingsPalette.danger : SettingsPalette.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .task { refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    @ViewBuilder private var statusLine: some View {
        let total = FormatRegistry.all.count
        if let defaultCount {
            Text("Currently the default for \(defaultCount) of \(total) types")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsPalette.secondaryText)
        } else {
            Text("Checking current defaults…")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsPalette.secondaryText)
        }
    }

    private func makeDefault() {
        let formats = settings.enabledFormats
        isWorking = true
        resultMessage = nil
        DefaultAppService.makeDefault(for: formats) { result in
            isWorking = false
            switch result {
            case .success:
                // The service counts type identifiers (several per format); report formats instead.
                let n = formats.filter { DefaultAppService.isDefault(for: $0) }.count
                resultIsError = false
                resultMessage = "Picsl is now the default for \(n) of \(formats.count) file type\(formats.count == 1 ? "" : "s")."
            case .failure(let error):
                resultIsError = true
                resultMessage = "Couldn’t make Picsl the default: \(error.localizedDescription)"
            }
            refreshStatus()
        }
    }

    /// Recomputes "default for N of M" off the main thread (LaunchServices lookups can block).
    private func refreshStatus() {
        statusGeneration += 1
        let generation = statusGeneration
        let formats = FormatRegistry.all
        Task {
            let count = await Task.detached(priority: .utility) {
                formats.filter { DefaultAppService.isDefault(for: $0) }.count
            }.value
            if generation == statusGeneration { defaultCount = count }
        }
    }
}
