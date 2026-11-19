import SwiftUI
import AppKit
import ImageIO
import AVFoundation
import PDFKit

/// Right-side file info panel (toggled with the (i) button / ⌘I).
struct InfoPanelView: View {
    let url: URL
    @State private var info: InfoPanelFileInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Info")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ViewerPalette.primaryText)
                row("Name", url.lastPathComponent)
                if let info {
                    if let error = info.error {
                        row("Status", error)
                    }
                    if let kind = info.kind { row("Kind", kind) }
                    if let px = info.pixelSize {
                        row("Dimensions", "\(Int(px.width)) × \(Int(px.height)) pixels")
                    }
                    if let d = info.duration { row("Duration", Self.formatDuration(d)) }
                    if let pages = info.pageCount { row("Pages", "\(pages)") }
                    if let size = info.pageSize { row("Page size", Self.formatPageSize(size)) }
                    if let size = info.fileSize {
                        row("File size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let camera = info.camera { row("Camera", camera) }
                    if let taken = info.dateTaken { row("Date taken", taken) }
                    if let m = info.modified { row("Modified", m.formatted(date: .abbreviated, time: .shortened)) }
                    if let c = info.created { row("Created", c.formatted(date: .abbreviated, time: .shortened)) }
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    label("Where")
                    Text(url.deletingLastPathComponent().path)
                        .font(.system(size: 12))
                        .foregroundStyle(ViewerPalette.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .foregroundStyle(ViewerPalette.accent)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ViewerPalette.bar)
        .overlay(alignment: .leading) { Rectangle().fill(ViewerPalette.border).frame(width: 1) }
        .task(id: url) {
            info = nil
            let loaded = await InfoPanelFileInfo.load(url)
            if !Task.isCancelled { info = loaded }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(ViewerPalette.secondaryText)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label(title)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(ViewerPalette.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// PDF points → "210 × 297 mm" or "8.5 × 11 in", per the user's measurement system.
    static func formatPageSize(_ points: CGSize) -> String {
        if Locale.current.measurementSystem == .metric {
            let mm = { (p: CGFloat) in Int((p / 72 * 25.4).rounded()) }
            return "\(mm(points.width)) × \(mm(points.height)) mm"
        }
        let inches = { (p: CGFloat) -> String in
            let v = Double((p / 72 * 100).rounded() / 100)
            return v.formatted(FloatingPointFormatStyle<Double>().precision(.fractionLength(0...2)))
        }
        return "\(inches(points.width)) × \(inches(points.height)) in"
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Metadata shown in the info panel. Loaded off the main thread.
struct InfoPanelFileInfo: Sendable {
    var kind: String?
    var fileSize: Int64?
    var modified: Date?
    var created: Date?
    var pixelSize: CGSize?
    var duration: Double?
    var camera: String?
    var dateTaken: String?
    var pageCount: Int?
    /// First page's visible (crop box) size in PDF points (1/72 inch), after its own rotation.
    var pageSize: CGSize?
    var error: String?

    static func load(_ url: URL) async -> InfoPanelFileInfo {
        let category = FormatRegistry.format(for: url)?.category
        var info = await Task.detached(priority: .utility) { () -> InfoPanelFileInfo in
            var info = InfoPanelFileInfo()
            do {
                let v = try url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey,
                                                         .contentModificationDateKey, .creationDateKey])
                info.kind = v.localizedTypeDescription
                info.fileSize = v.fileSize.map(Int64.init)
                info.modified = v.contentModificationDate
                info.created = v.creationDate
            } catch {
                info.error = "File can’t be read: \(error.localizedDescription)"
                return info
            }
            if category == .raster || category == .svg {
                readImageProperties(url, into: &info)
            } else if category == .pdf {
                readPDFProperties(url, into: &info)
            }
            return info
        }.value
        if category == .video, info.error == nil, !Task.isCancelled {
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration), d.isNumeric {
                info.duration = d.seconds
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(transform)
                info.pixelSize = CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
            }
        }
        return info
    }

    private static func readPDFProperties(_ url: URL, into info: inout InfoPanelFileInfo) {
        guard let doc = PDFDocument(url: url) else { return }
        info.pageCount = doc.pageCount
        if !doc.isLocked, let page = doc.page(at: 0) {
            // The crop box is what PDFView shows (it falls back to the media box when unset).
            let size = page.bounds(for: .cropBox).size
            info.pageSize = page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
        }
    }

    private static func readImageProperties(_ url: URL, into info: inout InfoPanelFileInfo) {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any] else { return }
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            // EXIF orientations 5–8 rotate the picture by 90°.
            info.pixelSize = (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
            if let model, !model.isEmpty {
                if let make, !make.isEmpty, !model.lowercased().hasPrefix(make.lowercased()) {
                    info.camera = "\(make) \(model)"
                } else {
                    info.camera = model
                }
            }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = parser.date(from: taken) {
                info.dateTaken = d.formatted(date: .abbreviated, time: .shortened)
            } else {
                info.dateTaken = taken
            }
        }
    }
}
