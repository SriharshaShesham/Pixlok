import Foundation
import UniformTypeIdentifiers

/// How a file is rendered.
enum MediaCategory: String, Codable {
    case raster   // decoded by ImageIO / NSImage
    case svg      // vector, rendered via WebKit
    case model3D  // STL via ModelIO + SceneKit
    case video    // AVKit
}

/// One user-toggleable file type in Settings ("File types to show").
struct FileFormat: Identifiable, Hashable {
    let id: String            // stable key stored in UserDefaults
    let label: String         // shown in Settings
    let extensions: [String]  // lowercase, no dot
    let category: MediaCategory
    let utTypes: [String]     // UTType identifiers (Info.plist + default-app registration)
}

enum FormatRegistry {
    static let all: [FileFormat] = [
        FileFormat(id: "jpeg", label: "JPEG", extensions: ["jpg", "jpeg", "jpe", "jfif"], category: .raster, utTypes: ["public.jpeg"]),
        FileFormat(id: "png", label: "PNG", extensions: ["png"], category: .raster, utTypes: ["public.png"]),
        FileFormat(id: "heic", label: "HEIC", extensions: ["heic", "heif"], category: .raster, utTypes: ["public.heic", "public.heif"]),
        FileFormat(id: "gif", label: "GIF", extensions: ["gif"], category: .raster, utTypes: ["com.compuserve.gif"]),
        FileFormat(id: "webp", label: "WebP", extensions: ["webp"], category: .raster, utTypes: ["org.webmproject.webp"]),
        FileFormat(id: "tiff", label: "TIFF", extensions: ["tif", "tiff"], category: .raster, utTypes: ["public.tiff"]),
        FileFormat(id: "bmp", label: "BMP", extensions: ["bmp"], category: .raster, utTypes: ["com.microsoft.bmp"]),
        FileFormat(id: "avif", label: "AVIF", extensions: ["avif"], category: .raster, utTypes: ["public.avif"]),
        FileFormat(id: "jxl", label: "JPEG XL", extensions: ["jxl"], category: .raster, utTypes: ["public.jpeg-xl"]),
        FileFormat(id: "psd", label: "PSD", extensions: ["psd"], category: .raster, utTypes: ["com.adobe.photoshop-image"]),
        FileFormat(id: "raw", label: "RAW", extensions: ["dng", "cr2", "cr3", "nef", "nrw", "arw", "orf", "rw2", "raf", "srw", "pef", "rwl", "3fr", "erf", "kdc", "mrw", "x3f"], category: .raster, utTypes: ["public.camera-raw-image"]),
        FileFormat(id: "ico", label: "ICO", extensions: ["ico"], category: .raster, utTypes: ["com.microsoft.ico"]),
        FileFormat(id: "svg", label: "SVG", extensions: ["svg"], category: .svg, utTypes: ["public.svg-image"]),
        FileFormat(id: "stl", label: "STL", extensions: ["stl"], category: .model3D, utTypes: ["public.standard-tesselated-geometry-format"]),
        FileFormat(id: "mp4", label: "MP4", extensions: ["mp4"], category: .video, utTypes: ["public.mpeg-4"]),
        FileFormat(id: "mov", label: "MOV", extensions: ["mov", "qt"], category: .video, utTypes: ["com.apple.quicktime-movie"]),
        FileFormat(id: "m4v", label: "M4V", extensions: ["m4v"], category: .video, utTypes: ["com.apple.m4v-video"]),
    ]

    private static let byExtension: [String: FileFormat] = {
        var map: [String: FileFormat] = [:]
        for f in all { for e in f.extensions { map[e] = f } }
        return map
    }()

    static func format(for url: URL) -> FileFormat? {
        byExtension[url.pathExtension.lowercased()]
    }

    static func format(id: String) -> FileFormat? {
        all.first { $0.id == id }
    }
}
