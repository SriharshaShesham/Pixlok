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
///   Pixlok --selftest-pdf <empty scratch folder>
///       Builds PDF fixtures there and checks loading, unlocking, info fields, listing and the
///       new-format settings migration (throwaway preferences suite).
///   Pixlok --selftest-pdf-edit <empty scratch folder>
///       PDF edit mode end to end: annotations, signature, forms, pages, undo, metadata, password,
///       save with original/ backup, re-save, flattened copy.
///   Pixlok --selftest-update [--offline]
///       Version comparison, release-JSON parsing and notes tidying; without --offline also fetches
///       the latest GitHub release and prints it.
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
            let suite = makeSuiteName()
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
        case "--selftest-pdf-edit":
            guard args.count >= 3 else { fail("usage: --selftest-pdf-edit <empty scratch folder>") }
            exit(PDFEditSelfTest.run(root: args[2]))
        case "--selftest-update":
            let offline = args.contains("--offline")
            Task { @MainActor in exit(await updateSelfTest(offline: offline)) }
            dispatchMain()
        case "--selftest-pdf":
            guard args.count >= 3 else { fail("usage: --selftest-pdf <empty scratch folder>") }
            let root = args[2]
            Task { @MainActor in exit(await PDFSelfTest.run(root: root)) }
            dispatchMain()
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

    /// A throwaway preferences suite for a self-test. It is stored as a plist under the temporary
    /// directory (CFPreferences accepts an absolute path as the domain), never in
    /// ~/Library/Preferences, so nothing is left behind there even though cfprefsd writes the file
    /// back after the process exits.
    static func makeSuiteName() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("Pixlok-selftest-\(UUID().uuidString)")
    }

    /// Clears a throwaway suite made by `makeSuiteName()` and deletes its plist (best-effort; it lives
    /// in the temporary directory either way).
    static func removeSuite(_ name: String) {
        guard name.hasPrefix(NSTemporaryDirectory()) else { return }
        UserDefaults.standard.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }

    private static func snapshotSettings(to path: String) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let hosting = NSHostingView(rootView: SettingsView(settings: .shared).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 760, height: 1100),
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

    // MARK: - Update check

    private static func updateSelfTest(offline: Bool) async -> Int32 {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print((ok ? "ok   " : "FAIL ") + what)
            if !ok { failures += 1 }
        }
        let newer = UpdateService.isVersion
        expect(newer("1.2.0", "1.1.1"), "1.2.0 > 1.1.1")
        expect(newer("1.10.0", "1.9.9"), "1.10.0 > 1.9.9")
        expect(!newer("1.1.1", "1.1.1"), "1.1.1 == 1.1.1")
        expect(!newer("1.1", "1.1.0"), "1.1 == 1.1.0")
        expect(newer("1.1.0.1", "1.1"), "1.1.0.1 > 1.1")
        expect(!newer("1.0.9", "1.1"), "1.0.9 < 1.1")
        expect(newer("2.0.0-beta", "1.9"), "2.0.0-beta > 1.9 (suffix ignored)")

        let json = ###"{"tag_name":"v1.2.0","name":"","html_url":"https://example.com/r","body":"## What's new\n- **Tabs.** New `⌘T`"}"###
        let r = UpdateService.parseRelease(Data(json.utf8))
        expect(r?.version == "1.2.0", "parse tag v1.2.0 → 1.2.0")
        expect(r?.name == "Pixlok 1.2.0", "empty name falls back")
        expect(r?.page.absoluteString == "https://example.com/r", "html_url")
        expect(UpdateService.plainNotes(r?.notes ?? "") == "What's new\n• Tabs. New ⌘T", "notes tidied")
        expect(UpdateService.parseRelease(Data(#"{"tag_name":"nightly"}"#.utf8)) == nil, "non-numeric tag rejected")
        expect(UpdateService.parseRelease(Data("not json".utf8)) == nil, "bad JSON rejected")

        if !offline {
            do {
                let latest = try await UpdateService.fetchLatest()
                print("latest release: \(latest.version) (\(latest.name)) \(latest.page.absoluteString)")
                print("installed: \(UpdateService.currentVersion); newer available: "
                      + "\(newer(latest.version, UpdateService.currentVersion))")
            } catch {
                print("FAIL fetch: \(error.localizedDescription)")
                failures += 1
            }
        }
        print(failures == 0 ? "update self-test passed" : "update self-test: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
}
