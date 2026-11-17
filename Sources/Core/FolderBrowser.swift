import Foundation
import AppKit
import Combine

/// The list of viewable files in the opened file's folder, sorted per settings,
/// with a cursor for ←/→ navigation. One instance per viewer window.
@MainActor
final class FolderBrowser: ObservableObject {
    @Published private(set) var items: [URL] = []
    @Published private(set) var index: Int = 0

    let folder: URL
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    var current: URL? { items.indices.contains(index) ? items[index] : nil }
    var count: Int { items.count }
    /// "12 / 87"
    var positionText: String { items.isEmpty ? "0 / 0" : "\(index + 1) / \(items.count)" }

    init(opening url: URL, settings: AppSettings? = nil) {
        let settings = settings ?? AppSettings.shared
        self.settings = settings
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            folder = url
            reload(selecting: nil)
        } else {
            folder = url.deletingLastPathComponent()
            // Show the opened file straight away ("1 / 1") while the folder is listed in the background.
            items = [url.standardizedFileURL]
            index = 0
            reload(selecting: url)
        }
        // Re-list when sort or file-type settings change (debounced; @Published fires in willSet,
        // so the deferred reload sees the new values).
        settings.$sortKey.map { _ in () }
            .merge(with: settings.$sortAscending.map { _ in () }, settings.$enabledFormatIDs.map { _ in () })
            .dropFirst(3)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    /// When the last listing was started (used to debounce focus-triggered reloads).
    private(set) var lastReloadDate: Date = .distantPast

    /// Re-read the folder, keeping the current file selected when it still exists.
    func reload() { reload(selecting: current) }

    /// Lists and sorts the folder off the main thread, then applies the result.
    /// The explicitly opened `target` is always kept, even when its type is disabled or
    /// unsupported (the viewer then shows a "not supported" message instead of another file).
    func reload(selecting target: URL?) {
        reloadTask?.cancel()
        reloadGeneration += 1
        lastReloadDate = Date()
        let gen = reloadGeneration
        let folder = folder
        let enabled = settings.enabledFormatIDs
        let key = settings.sortKey
        let ascending = settings.sortAscending
        let target = target?.standardizedFileURL
        reloadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FolderBrowser.listSnapshot(folder: folder, enabled: enabled, key: key,
                                           ascending: ascending, mustInclude: target)
            }.value
            guard let self, !Task.isCancelled, gen == self.reloadGeneration else { return }
            self.apply(result, keeping: target)
        }
    }

    /// Synchronous variant (self-tests / scripted checks). Cancels any pending async listing.
    func reloadSynchronously(selecting target: URL?) {
        reloadTask?.cancel()
        reloadGeneration += 1
        lastReloadDate = Date()
        let t = target?.standardizedFileURL
        let result = Self.listSnapshot(folder: folder, enabled: settings.enabledFormatIDs,
                                       key: settings.sortKey, ascending: settings.sortAscending, mustInclude: t)
        apply(result, keeping: t)
    }

    private func apply(_ result: [URL], keeping target: URL?) {
        // Re-read `current` at apply time so arrow-key moves made during the listing are kept.
        let keep = target ?? current
        let newIndex: Int
        if let k = keep, let i = result.firstIndex(of: k) {
            newIndex = i
        } else {
            newIndex = min(index, max(result.count - 1, 0))
        }
        // Observers read `current` asynchronously (after both assignments), see ViewerWindowController.
        items = result
        index = newIndex
    }

    func next() { step(1) }
    func previous() { step(-1) }
    func first() { if !items.isEmpty { index = 0 } }
    func last() { if !items.isEmpty { index = items.count - 1 } }

    func select(_ url: URL) {
        if let i = items.firstIndex(of: url.standardizedFileURL) { index = i }
    }

    /// Returns false when at an end and wrap-around is off.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        guard !items.isEmpty else { return false }
        let n = index + delta
        if n >= 0 && n < items.count { index = n; return true }
        guard settings.wrapAround else { return false }
        index = ((n % items.count) + items.count) % items.count
        return true
    }

    /// Moves the current file to the Trash and advances to the next one.
    func trashCurrent() throws {
        guard let url = current else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        // The backup in original/ stays, but it no longer belongs to any visible file.
        EditSaveService.forgetEdit(at: url)
        var list = items
        list.remove(at: index)
        let newIndex = min(index, max(list.count - 1, 0))
        index = newIndex
        items = list
    }

    // MARK: - Listing & sorting

    private nonisolated static let keys: [URLResourceKey] = [
        .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
    ]

    private struct Entry { let url: URL; let mod: Date; let created: Date; let size: Int; let name: String; let ext: String }

    private nonisolated static func entry(_ u: URL, _ v: URLResourceValues?) -> Entry {
        Entry(url: u,
              mod: v?.contentModificationDate ?? .distantPast,
              created: v?.creationDate ?? .distantPast,
              size: v?.fileSize ?? 0,
              name: u.lastPathComponent,
              ext: u.pathExtension.lowercased())
    }

    /// Lists `folder` (thread-safe; works on value snapshots of the settings).
    /// `mustInclude` is added when it exists and was filtered out.
    nonisolated static func listSnapshot(folder: URL, enabled: Set<String>, key: SortKey, ascending: Bool,
                                         mustInclude: URL?) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var entries: [Entry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            guard let f = FormatRegistry.format(for: url), enabled.contains(f.id) else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            entries.append(entry(url.standardizedFileURL, v))
        }
        if let t = mustInclude?.standardizedFileURL, !entries.contains(where: { $0.url == t }),
           FileManager.default.fileExists(atPath: t.path) {
            entries.append(entry(t, try? t.resourceValues(forKeys: Set(keys))))
        }
        return sortEntries(entries, key: key, ascending: ascending).map(\.url)
    }

    static func list(folder: URL, settings: AppSettings) -> [URL] {
        listSnapshot(folder: folder, enabled: settings.enabledFormatIDs, key: settings.sortKey,
                     ascending: settings.sortAscending, mustInclude: nil)
    }

    nonisolated static func sort(_ urls: [URL], key: SortKey, ascending: Bool) -> [URL] {
        let entries = urls.map { entry($0, try? $0.resourceValues(forKeys: Set(keys))) }
        return sortEntries(entries, key: key, ascending: ascending).map(\.url)
    }

    private nonisolated static func sortEntries(_ entries: [Entry], key: SortKey, ascending: Bool) -> [Entry] {
        // Name is the tie-breaker so the order is stable and deterministic.
        func byName(_ a: Entry, _ b: Entry) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return entries.sorted { a, b in
            let primary: ComparisonResult
            switch key {
            case .dateModified: primary = a.mod == b.mod ? .orderedSame : (a.mod < b.mod ? .orderedAscending : .orderedDescending)
            case .dateCreated: primary = a.created == b.created ? .orderedSame : (a.created < b.created ? .orderedAscending : .orderedDescending)
            case .size: primary = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .name: primary = a.name.localizedStandardCompare(b.name)
            case .type: primary = a.ext == b.ext ? .orderedSame : (a.ext < b.ext ? .orderedAscending : .orderedDescending)
            }
            if primary == .orderedSame { return byName(a, b) }
            return ascending ? primary == .orderedAscending : primary == .orderedDescending
        }
    }
}
