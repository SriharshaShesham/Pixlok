import AppKit
import SwiftUI

/// Headless checks for scripted verification (no UI):
///   Pixlok --selftest-list <folder>
///       Prints the folder's viewable files, one path per line, in the order the
///       viewer would step through them with the user's current settings (read directly from the
///       app's preferences; the first-launch settings migration is not run).
///   Pixlok --selftest-list-sorted <folder> <sortKey> <asc|desc>
///       Same, with an explicit sort (dateModified|dateCreated|name|size|type) using a
///       throwaway preferences suite so the real settings are untouched.
///   Pixlok --selftest-snapshot-settings <out.png>
///       Renders the Settings view offscreen to a PNG (visual check without screen recording).
///   Pixlok --selftest-edit <file> <recipe-json>
///       Saves an edit IN PLACE (use scratch copies!) via EditSaveService and prints the saved and
///       original URLs plus size/type/mean colour of the result. See SaveSelfTest for the JSON keys.
///   Pixlok --selftest-revert <file>
///       Reverts an edited file to its original/ copy and prints the restored URL.
///   Pixlok --selftest-originals <empty scratch folder>
///       Builds fixtures there and checks the original/ ownership rules (a user's own Original/
///       folder, stale backups of deleted files, re-save, viewer delete, failed save).
///   Pixlok --selftest-math
///       Crop-drag, flip/straighten and scroll-zoom clamp math.
@MainActor
enum SelfTest {
    static func runIfRequested(_ args: [String]) {
        guard args.count >= 2 else { return }
        switch args[1] {
        case "--selftest-list":
            guard args.count >= 3 else { fail("usage: --selftest-list <folder>") }
            list(folder: args[2], settings: AppSettings(defaults: .standard))
        case "--selftest-list-sorted":
            guard args.count >= 5 else { fail("usage: --selftest-list-sorted <folder> <sortKey> <asc|desc>") }
            guard let key = SortKey.allCases.first(where: { $0.rawValue.lowercased() == args[3].lowercased() }) else {
                fail("unknown sort key '\(args[3])'; use one of: \(SortKey.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let order = args[4].lowercased()
            guard order == "asc" || order == "desc" else { fail("order must be 'asc' or 'desc'") }
            let suite = "Pixlok.selftest.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { fail("cannot create preferences suite") }
            let settings = AppSettings(defaults: defaults)
            settings.sortKey = key
            settings.sortAscending = order == "asc"
            list(folder: args[2], settings: settings, cleanupSuite: suite)
        case "--selftest-snapshot-settings":
            guard args.count >= 3 else { fail("usage: --selftest-snapshot-settings <out.png>") }
            snapshotSettings(to: args[2])
        case "--selftest-edit":
            guard args.count >= 4 else { fail("usage: --selftest-edit <file> <recipe-json>") }
            let path = args[2], json = args[3]
            Task { @MainActor in exit(await SaveSelfTest.runEdit(path: path, recipeJSON: json)) }
            dispatchMain()
        case "--selftest-originals":
            guard args.count >= 3 else { fail("usage: --selftest-originals <empty scratch folder>") }
            exit(OriginalsSelfTest.runOriginals(root: args[2]))
        case "--selftest-math":
            exit(OriginalsSelfTest.runMath())
        case "--selftest-revert":
            guard args.count >= 3 else { fail("usage: --selftest-revert <file>") }
            exit(SaveSelfTest.runRevert(path: args[2]))
        default:
            return
        }
    }

    private static func list(folder path: String, settings: AppSettings, cleanupSuite: String? = nil) -> Never {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            fail("no such file or folder: \(url.path)")
        }
        let browser = FolderBrowser(opening: url, settings: settings)
        browser.reloadSynchronously(selecting: isDir.boolValue ? nil : url)
        var out = ""
        for item in browser.items { out += item.path + "\n" }
        FileHandle.standardOutput.write(Data(out.utf8))
        if let cleanupSuite { removeSuite(cleanupSuite) }
        exit(0)
    }

    /// Clears a throwaway preferences suite and deletes its (now empty) plist so test runs leave nothing behind.
    private static func removeSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        UserDefaults(suiteName: name)?.synchronize()
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    private static func snapshotSettings(to path: String) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let hosting = NSHostingView(rootView: SettingsView(settings: .shared).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 760, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { fail("cannot create bitmap") }
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("cannot encode png") }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { fail("cannot write \(path): \(error)") }
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("selftest: \(message)\n".utf8))
        exit(1)
    }
}
