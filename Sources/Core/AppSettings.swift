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

/// Where a file from a folder that isn't open yet (Finder, Dock, Open With) is shown.
enum OtherFolderPlacement: String, CaseIterable, Identifiable {
    case newWindow, newTab, currentWindow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newWindow: return "In a new window"
        case .newTab: return "In a new tab"
        case .currentWindow: return "In the current window"
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
        /// Every format ID that existed when `enabledFormatIDs` was last saved, so formats added in a
        /// later version can be switched on for people who already have a saved selection.
        static let knownFormats = "knownFormatIDs"
        static let editors = "editors"
        static let defaultEditorPath = "defaultEditorPath"
        static let slideshowInterval = "slideshowInterval"
        static let wrapAround = "wrapAround"
        static let didSeedEditors = "didSeedEditors"
        static let scrollWheelZooms = "scrollWheelZooms"
        static let otherFolderPlacement = "otherFolderPlacement"
        static let checkForUpdates = "checkForUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let skippedUpdateVersion = "skippedUpdateVersion"
    }

    /// Default: Date modified, newest first.
    @Published var sortKey: SortKey { didSet { defaults.set(sortKey.rawValue, forKey: Key.sortKey) } }
    @Published var sortAscending: Bool { didSet { defaults.set(sortAscending, forKey: Key.sortAscending) } }
    /// IDs from `FormatRegistry.all`. Default: all enabled.
    @Published var enabledFormatIDs: Set<String> {
        didSet {
            defaults.set(Array(enabledFormatIDs).sorted(), forKey: Key.enabledFormats)
            defaults.set(FormatRegistry.all.map(\.id).sorted(), forKey: Key.knownFormats)
        }
    }
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

    /// Default: new window. Folders already open in a window always go back to that window.
    @Published var otherFolderPlacement: OtherFolderPlacement {
        didSet { defaults.set(otherFolderPlacement.rawValue, forKey: Key.otherFolderPlacement) }
    }

    /// Daily check for a newer GitHub release (notify only). Default: on.
    @Published var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) } }
    @Published var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: Key.lastUpdateCheck) } }
    /// "Skip This Version": automatic checks stay quiet about this version (manual checks still show it).
    var skippedUpdateVersion: String? {
        get { defaults.string(forKey: Key.skippedUpdateVersion) }
        set { defaults.set(newValue, forKey: Key.skippedUpdateVersion) }
    }

    var didSeedEditors: Bool {
        get { defaults.bool(forKey: Key.didSeedEditors) }
        set { defaults.set(newValue, forKey: Key.didSeedEditors) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sortKey = SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .dateModified
        sortAscending = defaults.object(forKey: Key.sortAscending) as? Bool ?? false
        let allIDs = Set(FormatRegistry.all.map(\.id))
        let savedFormats = defaults.array(forKey: Key.enabledFormats) as? [String]
        var formats = allIDs
        if let savedFormats {
            // Formats added since the selection was saved start out enabled, like on a fresh install.
            let known = (defaults.array(forKey: Key.knownFormats) as? [String]).map(Set.init)
                ?? FormatRegistry.formatIDsBeforeKnownTracking
            formats = Set(savedFormats).union(allIDs.subtracting(known))
        }
        enabledFormatIDs = formats
        // Persist the merged selection (didSet doesn't run during init). Nothing is written when no
        // selection was saved yet, so an untouched domain stays empty (the legacy settings migration
        // only runs into an empty domain).
        if savedFormats != nil,
           (defaults.array(forKey: Key.knownFormats) as? [String]).map(Set.init) != allIDs {
            defaults.set(Array(allIDs).sorted(), forKey: Key.knownFormats)
            defaults.set(Array(formats).sorted(), forKey: Key.enabledFormats)
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
        checkForUpdates = defaults.object(forKey: Key.checkForUpdates) as? Bool ?? true
        lastUpdateCheck = defaults.object(forKey: Key.lastUpdateCheck) as? Date
        otherFolderPlacement = OtherFolderPlacement(
            rawValue: defaults.string(forKey: Key.otherFolderPlacement) ?? "") ?? .newWindow
    }

    // MARK: - One-time migration from the pre-rename bundle ids

    /// Preferences domains used before the app was renamed to Pixlok, newest first.
    /// `io.github.sriharshashesham.picsl` was the Picsl build; `com.macpicviewer.app` the one before it.
    static let legacyDefaultsDomains = ["io.github.sriharshashesham.picsl", "com.macpicviewer.app"]

    /// Settings keys, which never changed across renames.
    private static let settingsKeys = [Key.sortKey, Key.sortAscending, Key.enabledFormats, Key.editors,
                                       Key.defaultEditorPath, Key.slideshowInterval, Key.wrapAround,
                                       Key.didSeedEditors, Key.scrollWheelZooms]

    /// Old key -> new key for one legacy domain. Window frame keys follow the renamed autosave names.
    private static func migratedKeys(from domain: String) -> [(old: String, new: String)] {
        var keys = settingsKeys.map { (old: $0, new: $0) }
        let oldPrefix = domain == "com.macpicviewer.app" ? "MacPicViewer" : "Picsl"
        keys.append((old: "NSWindow Frame \(oldPrefix)Window", new: "NSWindow Frame PixlokWindow"))
        keys.append((old: "NSWindow Frame \(oldPrefix)Settings", new: "NSWindow Frame PixlokSettings"))
        return keys
    }

    /// Every key this migration may write in the current domain.
    private static var currentKeys: [String] {
        settingsKeys + ["NSWindow Frame PixlokWindow", "NSWindow Frame PixlokSettings"]
    }

    /// Copies the known keys once from the newest legacy domain that has any of them, when the
    /// current domain has none of them. Only ever called for the real app domain (`.standard`),
    /// never for self-test suites.
    static func migrateLegacyDefaultsIfNeeded(into defaults: UserDefaults) {
        guard let current = Bundle.main.bundleIdentifier, !legacyDefaultsDomains.contains(current),
              !currentKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        for domain in legacyDefaultsDomains {
            guard let legacy = defaults.persistentDomain(forName: domain), !legacy.isEmpty else { continue }
            let keys = migratedKeys(from: domain)
            guard keys.contains(where: { legacy[$0.old] != nil }) else { continue }
            for (old, new) in keys {
                if let value = legacy[old] { defaults.set(value, forKey: new) }
            }
            return
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
