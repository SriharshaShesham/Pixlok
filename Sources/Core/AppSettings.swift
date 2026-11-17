import Foundation
import Combine

enum SortKey: String, CaseIterable, Identifiable, Codable {
    case dateModified, dateCreated, name, size, type
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateModified: return "Date modified"
        case .dateCreated: return "Date created"
        case .name: return "Name"
        case .size: return "Size"
        case .type: return "Type"
        }
    }
}

/// An external app offered under "Edit in".
struct EditorApp: Codable, Hashable, Identifiable {
    var path: String          // absolute path to the .app bundle
    var name: String          // display name
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// App-wide preferences, persisted in UserDefaults. Single shared instance.
@MainActor
final class AppSettings: ObservableObject {
    static let shared: AppSettings = {
        migrateLegacyDefaultsIfNeeded(into: .standard)
        return AppSettings()
    }()

    private let defaults: UserDefaults
    private enum Key {
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let enabledFormats = "enabledFormatIDs"
        static let editors = "editors"
        static let defaultEditorPath = "defaultEditorPath"
        static let slideshowInterval = "slideshowInterval"
        static let wrapAround = "wrapAround"
        static let didSeedEditors = "didSeedEditors"
        static let scrollWheelZooms = "scrollWheelZooms"
    }

    /// Default: Date modified, newest first.
    @Published var sortKey: SortKey { didSet { defaults.set(sortKey.rawValue, forKey: Key.sortKey) } }
    @Published var sortAscending: Bool { didSet { defaults.set(sortAscending, forKey: Key.sortAscending) } }
    /// IDs from `FormatRegistry.all`. Default: all enabled.
    @Published var enabledFormatIDs: Set<String> { didSet { defaults.set(Array(enabledFormatIDs).sorted(), forKey: Key.enabledFormats) } }
    @Published var editors: [EditorApp] { didSet { saveEditors() } }
    /// Path of the editor used by the primary "Edit in …" button. nil → first in `editors`.
    @Published var defaultEditorPath: String? { didSet { defaults.set(defaultEditorPath, forKey: Key.defaultEditorPath) } }
    /// Seconds per slide.
    @Published var slideshowInterval: Double { didSet { defaults.set(slideshowInterval, forKey: Key.slideshowInterval) } }
    /// Arrow past the last file wraps to the first.
    @Published var wrapAround: Bool { didSet { defaults.set(wrapAround, forKey: Key.wrapAround) } }
    /// Plain scroll wheel / two-finger scroll zooms images (true) or pans them (false).
    /// ⌘/⌥-scroll zooms in both modes.
    @Published var scrollWheelZooms: Bool { didSet { defaults.set(scrollWheelZooms, forKey: Key.scrollWheelZooms) } }

    var didSeedEditors: Bool {
        get { defaults.bool(forKey: Key.didSeedEditors) }
        set { defaults.set(newValue, forKey: Key.didSeedEditors) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sortKey = SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .dateModified
        sortAscending = defaults.object(forKey: Key.sortAscending) as? Bool ?? false
        if let ids = defaults.array(forKey: Key.enabledFormats) as? [String] {
            enabledFormatIDs = Set(ids)
        } else {
            enabledFormatIDs = Set(FormatRegistry.all.map(\.id))
        }
        if let data = defaults.data(forKey: Key.editors),
           let list = try? JSONDecoder().decode([EditorApp].self, from: data) {
            editors = list
        } else {
            editors = []
        }
        defaultEditorPath = defaults.string(forKey: Key.defaultEditorPath)
        let interval = defaults.double(forKey: Key.slideshowInterval)
        slideshowInterval = interval > 0 ? interval : 3
        wrapAround = defaults.object(forKey: Key.wrapAround) as? Bool ?? true
        scrollWheelZooms = defaults.object(forKey: Key.scrollWheelZooms) as? Bool ?? true
    }

    // MARK: - One-time migration from the pre-rename bundle id

    /// Preferences domain used before the app was renamed to Picsl.
    static let legacyDefaultsDomain = "com.macpicviewer.app"

    /// Old key → new key. Settings keys are unchanged; window frame keys follow the renamed
    /// autosave names.
    private static let migratedKeys: [(old: String, new: String)] = {
        var keys = [Key.sortKey, Key.sortAscending, Key.enabledFormats, Key.editors, Key.defaultEditorPath,
                    Key.slideshowInterval, Key.wrapAround, Key.didSeedEditors, Key.scrollWheelZooms]
            .map { (old: $0, new: $0) }
        keys.append((old: "NSWindow Frame MacPicViewerWindow", new: "NSWindow Frame PicslWindow"))
        keys.append((old: "NSWindow Frame MacPicViewerSettings", new: "NSWindow Frame PicslSettings"))
        return keys
    }()

    /// Copies the known keys from the legacy domain once, when the current domain has none of them.
    /// Only ever called for the real app domain (`.standard`), never for self-test suites.
    static func migrateLegacyDefaultsIfNeeded(into defaults: UserDefaults) {
        guard Bundle.main.bundleIdentifier != legacyDefaultsDomain,
              let legacy = defaults.persistentDomain(forName: legacyDefaultsDomain), !legacy.isEmpty,
              !migratedKeys.contains(where: { defaults.object(forKey: $0.new) != nil }) else { return }
        for (old, new) in migratedKeys {
            if let value = legacy[old] { defaults.set(value, forKey: new) }
        }
    }

    private func saveEditors() {
        if let data = try? JSONEncoder().encode(editors) { defaults.set(data, forKey: Key.editors) }
    }

    var enabledFormats: [FileFormat] { FormatRegistry.all.filter { enabledFormatIDs.contains($0.id) } }

    func isEnabled(_ url: URL) -> Bool {
        guard let f = FormatRegistry.format(for: url) else { return false }
        return enabledFormatIDs.contains(f.id)
    }

    /// Editor for the primary "Edit in" button.
    var primaryEditor: EditorApp? {
        if let p = defaultEditorPath, let e = editors.first(where: { $0.path == p }) { return e }
        return editors.first
    }
}
