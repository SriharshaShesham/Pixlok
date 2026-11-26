import AppKit
import SwiftUI

/// Saved signatures / initials: transparent PNGs in
/// ~/Library/Application Support/Pixlok/Signatures (local only, never uploaded).
@MainActor
final class SignatureStore: ObservableObject {
    static let shared = SignatureStore()

    struct Signature: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let image: NSImage
        var cgImage: CGImage? { image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        static func == (a: Signature, b: Signature) -> Bool { a.id == b.id }
    }

    @Published private(set) var signatures: [Signature] = []
    let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pixlok/Signatures", isDirectory: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        signatures = files
            .filter { $0.pathExtension.lowercased() == "png" }
            .compactMap { u -> (Date, Signature)? in
                guard let id = UUID(uuidString: u.deletingPathExtension().lastPathComponent),
                      let img = NSImage(contentsOf: u) else { return nil }
                let date = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return (date, Signature(id: id, url: u, image: img))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    func signature(_ id: UUID) -> Signature? { signatures.first { $0.id == id } }

    @discardableResult
    func add(_ image: CGImage) throws -> UUID {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let url = folder.appendingPathComponent("\(id.uuidString).png")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
        reload()
        return id
    }

    func delete(_ id: UUID) {
        guard let s = signature(id) else { return }
        try? FileManager.default.removeItem(at: s.url)
        reload()
    }

    // MARK: - Image helpers

    /// Crops fully transparent margins (with a little padding).
    static func trimmed(_ image: CGImage, padding: Int = 6) -> CGImage? {
        guard let ctx = rgbaContext(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let w = image.width, h = image.height, bpr = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[y * bpr + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Context rows run top-down in memory; CGImage cropping uses the same top-left origin.
        let rect = CGRect(x: max(0, minX - padding), y: max(0, minY - padding),
                          width: min(w, maxX + padding + 1) - max(0, minX - padding),
                          height: min(h, maxY + padding + 1) - max(0, minY - padding))
        return ctx.makeImage()?.cropping(to: rect)
    }

    /// Paper signature photo → ink on transparent: dark pixels keep their darkness as opacity,
    /// the light paper becomes transparent. The ink is recoloured to `ink`.
    static func removingBackground(_ image: CGImage, ink: NSColor = .black) -> CGImage? {
        let maxSide = 1600
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = rgbaContext(width: w, height: h) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        // Paper level: a bright percentile, so uneven lighting still clears.
        var hist = [Int](repeating: 0, count: 256)
        for y in 0..<h { for x in 0..<w {
            let o = y * bpr + x * 4
            hist[(Int(px[o]) * 299 + Int(px[o + 1]) * 587 + Int(px[o + 2]) * 114) / 1000] += 1
        } }
        var acc = 0, paper = 255
        let target = w * h * 40 / 100
        for v in stride(from: 255, through: 0, by: -1) { acc += hist[v]; if acc >= target { paper = v; break } }
        let paperLevel = max(CGFloat(paper) - 25, 60)
        let c = ink.usingColorSpace(.sRGB) ?? .black
        let ir = UInt8(c.redComponent * 255), ig = UInt8(c.greenComponent * 255), ib = UInt8(c.blueComponent * 255)
        for y in 0..<h { for x in 0..<w {
            let o = y * bpr + x * 4
            let lum = CGFloat(Int(px[o]) * 299 + Int(px[o + 1]) * 587 + Int(px[o + 2]) * 114) / 1000
            var a = (paperLevel - lum) / paperLevel * 1.6
            a = min(max(a, 0), 1)
            let a8 = UInt8(a * 255)
            // Premultiplied.
            px[o] = UInt8(CGFloat(ir) * a); px[o + 1] = UInt8(CGFloat(ig) * a); px[o + 2] = UInt8(CGFloat(ib) * a)
            px[o + 3] = a8
        } }
        return ctx.makeImage()
    }

    static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Renders `text` in `font` as ink on transparent, at 3× for crisp printing.
    static func render(text: String, font: NSFont, color: NSColor) -> CGImage? {
        let big = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 3) ?? font
        let attr = NSAttributedString(string: text, attributes: [.font: big, .foregroundColor: color])
        let size = attr.size()
        let w = Int(ceil(size.width)) + 40, h = Int(ceil(size.height)) + 40
        guard w > 0, h > 0, let ctx = rgbaContext(width: w, height: h) else { return nil }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        attr.draw(at: NSPoint(x: 20, y: 20))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().flatMap { trimmed($0) }
    }
}

// MARK: - Creator sheet

/// "New Signature" sheet: Draw (trackpad / mouse), Type (script fonts) or Image (photo of a
/// signature on paper; the paper is made transparent).
struct SignatureCreatorView: View {
    enum Mode: String, CaseIterable, Identifiable { case draw = "Draw", type = "Type", image = "Image"; var id: String { rawValue } }

    let onDone: (CGImage?) -> Void
    @State private var mode: Mode = .draw
    @StateObject private var pad = SignaturePadModel()
    @State private var typed = ""
    @State private var fontName = SignatureCreatorView.scriptFonts.first ?? "Snell Roundhand"
    @State private var picked: CGImage?
    @State private var inkIndex = 0

    static let inks: [NSColor] = [.black, NSColor(srgbRed: 0.10, green: 0.20, blue: 0.62, alpha: 1)]

    static let scriptFonts: [String] = ["Snell Roundhand", "Savoye LET", "Zapfino", "Apple Chancery",
                                        "Bradley Hand", "Noteworthy", "Marker Felt"]
        .filter { NSFont(name: $0, size: 12) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Signature").font(.system(size: 15, weight: .semibold))
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                switch mode {
                case .draw:
                    SignaturePadView(model: pad, ink: Self.inks[inkIndex])
                    if pad.strokes.isEmpty {
                        Text("Sign here with your trackpad or mouse")
                            .foregroundStyle(.gray).allowsHitTesting(false)
                    }
                case .type:
                    Text(typed.isEmpty ? "Your name" : typed)
                        .font(.custom(fontName, size: 44))
                        .foregroundStyle(typed.isEmpty ? Color.gray.opacity(0.5) : Color(nsColor: Self.inks[inkIndex]))
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                        .padding(.horizontal, 16)
                case .image:
                    if let picked {
                        Image(decorative: picked, scale: 1).resizable().scaledToFit().padding(12)
                    } else {
                        VStack(spacing: 8) {
                            Text("Sign on white paper, take a photo, then choose it.")
                                .foregroundStyle(.gray)
                            Button("Choose Picture…", action: choosePicture)
                        }
                    }
                }
            }
            .frame(width: 460, height: 170)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 1).padding(.horizontal, 30).padding(.bottom, 40)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 10) {
                if mode == .type {
                    TextField("Your name", text: $typed).textFieldStyle(.roundedBorder).frame(width: 180)
                    Picker("", selection: $fontName) {
                        ForEach(Self.scriptFonts, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                if mode == .draw {
                    Button("Clear") { pad.strokes = [] }.disabled(pad.strokes.isEmpty)
                }
                if mode == .image && picked != nil {
                    Button("Choose Another…", action: choosePicture)
                }
                Spacer()
                Text("Ink").foregroundStyle(.secondary)
                ForEach(Self.inks.indices, id: \.self) { i in
                    Circle().fill(Color(nsColor: Self.inks[i])).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: inkIndex == i ? 2 : 0).padding(-3))
                        .onTapGesture {
                            inkIndex = i
                            if mode == .image, let src = sourcePicture { picked = SignatureStore.removingBackground(src, ink: Self.inks[i]) }
                        }
                }
            }

            Text("Signatures are saved only on this Mac, in Pixlok’s Application Support folder.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Save Signature") { onDone(result()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    @State private var sourcePicture: CGImage?

    private var canSave: Bool {
        switch mode {
        case .draw: return !pad.strokes.isEmpty
        case .type: return !typed.trimmingCharacters(in: .whitespaces).isEmpty
        case .image: return picked != nil
        }
    }

    private func result() -> CGImage? {
        switch mode {
        case .draw: return pad.render(ink: Self.inks[inkIndex])
        case .type:
            let font = NSFont(name: fontName, size: 44) ?? .systemFont(ofSize: 44)
            return SignatureStore.render(text: typed.trimmingCharacters(in: .whitespaces), font: font, color: Self.inks[inkIndex])
        case .image: return picked.flatMap { SignatureStore.trimmed($0) }
        }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let u = panel.url,
              let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2000,
              ] as CFDictionary) else { return }
        sourcePicture = img
        picked = SignatureStore.removingBackground(img, ink: Self.inks[inkIndex])
    }
}

@MainActor
final class SignaturePadModel: ObservableObject {
    @Published var strokes: [[CGPoint]] = []
    var canvasSize: CGSize = CGSize(width: 460, height: 170)

