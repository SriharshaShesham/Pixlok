import AppKit
import UniformTypeIdentifiers

/// "Make default viewer": registers Picsl as the default app for file types.
enum DefaultAppService {

    enum DefaultAppError: LocalizedError {
        case noTypes
        var errorDescription: String? {
            switch self {
            case .noTypes: return "No file types are selected. Check at least one type under “File types to show”."
            }
        }
    }

    /// Sets this app as default for every UTType of `formats`.
    /// `completion` runs on the main queue with the number of types set, or the first error
    /// (if nothing succeeded). On macOS 26.4+ the system asks the user to confirm each change.
    static func makeDefault(for formats: [FileFormat], completion: @escaping (Result<Int, Error>) -> Void) {
        let types = types(for: formats)
        guard !types.isEmpty else {
            DispatchQueue.main.async { completion(.failure(DefaultAppError.noTypes)) }
            return
        }
        let appURL = Bundle.main.bundleURL
        let group = DispatchGroup()
        let lock = NSLock()
        var successes = 0
        var firstError: Error?
        for type in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                lock.lock()
                if let error {
                    if firstError == nil { firstError = error }
                } else {
                    successes += 1
                }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if successes == 0, let firstError {
                completion(.failure(firstError))
            } else {
                completion(.success(successes))
            }
        }
    }

    /// True when every UTType of `format` currently opens with this app.
    static func isDefault(for format: FileFormat) -> Bool {
        let types = types(for: [format])
        guard !types.isEmpty else { return false }
        let selfPath = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        let selfID = Bundle.main.bundleIdentifier
        return types.allSatisfy { type in
            guard let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
            if app.standardizedFileURL.resolvingSymlinksInPath().path == selfPath { return true }
            if let selfID, Bundle(url: app)?.bundleIdentifier == selfID { return true }
            return false
        }
    }

    /// Declared types plus the concrete types of each extension (e.g. com.canon.cr2-raw-image
    /// under public.camera-raw-image), since Launch Services keeps a separate default per
    /// concrete type. Dynamic `dyn.` types (unknown extensions) are skipped.
    private static func types(for formats: [FileFormat]) -> [UTType] {
        var seen = Set<String>()
        var result: [UTType] = []
        for format in formats {
            let candidates = format.utTypes.compactMap { UTType($0) }
                + format.extensions.compactMap { UTType(filenameExtension: $0) }
            for t in candidates where !t.isDynamic && seen.insert(t.identifier).inserted {
                result.append(t)
            }
        }
        return result
    }
}
