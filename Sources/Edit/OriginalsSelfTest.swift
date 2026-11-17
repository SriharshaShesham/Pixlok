import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Headless checks for the original/ ownership rules and the pure edit/zoom math (used by SelfTest):
///   --selftest-originals <empty scratch folder>   builds its own fixtures there and prints
///       "PASS <name>" / "FAIL <name>: why" per scenario; exit code 1 if any failed.
///   --selftest-math                               crop-drag, flip/straighten and scroll-zoom math.
@MainActor
enum OriginalsSelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String, _ why: @autoclosure () -> String = "") {
        if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name): \(why())") }
    }

    // MARK: Fixtures

    /// Writes a solid-colour JPEG of the given size.
    private static func writeJPEG(_ url: URL, r: CGFloat, g: CGFloat, b: CGFloat, w: Int = 64, h: Int = 48) throws {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    private static let exposure: EditRecipe = { var r = EditRecipe(); r.exposure = 0.5; return r }()

    // MARK: Originals

    static func runOriginals(root path: String) -> Int32 {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let fm = FileManager.default
        EditSaveService.trashEditedOnRevert = false
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if let left = try? fm.contentsOfDirectory(atPath: root.path), !left.isEmpty {
                print("error: \(root.path) must be empty"); return 2
            }
            try userOwnOriginalFolder(root.appendingPathComponent("user-original"))
            try staleBackupSameName(root.appendingPathComponent("stale-backup"))
            try resaveKeepsTrueOriginal(root.appendingPathComponent("resave"))
            try viewerDeleteForgetsEdit(root.appendingPathComponent("viewer-delete"))
            try failureLeavesOriginal(root.appendingPathComponent("read-only"))
            try legacyBackupStillOurs(root.appendingPathComponent("legacy-backup"))
            try legacyRecordsMerged(root.appendingPathComponent("legacy-merge"))
            try legacyMarkWithoutRecordNotOurs(root.appendingPathComponent("legacy-unrecorded"))
        } catch {
            failures += 1
            print("FAIL unexpected error: \(error.localizedDescription)")
        }
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// Finding: a user's own Original/photo.jpg must never be treated as our backup.
    private static func userOwnOriginalFolder(_ dir: URL) throws {
        let fm = FileManager.default
        let userFolder = dir.appendingPathComponent("Original", isDirectory: true)
        try fm.createDirectory(at: userFolder, withIntermediateDirectories: true)
        let theirs = userFolder.appendingPathComponent("photo.jpg")
        let photo = dir.appendingPathComponent("photo.jpg")
        try writeJPEG(theirs, r: 1, g: 0, b: 0)
        try writeJPEG(photo, r: 0, g: 0, b: 1, w: 80, h: 60)
        let theirsBefore = bytes(theirs), photoBefore = bytes(photo)

        check(!EditSaveService.hasOriginal(for: photo), "user-original: hasOriginal false before any edit")
        let (res, _) = try EditSaveService.saveSync(exposure, source: photo)
        check(bytes(theirs) == theirsBefore, "user-original: user's Original/photo.jpg untouched")
        check(bytes(res.originalURL) == photoBefore, "user-original: pre-edit photo kept as backup",
              res.originalURL.path)
        check(res.originalURL.standardizedFileURL.path != theirs.standardizedFileURL.path
                || !isCaseInsensitive(dir), "user-original: backup did not reuse the user's file",
              res.originalURL.lastPathComponent)
        check(EditSaveService.hasOwnerMark(res.originalURL), "user-original: backup marked as ours")
        check(!EditSaveService.hasOwnerMark(photo), "user-original: edited file not marked")
        check(bytes(photo) != photoBefore, "user-original: photo.jpg now holds the edit")
        check(EditSaveService.hasOriginal(for: photo), "user-original: hasOriginal true after save")

        let restored = try EditSaveService.revert(photo)
        check(restored == photo && bytes(photo) == photoBefore, "user-original: revert restores the pre-edit bytes")
        check(!EditSaveService.hasOwnerMark(photo), "user-original: restored file unmarked")
        check(bytes(theirs) == theirsBefore, "user-original: user's file still untouched after revert")
        check(!EditSaveService.hasOriginal(for: photo), "user-original: hasOriginal false after revert")
    }

    private static func isCaseInsensitive(_ dir: URL) -> Bool {
        let v = try? dir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return v?.volumeSupportsCaseSensitiveNames == false
    }

    /// Finding: a backup left behind by a deleted edited file must not be used for a new file
    /// that happens to get the same name.
    private static func staleBackupSameName(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("DSC_0001.jpg")
        try writeJPEG(photo, r: 0, g: 1, b: 0)
        let oldBytes = bytes(photo)
        let (first, _) = try EditSaveService.saveSync(exposure, source: photo)
        let oldBackup = first.originalURL
        check(bytes(oldBackup) == oldBytes, "stale-backup: first save backs up the first photo")

        // Deleted outside the viewer (Finder): no forgetEdit, the record stays behind.
        try fm.removeItem(at: photo)
        try writeJPEG(photo, r: 1, g: 1, b: 0, w: 96, h: 72)
        let newBytes = bytes(photo)
        check(!EditSaveService.hasOriginal(for: photo), "stale-backup: new file has no original")

        let (second, _) = try EditSaveService.saveSync(exposure, source: photo)
        check(second.originalURL != oldBackup, "stale-backup: new backup gets its own name",
              second.originalURL.lastPathComponent)
        check(bytes(second.originalURL) == newBytes, "stale-backup: new photo's untouched bytes are in original/")
        check(bytes(oldBackup) == oldBytes, "stale-backup: old backup unchanged")

        let restored = try EditSaveService.revert(photo)
        check(restored == photo && bytes(photo) == newBytes, "stale-backup: revert restores the NEW photo")
        check(bytes(oldBackup) == oldBytes, "stale-backup: old backup still unchanged after revert")
    }

    /// Re-saving an edit keeps the first backup (the true original) and revert returns to it.
    private static func resaveKeepsTrueOriginal(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("photo.jpg")
        try writeJPEG(photo, r: 0.5, g: 0.2, b: 0.2)
        let before = bytes(photo)
        let (a, _) = try EditSaveService.saveSync(exposure, source: photo)
        let firstEdit = bytes(photo)
        let (b, _) = try EditSaveService.saveSync(exposure, source: photo)
        check(a.originalURL == b.originalURL, "resave: second save reuses the same backup",
              "\(a.originalURL.lastPathComponent) vs \(b.originalURL.lastPathComponent)")
        check(bytes(b.originalURL) == before, "resave: backup still holds the true original")
        check(bytes(photo) != firstEdit, "resave: second edit written")
        check(EditSaveService.isOurEdit(photo), "resave: record identity refreshed after re-save")
        let restored = try EditSaveService.revert(photo)
        check(restored == photo && bytes(photo) == before, "resave: revert restores the true original")
        check(!fm.fileExists(atPath: EditSaveService.originalFolder(for: photo).path),
              "resave: empty original/ removed after revert")
    }

    /// The viewer's Delete forgets the record; the backup file stays.
    private static func viewerDeleteForgetsEdit(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("photo.jpg")
        try writeJPEG(photo, r: 0.1, g: 0.6, b: 0.3)
        let before = bytes(photo)
        let (res, _) = try EditSaveService.saveSync(exposure, source: photo)
        try fm.removeItem(at: photo)
        EditSaveService.forgetEdit(at: photo)
        check(EditSaveService.readRecords(folder: dir)["photo.jpg"] == nil, "viewer-delete: record removed")
        check(bytes(res.originalURL) == before, "viewer-delete: backup file kept")
    }

    /// A failed save (read-only folder) leaves the original at its path and creates nothing.
    private static func failureLeavesOriginal(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("photo.jpg")
        try writeJPEG(photo, r: 0.3, g: 0.3, b: 0.9)
        let before = bytes(photo)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        var threw = false
        do { _ = try EditSaveService.saveSync(exposure, source: photo) } catch { threw = true }
        check(threw, "read-only: save fails")
        check(bytes(photo) == before, "read-only: original untouched at its path")
        check(!fm.fileExists(atPath: EditSaveService.originalFolder(for: photo).path), "read-only: no original/ created")
    }

    // MARK: Legacy (pre-rename) backups

    private static var legacyXattr: String { EditSaveService.legacyOwnerXattrs[0] }
    private static var legacyMapName: String { EditSaveService.legacyMappingFileNames[0] }

    private static func setXattr(_ u: URL, _ name: String) {
        let value: [UInt8] = [0x31]
        _ = u.withUnsafeFileSystemRepresentation { p in setxattr(p!, name, value, value.count, 0, XATTR_NOFOLLOW) }
    }

    private static func hasXattr(_ u: URL, _ name: String) -> Bool {
        u.withUnsafeFileSystemRepresentation { p in getxattr(p!, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    }

    private static func mapURL(_ dir: URL, _ name: String) -> URL {
        dir.appendingPathComponent(EditSaveService.originalFolderName, isDirectory: true).appendingPathComponent(name)
    }

    private static func decodeMap(_ u: URL) -> [String: EditSaveService.EditRecord]? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode([String: EditSaveService.EditRecord].self, from: d)
    }

    private static func encodeMap(_ map: [String: EditSaveService.EditRecord], to u: URL) throws {
        try JSONEncoder().encode(map).write(to: u, options: .atomic)
    }

    /// Turns a fresh save's backup into exactly what the pre-rename build left on disk:
    /// legacy xattr only, records only in the legacy record file.
    private static func makeLegacy(_ backup: URL, dir: URL) throws {
        let fm = FileManager.default
        backup.withUnsafeFileSystemRepresentation { p in _ = removexattr(p!, EditSaveService.ownerXattr, XATTR_NOFOLLOW) }
        setXattr(backup, legacyXattr)
        let cur = mapURL(dir, EditSaveService.mappingFileName), old = mapURL(dir, legacyMapName)
        if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
        try fm.moveItem(at: cur, to: old)
    }

    /// A backup made by the pre-rename build (legacy xattr + legacy record file) is still ours:
    /// re-save reuses it, revert restores it byte-identically, and the records migrate.
    private static func legacyBackupStillOurs(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("photo.jpg")
        try writeJPEG(photo, r: 0.7, g: 0.4, b: 0.1)
        let before = bytes(photo)
        let (a, _) = try EditSaveService.saveSync(exposure, source: photo)
        try makeLegacy(a.originalURL, dir: dir)
        check(!hasXattr(a.originalURL, EditSaveService.ownerXattr) && hasXattr(a.originalURL, legacyXattr)
                && !fm.fileExists(atPath: mapURL(dir, EditSaveService.mappingFileName).path)
                && fm.fileExists(atPath: mapURL(dir, legacyMapName).path),
              "legacy-backup: fixture looks like a pre-rename save")

        check(EditSaveService.hasOwnerMark(a.originalURL), "legacy-backup: legacy xattr counts as owner mark")
        check(EditSaveService.isOurEdit(photo), "legacy-backup: legacy record identifies the edited file")
        check(EditSaveService.existingOriginal(for: photo) == a.originalURL, "legacy-backup: legacy backup recognised")

        let firstEdit = bytes(photo)
        let (b, _) = try EditSaveService.saveSync(exposure, source: photo)
        check(a.originalURL == b.originalURL, "legacy-backup: second save reuses the legacy backup",
              "\(a.originalURL.lastPathComponent) vs \(b.originalURL.lastPathComponent)")
        check(bytes(b.originalURL) == before, "legacy-backup: backup still holds the true original")
        check(bytes(photo) != firstEdit, "legacy-backup: second edit written")
        let items = (try? fm.contentsOfDirectory(atPath: EditSaveService.originalFolder(for: photo).path)) ?? []
        check(items.count == 2, "legacy-backup: no extra backup created", "\(items)")
        check(decodeMap(mapURL(dir, EditSaveService.mappingFileName))?["photo.jpg"] != nil,
              "legacy-backup: record migrated to the current record file")
        check(!fm.fileExists(atPath: mapURL(dir, legacyMapName).path), "legacy-backup: legacy record file retired")
        check(EditSaveService.isOurEdit(photo), "legacy-backup: identity refreshed after re-save")

        let restored = try EditSaveService.revert(photo)
        check(restored == photo && bytes(photo) == before, "legacy-backup: revert restores byte-identical original")
        check(!hasXattr(photo, legacyXattr) && !hasXattr(photo, EditSaveService.ownerXattr),
              "legacy-backup: restored file carries no marker")
        check(!fm.fileExists(atPath: EditSaveService.originalFolder(for: photo).path),
              "legacy-backup: empty original/ removed after revert")
    }

    /// Records in the legacy file are honoured next to current ones; current wins on conflict;
    /// removing a record never lets the legacy file resurrect it; cleanup knows both file names.
    private static func legacyRecordsMerged(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldPhoto = dir.appendingPathComponent("old.jpg"), newPhoto = dir.appendingPathComponent("new.jpg")
        try writeJPEG(oldPhoto, r: 0.2, g: 0.8, b: 0.8)
        let oldBefore = bytes(oldPhoto)
        let (oldRes, _) = try EditSaveService.saveSync(exposure, source: oldPhoto)
        try makeLegacy(oldRes.originalURL, dir: dir)          // "old.jpg" was edited by the old build
        try writeJPEG(newPhoto, r: 0.9, g: 0.1, b: 0.5, w: 72, h: 40)
        let newBefore = bytes(newPhoto)
        let (newRes, _) = try EditSaveService.saveSync(exposure, source: newPhoto)   // migrates "old.jpg" record

        // Rebuild the split state: legacy file holds old.jpg plus a bogus conflicting new.jpg entry.
        let cur = mapURL(dir, EditSaveService.mappingFileName), old = mapURL(dir, legacyMapName)
        guard var merged = decodeMap(cur), let oldRec = merged.removeValue(forKey: "old.jpg"),
              let newRec = merged["new.jpg"] else { check(false, "legacy-merge: fixture records"); return }
        var bogus = newRec; bogus.fileID &+= 12345; bogus.original = "old.jpg"
        try encodeMap(["old.jpg": oldRec, "new.jpg": bogus], to: old)
        try encodeMap(["new.jpg": newRec], to: cur)

        let recs = EditSaveService.readRecords(folder: dir)
        check(recs["old.jpg"] == oldRec, "legacy-merge: legacy-only record is read")
        check(recs["new.jpg"] == newRec, "legacy-merge: current record wins over legacy on conflict")
        check(EditSaveService.existingOriginal(for: oldPhoto) == oldRes.originalURL, "legacy-merge: legacy backup recognised")
        check(EditSaveService.existingOriginal(for: newPhoto) == newRes.originalURL, "legacy-merge: current backup recognised")

        let r1 = try EditSaveService.revert(oldPhoto)
        check(r1 == oldPhoto && bytes(oldPhoto) == oldBefore, "legacy-merge: revert of legacy edit is byte-identical")
        check(EditSaveService.readRecords(folder: dir)["old.jpg"] == nil, "legacy-merge: reverted record not resurrected")
        check(!fm.fileExists(atPath: old.path), "legacy-merge: legacy record file retired on write")
        check(EditSaveService.readRecords(folder: dir)["new.jpg"] == newRec, "legacy-merge: other record kept")

        let r2 = try EditSaveService.revert(newPhoto)
        check(r2 == newPhoto && bytes(newPhoto) == newBefore, "legacy-merge: revert of current edit is byte-identical")
        check(!fm.fileExists(atPath: EditSaveService.originalFolder(for: newPhoto).path),
              "legacy-merge: empty original/ removed")

        // Viewer delete with only a legacy record file: record dropped, original/ cleaned up;
        // with a user's file beside it, the folder and that file stay.
        let orig = EditSaveService.originalFolder(for: newPhoto)
        let gone = dir.appendingPathComponent("gone.jpg")
        let legacyOnly = EditSaveService.EditRecord(source: "gone.jpg", original: "gone.jpg", fileID: 0, size: 0,
                                                    mtime: 0, backupID: 0, backupSize: 0)
        try fm.createDirectory(at: orig, withIntermediateDirectories: false)
        try encodeMap(["gone.jpg": legacyOnly], to: old)
        EditSaveService.forgetEdit(at: gone)
        check(!fm.fileExists(atPath: orig.path), "legacy-merge: original/ with only legacy records file removed")
        try fm.createDirectory(at: orig, withIntermediateDirectories: false)
        try encodeMap(["gone.jpg": legacyOnly], to: old)
        let user = orig.appendingPathComponent("keep.txt")
        try Data("user".utf8).write(to: user)
        EditSaveService.forgetEdit(at: gone)
        check(fm.fileExists(atPath: user.path) && EditSaveService.readRecords(folder: dir).isEmpty,
              "legacy-merge: user's file in original/ kept, legacy record forgotten")
    }

    /// A file in original/ carrying the legacy xattr but no matching record is NOT ours.
    private static func legacyMarkWithoutRecordNotOurs(_ dir: URL) throws {
        let fm = FileManager.default
        let orig = dir.appendingPathComponent(EditSaveService.originalFolderName, isDirectory: true)
        try fm.createDirectory(at: orig, withIntermediateDirectories: true)
        let theirs = orig.appendingPathComponent("photo.jpg"), photo = dir.appendingPathComponent("photo.jpg")
        try writeJPEG(theirs, r: 1, g: 0, b: 1)
        setXattr(theirs, legacyXattr)
        try writeJPEG(photo, r: 0, g: 1, b: 1, w: 50, h: 50)
        let theirsBefore = bytes(theirs), photoBefore = bytes(photo)
        check(!EditSaveService.hasOriginal(for: photo), "legacy-unrecorded: marked file without record not ours")
        let (res, _) = try EditSaveService.saveSync(exposure, source: photo)
        check(res.originalURL != theirs && bytes(theirs) == theirsBefore, "legacy-unrecorded: existing file untouched",
              res.originalURL.lastPathComponent)
        check(bytes(res.originalURL) == photoBefore, "legacy-unrecorded: new backup holds pre-edit bytes")
        _ = try EditSaveService.revert(photo)
        check(bytes(photo) == photoBefore && bytes(theirs) == theirsBefore, "legacy-unrecorded: revert ok, other file kept")
    }

    // MARK: Math

    static func runMath() -> Int32 {
        // Scroll zoom never reverses direction after a pinch beyond the scroll range.
        check(ScrollZoomMath.target(current: 30, factor: 1.1, fit: 0.5, isFit: false, minScale: 0.05, maxScale: 16) == nil,
              "zoom: at 3000% scrolling in does not zoom out")
        if case .scale(let s)? = ScrollZoomMath.target(current: 30, factor: 0.9, fit: 0.5, isFit: false, minScale: 0.05, maxScale: 16) {
            check(abs(s - 27) < 1e-9, "zoom: at 3000% scrolling out zooms out", "\(s)")
        } else { check(false, "zoom: at 3000% scrolling out zooms out") }
        check(ScrollZoomMath.target(current: 0.02, factor: 0.9, fit: 0.07, isFit: false, minScale: 0.05, maxScale: 16) == nil,
              "zoom: at 2% scrolling out does not zoom in")
        if case .scale(let s)? = ScrollZoomMath.target(current: 0.02, factor: 1.1, fit: 0.07, isFit: false, minScale: 0.05, maxScale: 16) {
            check(abs(s - 0.022) < 1e-9, "zoom: at 2% scrolling in zooms in", "\(s)")
        } else { check(false, "zoom: at 2% scrolling in zooms in") }

        // Crop: aspect-locked corner shrinks with a one-axis inward drag.
        let b = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let r0 = CGRect(x: 100, y: 100, width: 400, height: 300)   // 4:3
        let left = CropGeometry.drag(.bottomRight, start: r0, translation: CGSize(width: -50, height: 0),
                                     bounds: b, ratio: 4.0 / 3.0, minSize: 32)
        check(abs(left.width - 350) < 0.01 && abs(left.height - 262.5) < 0.01, "crop: corner dragged straight left shrinks", "\(left)")
        let up = CropGeometry.drag(.bottomRight, start: r0, translation: CGSize(width: 0, height: -60),
                                   bounds: b, ratio: 4.0 / 3.0, minSize: 32)
        check(abs(up.height - 240) < 0.01, "crop: corner dragged straight up shrinks", "\(up)")
        let grow = CropGeometry.drag(.bottomRight, start: r0, translation: CGSize(width: 40, height: 0),
                                     bounds: b, ratio: 4.0 / 3.0, minSize: 32)
        check(grow.width > r0.width, "crop: corner dragged outward grows", "\(grow)")

        // Crop: aspect-locked edge drag grows a crop that touches the top edge.
        let top = CGRect(x: 100, y: 0, width: 320, height: 180)     // 16:9 at the top
        let wider = CropGeometry.drag(.right, start: top, translation: CGSize(width: 160, height: 0),
                                      bounds: b, ratio: 16.0 / 9.0, minSize: 32)
        check(abs(wider.width - 480) < 0.01 && wider.minY >= 0 && wider.maxY <= b.maxY + 0.001,
              "crop: right edge grows a crop touching the top", "\(wider)")
        let side = CGRect(x: 0, y: 100, width: 320, height: 180)
        let taller = CropGeometry.drag(.bottom, start: side, translation: CGSize(width: 0, height: 90),
                                       bounds: b, ratio: 16.0 / 9.0, minSize: 32)
        check(abs(taller.height - 270) < 0.01 && taller.minX >= 0, "crop: bottom edge grows a crop touching the left", "\(taller)")

        // Flip mirrors the straighten angle.
        var seed = EditRecipe(); seed.straighten = 4
        let session = EditSession(url: URL(fileURLWithPath: "/nonexistent.jpg"), initialRecipe: seed)
        session.flip(horizontal: true)
        check(session.recipe.straighten == -4 && session.recipe.flipHorizontal, "flip: horizontal flip negates straighten")
        session.flip(horizontal: false)
        check(session.recipe.straighten == 4, "flip: vertical flip negates straighten again")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
