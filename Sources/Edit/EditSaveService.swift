import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Writing edits to disk with the "original" folder convention.
///
/// Convention:
/// - On the FIRST save of a file, the untouched file goes to `<folder>/original/<filename>`;
///   the edited image is written at the file's original path. Later saves never overwrite the
///   file already in `original/` (it is the true original).
/// - When ImageIO can't write the source format (RAW, PSD, …) the edited image is written as
///   `<base>.jpg` (`.png` if the image has alpha) next to it, or `<base> edited.jpg`
///   (`<base> edited 2.jpg`, …) if that name is taken; the source still moves to `original/`.
/// - Ownership: a file in `original/` only counts as this app's backup when (a) the hidden file
///   `<folder>/original/.picsl-edits.json` has an `EditRecord` for the edited file's name
///   whose identity (inode, size, modification date) still matches the edited file on disk, and
///   (b) the backup carries the `io.github.sriharshashesham.picsl.original` extended attribute (or
///   matches the inode/size recorded for it). A user's own `Original/` folder, or a backup left behind by a
///   deleted/renamed edited file, is therefore never treated as the backup of an unrelated file.
/// - Backward compatibility: backups made by the earliest builds (before the first rename) carry the legacy xattr
///   `com.macpicviewer.original` and are recorded in `original/.macpicviewer-edits.json`. Both are
///   still recognised. Records from the legacy file are merged under the current file (current wins)
///   and the legacy file is removed once the merged map has been written to the current file.
/// - If `original/<name>` is taken by a file that isn't ours, the backup gets a free name
///   (`<base> 2.<ext>`, …) and the record maps the edited file to it. Nothing is ever overwritten.
/// - Save and revert post `Notification.Name.fileDidChange` (userInfo `"url"`) on the main thread
///   for every URL whose contents changed, appeared or disappeared.
struct EditSaveResult {
    let savedURL: URL      // where the edited image now lives (usually == source URL)
    let originalURL: URL   // where the untouched original lives
}

extension Notification.Name {
    /// Posted on the main thread after a save/revert changed a file. userInfo["url"]: URL.
    static let fileDidChange = Notification.Name("Pixlok.fileDidChange")
}

enum EditSaveService {
    static let originalFolderName = "original"
    // Data identifiers (record file name, owner xattr, legacy names) are kept stable on purpose
    // across app renames: existing backups on users' disks must keep being recognised. Do not
    // rename them with the app.
    static let mappingFileName = ".picsl-edits.json"
    /// Record files written by earlier builds (read and migrated, never written).
    static let legacyMappingFileNames = [".macpicviewer-edits.json"]
    /// Every record-file name this app owns in `original/`.
    static var allMappingFileNames: [String] { [mappingFileName] + legacyMappingFileNames }
    static let jpegQuality = 0.92
    /// Revert moves the edited file to the Trash. Self-tests set this to false (delete instead)
    /// so test runs don't fill the user's Trash.
    nonisolated(unsafe) static var trashEditedOnRevert = true

    enum SaveError: LocalizedError {
        case cannotDecode, cannotRender, cannotWrite(String), noOriginal, fileExists(String)
        var errorDescription: String? {
            switch self {
            case .cannotDecode: return "The image could not be decoded."
            case .cannotRender: return "The edited image could not be rendered."
            case .cannotWrite(let why): return "The edited image could not be written. \(why)"
            case .noOriginal: return "There is no original to revert to."
            case .fileExists(let name): return "“\(name)” already exists."
            }
        }
    }

    /// Default location of the untouched original for a file of the same name.
    static func originalURL(for url: URL) -> URL {
        originalFolder(for: url).appendingPathComponent(url.lastPathComponent)
    }