    /// Strokes rendered at 3× as smooth ink on transparent, trimmed.
    func render(ink: NSColor) -> CGImage? {
        let scale: CGFloat = 3
        let w = Int(canvasSize.width * scale), h = Int(canvasSize.height * scale)
        guard let ctx = SignatureStore.rgbaContext(width: w, height: h) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(2.4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in strokes {
            ctx.addPath(Self.smoothPath(s, height: canvasSize.height))
            ctx.strokePath()
        }
        return ctx.makeImage().flatMap { SignatureStore.trimmed($0, padding: 8) }
    }

    /// Quadratic smoothing through midpoints; flips SwiftUI's top-left points to CG's bottom-left.
    static func smoothPath(_ pts: [CGPoint], height: CGFloat) -> CGPath {
        let p = pts.map { CGPoint(x: $0.x, y: height - $0.y) }
        let path = CGMutablePath()
        guard let first = p.first else { return path }
        path.move(to: first)
        if p.count < 3 {
            p.dropFirst().forEach { path.addLine(to: $0) }
            if p.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y)) }
            return path
        }
        for i in 1..<(p.count - 1) {
            let mid = CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: p[i])
        }
        path.addLine(to: p[p.count - 1])
        return path
    }
}

struct SignaturePadView: View {
    @ObservedObject var model: SignaturePadModel
    let ink: NSColor
    @State private var current: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                for s in model.strokes + (current.isEmpty ? [] : [current]) {
                    var path = Path(SignaturePadModel.smoothPath(s, height: size.height))
                    path = path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
                    ctx.stroke(path, with: .color(Color(nsColor: ink)),
                               style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { current.append($0.location) }
                .onEnded { _ in
                    if !current.isEmpty { model.strokes.append(current) }
                    current = []
                })
            .onAppear { model.canvasSize = geo.size }
            .onChange(of: geo.size) { model.canvasSize = geo.size }
        }
    }
}