    static func originalFolder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(originalFolderName, isDirectory: true)
    }

    /// The untouched original this app saved for `url`, or nil. Only returned when `url` is still
    /// the very file this app wrote (see `isOurEdit`) and the backup is marked as ours.
    static func existingOriginal(for url: URL) -> URL? { ownedBackup(for: url)?.backup }

    /// The record and backup URL for `url`, when both still belong to this app.
    static func ownedBackup(for url: URL) -> (record: EditRecord, backup: URL)? {
        let folder = url.deletingLastPathComponent()
        guard let rec = readRecords(folder: folder)[url.lastPathComponent], rec.hasIdentity,
              isSafeName(rec.original), isSafeName(rec.source),
              let id = fileIdentity(url), id == rec.identity else { return nil }
        let backup = originalFolder(for: url).appendingPathComponent(rec.original)
        guard FileManager.default.fileExists(atPath: backup.path), isOwned(backup, record: rec) else { return nil }
        return (rec, backup)
    }

    /// True when `url` is the file this app wrote at its last save (same inode, size and mtime).
    static func isOurEdit(_ url: URL) -> Bool {
        guard let rec = readRecords(folder: url.deletingLastPathComponent())[url.lastPathComponent],
              rec.hasIdentity, let id = fileIdentity(url) else { return false }
        return id == rec.identity
    }

    // MARK: - Ownership marker & identity

    /// Kept stable on purpose across app renames (see the note on `mappingFileName`).
    static let ownerXattr = "io.github.sriharshashesham.picsl.original"
    /// Ownership markers set by earlier builds; still accepted, removed on unmark.
    static let legacyOwnerXattrs = ["com.macpicviewer.original"]

    @discardableResult
    static func markOwned(_ u: URL) -> Bool {
        let value: [UInt8] = [0x31]
        return u.withUnsafeFileSystemRepresentation { p in
            guard let p else { return false }
            return setxattr(p, ownerXattr, value, value.count, 0, XATTR_NOFOLLOW) == 0
        }
    }

    static func unmarkOwned(_ u: URL) {
        u.withUnsafeFileSystemRepresentation { p in
            guard let p else { return }
            for name in [ownerXattr] + legacyOwnerXattrs { _ = removexattr(p, name, XATTR_NOFOLLOW) }
        }
    }

    /// True when `u` carries the current or a legacy ownership marker.
    static func hasOwnerMark(_ u: URL) -> Bool {
        u.withUnsafeFileSystemRepresentation { p in
            guard let p else { return false }
            return ([ownerXattr] + legacyOwnerXattrs).contains { getxattr(p, $0, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
        }
    }

    /// The backup is ours when it carries the marker, or (volumes without xattrs) when it still
    /// has the inode and size recorded for it at save time.
    static func isOwned(_ u: URL, record: EditRecord) -> Bool {
        if hasOwnerMark(u) { return true }
        guard record.backupID != 0, let id = fileIdentity(u) else { return false }
        return id.fileID == record.backupID && id.size == record.backupSize
    }

    struct FileIdentity: Equatable { var fileID: UInt64; var size: Int64; var mtime: Double }

    static func fileIdentity(_ u: URL) -> FileIdentity? {
        var st = stat()
        let ok = u.withUnsafeFileSystemRepresentation { p -> Bool in
            guard let p else { return false }
            return lstat(p, &st) == 0
        }
        guard ok, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return FileIdentity(fileID: UInt64(st.st_ino), size: Int64(st.st_size), mtime: mtime)
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    static func hasOriginal(for url: URL) -> Bool { existingOriginal(for: url) != nil }

    // MARK: - Save

    static func save(_ recipe: EditRecipe, source url: URL) async throws -> EditSaveResult {
        let (result, changed) = try await Task.detached(priority: .userInitiated) {
            try saveSync(recipe, source: url)
        }.value
        await MainActor.run { postChanged(changed) }
        return result
    }

    /// Synchronous save (any thread). Returns the result and the URLs that changed (not yet posted).
    static func saveSync(_ recipe: EditRecipe, source url: URL) throws -> (EditSaveResult, [URL]) {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw SaveError.cannotDecode }
        let srcType = CGImageSourceGetType(src) as String?
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let source = try ImageEditPipeline.loadSourceSync(url, previewMaxPixel: 0)
        let edited = ImageEditPipeline.apply(recipe, to: source.full)

        // Output type and location.
        // Only an untouched file this app itself backed up counts; anything else at original/<name>
        // (a user's own folder, a stale backup of a deleted file) is left alone and not reused.
        let prior = ownedBackup(for: url)
        let priorOriginal = prior?.backup
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let keepFormat: Bool = {
            guard let t = srcType, writable.contains(t), let ut = UTType(t) else { return false }
            if ut.conforms(to: .rawImage) || t == "com.adobe.photoshop-image" { return false }
            return true
        }()
        let outType: String
        let savedURL: URL
        if keepFormat, let t = srcType {
            outType = t; savedURL = url
        } else {
            outType = source.hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier
            savedURL = freeName(base: url.deletingPathExtension().lastPathComponent,
                                ext: source.hasAlpha ? "png" : "jpg", in: folder)
        }

        // Render.
        let outUT = UTType(outType)
        let sourceDepth = (props[kCGImagePropertyDepth] as? Int) ?? 8
        let deep = sourceDepth > 8 && (outUT.map { $0.conforms(to: .png) || $0.conforms(to: .tiff) } ?? false)
        let colorSpace = source.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = ImageEditPipeline.render(edited, colorSpace: colorSpace,
                                                format: deep ? .RGBA16 : .RGBA8,
                                                opaque: !source.hasAlpha) else { throw SaveError.cannotRender }

        // Metadata: keep EXIF/GPS/IPTC/…, pixels are now upright, dimensions updated.
        var meta = props
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                  kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
                  kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed, kCGImagePropertyFileContentsDictionary] {
            meta.removeValue(forKey: k)
        }
        meta[kCGImagePropertyOrientation] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = meta[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = cg.width
            exif[kCGImagePropertyExifPixelYDimension] = cg.height
            meta[kCGImagePropertyExifDictionary] = exif
        }
        if outUT?.conforms(to: .jpeg) == true || outUT?.conforms(to: .heic) == true
            || outUT?.conforms(to: .heif) == true || outType == "org.webmproject.webp" {
            meta[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }

        // 1. Write the edited image to a hidden temp file in the same folder.
        let tempURL = folder.appendingPathComponent(".\(savedURL.lastPathComponent).pixlok-\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, outType as CFString, 1, nil) else {
            let why = fm.isWritableFile(atPath: folder.path)
                ? "This format can't be written."
                : "The folder “\(folder.lastPathComponent)” is read-only."
            throw SaveError.cannotWrite(why)
        }
        CGImageDestinationAddImage(dest, cg, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: tempURL)
            throw SaveError.cannotWrite("Encoding failed.")
        }

        // 2. Swap files into place, rolling back on any error.
        let origFolder = originalFolder(for: url)
        var createdFolder = false
        // Only ever removes an EMPTY folder (rmdir), so a stranded original can never be deleted.
        func cleanupFolder() { if createdFolder { _ = rmdir(origFolder.path) } }

        do {
            if savedURL == url {
                if let prior, let priorOriginal {
                    // Already edited by us: original/ already holds the true original.
                    _ = try fm.replaceItemAt(url, withItemAt: tempURL)
                    // The edited file's identity changed; refresh the record (best effort: if this
                    // fails the next save simply makes a fresh backup, nothing is lost).
                    try? putRecord(edited: url, source: prior.record.source, backup: priorOriginal, folder: folder)
                    return (EditSaveResult(savedURL: url, originalURL: priorOriginal), [url])
                }
                createdFolder = try ensureFolder(origFolder)
                let origURL = freeBackupURL(for: url.lastPathComponent, in: origFolder)
                // Keep the untouched file's inode in original/ (hard link), then atomically replace
                // the visible path. If hard links aren't supported, fall back to move + move.
                // The ownership marker is set only after the swap: before it, both names share an inode.
                if (try? fm.linkItem(at: url, to: origURL)) != nil {
                    do {
                        _ = try fm.replaceItemAt(url, withItemAt: tempURL)
                    } catch {
                        try? fm.removeItem(at: origURL)   // unlink only; `url` still holds the original
                        throw error
                    }
                } else {
                    try fm.moveItem(at: url, to: origURL)
                    do { try fm.moveItem(at: tempURL, to: url) } catch {
                        try? fm.moveItem(at: origURL, to: url)
                        throw error
                    }
                }
                markOwned(origURL)
                do {
                    try putRecord(edited: url, source: url.lastPathComponent, backup: origURL, folder: folder)
                } catch {
                    // Put the untouched file back at its path (the edited version is dropped).
                    // If even that fails the original stays in original/ rather than risk losing it.
                    unmarkOwned(origURL)
                    _ = try? fm.replaceItemAt(url, withItemAt: origURL)
                    throw error
                }
                return (EditSaveResult(savedURL: url, originalURL: origURL), [url])
            } else {
                // Different output file (format not writable).
                try fm.moveItem(at: tempURL, to: savedURL)
                if let prior, let priorOriginal {
                    // The source already has an original; it stays in place, just record the edit.
                    do { try putRecord(edited: savedURL, source: prior.record.source, backup: priorOriginal, folder: folder) }
                    catch { try? fm.removeItem(at: savedURL); throw error }
                    return (EditSaveResult(savedURL: savedURL, originalURL: priorOriginal), [savedURL])
                }
                let origURL: URL
                do {
                    createdFolder = try ensureFolder(origFolder)
                    origURL = freeBackupURL(for: url.lastPathComponent, in: origFolder)
                    try fm.moveItem(at: url, to: origURL)
                } catch {
                    try? fm.removeItem(at: savedURL); throw error
                }
                markOwned(origURL)
                do {
                    try putRecord(edited: savedURL, source: url.lastPathComponent, backup: origURL, folder: folder)
                } catch {
                    unmarkOwned(origURL)
                    try? fm.moveItem(at: origURL, to: url)
                    try? fm.removeItem(at: savedURL)
                    throw error
                }
                return (EditSaveResult(savedURL: savedURL, originalURL: origURL), [savedURL, url])
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            cleanupFolder()
            throw error
        }
    }

    /// `original/<name>` when nothing is there, else `original/<base> 2.<ext>`, `<base> 3.<ext>`, …
    /// Never returns a path that already exists (case-insensitively on the default APFS volume).
    private static func freeBackupURL(for name: String, in origFolder: URL) -> URL {
        let fm = FileManager.default
        let first = origFolder.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) { return first }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let u = origFolder.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    /// Creates `folder` if needed; returns true when it was created by this call.
    private static func ensureFolder(_ folder: URL) throws -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) {
            if isDir.boolValue { return false }
            throw SaveError.fileExists(folder.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return true
    }

    /// `<base>.<ext>`, else `<base> edited.<ext>`, `<base> edited 2.<ext>`, …
    private static func freeName(base: String, ext: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(base).appendingPathExtension(ext)
        if !fm.fileExists(atPath: first.path) { return first }
        var n = 1
        while true {
            let name = n == 1 ? "\(base) edited" : "\(base) edited \(n)"
            let u = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    // MARK: - Revert

    /// Restore the file from `original/` (replacing the edited version) and remove it from `original/`.
    static func revertToOriginal(_ url: URL) throws { try revert(url) }

    /// Revert and return the URL of the restored original (differs from `url` when the edit was
    /// saved under another name, e.g. RAW → .jpg). The edited file goes to the Trash (or is
    /// deleted if the volume has no Trash); `original/` is removed when it becomes empty.
    @discardableResult
    static func revert(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        guard let (rec, orig) = ownedBackup(for: url) else { throw SaveError.noOriginal }
        let restored = folder.appendingPathComponent(rec.source)

        if restored == url {
            var trashed: NSURL?
            do {
                guard trashEditedOnRevert else { throw CocoaError(.featureUnsupported) }
                try fm.trashItem(at: url, resultingItemURL: &trashed)
            } catch {
                // No Trash on this volume: swap in place (edited version is deleted).
                _ = try fm.replaceItemAt(url, withItemAt: orig)
                trashed = nil
            }
            if let trashed = trashed as URL? {
                do { try fm.moveItem(at: orig, to: url) } catch {
                    try? fm.moveItem(at: trashed, to: url)
                    throw error
                }
            }
        } else {
            if fm.fileExists(atPath: restored.path) { throw SaveError.fileExists(restored.lastPathComponent) }
            try fm.moveItem(at: orig, to: restored)
            if fm.fileExists(atPath: url.path) {
                do {
                    guard trashEditedOnRevert else { throw CocoaError(.featureUnsupported) }
                    try fm.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    do { try fm.removeItem(at: url) } catch {
                        try? fm.moveItem(at: restored, to: orig)
                        throw error
                    }
                }
            }
        }
        // The restored file is the user's again, not a backup.
        unmarkOwned(restored)
        try? removeRecord(edited: url.lastPathComponent, folder: folder)
        removeOriginalFolderIfEmpty(folder: folder)
        postChanged(restored == url ? [url] : [url, restored])
        return restored
    }

    /// Called after the viewer deleted `url`: drop its edit record (the backup file itself stays in
    /// original/, it just no longer belongs to any visible file) and remove original/ if now empty.
    static func forgetEdit(at url: URL) {
        let folder = url.deletingLastPathComponent()
        guard readRecords(folder: folder)[url.lastPathComponent] != nil else { return }
        try? removeRecord(edited: url.lastPathComponent, folder: folder)
        removeOriginalFolderIfEmpty(folder: folder)
    }

    private static func removeOriginalFolderIfEmpty(folder: URL) {
        let fm = FileManager.default
        let dir = folder.appendingPathComponent(originalFolderName, isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let ignorable = Set([".DS_Store"] + allMappingFileNames)
        guard items.allSatisfy({ ignorable.contains($0) }) else { return }
        if items.contains(where: { allMappingFileNames.contains($0) }), !readRecords(folder: folder).isEmpty { return }
        try? fm.removeItem(at: dir)
    }

    // MARK: - Edit records

    /// One saved edit: `<folder>/<edited name>` was written by this app from `source` (its name in
    /// the folder before the first save), whose untouched bytes live at `original/<original>`.
    struct EditRecord: Codable, Equatable {
        var source: String
        var original: String
        /// Identity of the edited file right after the save. 0 = legacy entry without identity.
        var fileID: UInt64
        var size: Int64
        var mtime: Double
        /// Identity of the backup (fallback ownership check on volumes without xattrs).
        var backupID: UInt64
        var backupSize: Int64

        var hasIdentity: Bool { fileID != 0 }
        var identity: FileIdentity { FileIdentity(fileID: fileID, size: size, mtime: mtime) }
    }

    private static func mappingURL(folder: URL, name: String = mappingFileName) -> URL {
        folder.appendingPathComponent(originalFolderName, isDirectory: true).appendingPathComponent(name)
    }

    /// All records for `folder`: legacy record files first, the current file on top (it wins on a
    /// name clash unless only the legacy record's identity matches the file on disk).
    static func readRecords(folder: URL) -> [String: EditRecord] {
        var map: [String: EditRecord] = [:]
        for name in legacyMappingFileNames + [mappingFileName] {
            for (edited, newer) in readRecordFile(mappingURL(folder: folder, name: name)) {
                // Same name in two record files (e.g. an older build saved after this one): keep the
                // record whose identity matches the file on disk; prefer the later file otherwise.
                if let older = map[edited] {
                    let disk = fileIdentity(folder.appendingPathComponent(edited))
                    func matches(_ r: EditRecord) -> Bool { r.hasIdentity && disk != nil && disk == r.identity }
                    if !matches(newer), matches(older) { continue }
                }
                map[edited] = newer
            }
        }
        return map
    }

    private static func readRecordFile(_ url: URL) -> [String: EditRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let map = try? JSONDecoder().decode([String: EditRecord].self, from: data) { return map }
        // Legacy format {"edited": "original"}: kept, but without identity it never counts as ours.
        if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            return legacy.mapValues { EditRecord(source: $0, original: $0, fileID: 0, size: 0, mtime: 0, backupID: 0, backupSize: 0) }
        }
        return [:]
    }

    /// Writes `map` (always the full merged map from `readRecords`) to the current record file,
    /// then removes legacy record files: their records are now in the current file, and leaving
    /// them would resurrect records this write just removed.
    private static func writeRecords(_ map: [String: EditRecord], folder: URL) throws {
        let fm = FileManager.default
        let u = mappingURL(folder: folder)
        if map.isEmpty {
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        } else {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(map).write(to: u, options: .atomic)
        }
        for name in legacyMappingFileNames {
            let legacy = mappingURL(folder: folder, name: name)
            // Best effort: if a legacy file cannot be removed (e.g. Finder-locked), a record that
            // reappears from it only counts when its identity still matches the file on disk.
            if fm.fileExists(atPath: legacy.path) { try? fm.removeItem(at: legacy) }
        }
    }

    /// Records that `edited` (already in place) was written by this app, backed up at `backup`.
    private static func putRecord(edited: URL, source: String, backup: URL, folder: URL) throws {
        guard let id = fileIdentity(edited) else { throw SaveError.cannotWrite("The saved file could not be read back.") }
        let bid = fileIdentity(backup)
        var map = readRecords(folder: folder)
        map[edited.lastPathComponent] = EditRecord(source: source, original: backup.lastPathComponent,
                                                   fileID: id.fileID, size: id.size, mtime: id.mtime,
                                                   backupID: bid?.fileID ?? 0, backupSize: bid?.size ?? 0)
        try writeRecords(map, folder: folder)
    }

    private static func removeRecord(edited: String, folder: URL) throws {
        var map = readRecords(folder: folder)
        guard map.removeValue(forKey: edited) != nil else { return }
        try writeRecords(map, folder: folder)
    }

    // MARK: - Notifications

    static func postChanged(_ urls: [URL]) {
        let post = {
            for u in urls { NotificationCenter.default.post(name: .fileDidChange, object: nil, userInfo: ["url": u]) }
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}
