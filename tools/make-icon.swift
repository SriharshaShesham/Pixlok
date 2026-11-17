// make-icon.swift - draws the Picsl app icon and builds Resources/AppIcon.icns.
//
// Usage (from the repo root, after `./build.sh typecheck` so build/vfs-overlay.yaml exists):
//   swiftc -O tools/make-icon.swift -o build/make-icon \
//     -vfsoverlay build/vfs-overlay.yaml -Xcc -ivfsoverlay -Xcc build/vfs-overlay.yaml
//   build/make-icon [output-dir]
// Writes <output-dir>/AppIcon.iconset, Resources/AppIcon.icns and build/icon-preview.png.
// (Drop the -vfsoverlay flags if build/vfs-overlay.yaml does not exist.)

import AppKit
import CoreGraphics

// MARK: - Helpers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space,
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

/// Continuous-corner rounded rect ("squircle") as used by modern macOS icons: straight sides,
/// with each corner a superellipse quadrant blended smoothly into the edges.
func squircle(_ r: CGRect, radius: CGFloat = 185, exponent n: CGFloat = 4.2) -> CGPath {
    let p = CGMutablePath()
    // Corner extent is larger than the nominal radius so the curvature eases in gradually.
    let k = radius * 1.28
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: r.maxX - k, y: r.maxY - k), 0),          // top-right
        (CGPoint(x: r.minX + k, y: r.maxY - k), .pi / 2),     // top-left
        (CGPoint(x: r.minX + k, y: r.minY + k), .pi),         // bottom-left
        (CGPoint(x: r.maxX - k, y: r.minY + k), 3 * .pi / 2), // bottom-right
    ]
    let steps = 90
    var first = true
    for (c, start) in corners {
        for i in 0...steps {
            let t = start + CGFloat(i) / CGFloat(steps) * (.pi / 2)
            let ct = cos(t), st = sin(t)
            let x = c.x + k * (ct >= 0 ? 1 : -1) * pow(abs(ct), 2 / n)
            let y = c.y + k * (st >= 0 ? 1 : -1) * pow(abs(st), 2 / n)
            if first { p.move(to: CGPoint(x: x, y: y)); first = false } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
    }
    p.closeSubpath()
    return p
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Drawing (in a 1024 x 1024, y-up coordinate space)

func drawIcon(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x2a1f5c))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile background: deep indigo -> violet -> warm magenta, diagonal.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x1b2a6b)), (0.55, rgb(0x5a2fa8)), (1, rgb(0xd9467a))]),
        start: CGPoint(x: 160, y: 924), end: CGPoint(x: 880, y: 100), options: [])
    // Soft glow in the upper left.
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x6fb6ff, 0.45)), (1, rgb(0x6fb6ff, 0))]),
        startCenter: CGPoint(x: 300, y: 800), startRadius: 0,
        endCenter: CGPoint(x: 300, y: 800), endRadius: 520, options: [])
    // Glossy top sheen.
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xffffff, 0.16)), (0.45, rgb(0xffffff, 0))]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])

    // Back photo card (tilted left), hints at browsing a folder of pictures.
    drawCard(ctx, center: CGPoint(x: 478, y: 540), size: CGSize(width: 520, height: 420),
             angle: 9, back: true)
    // Front photo card (tilted slightly right).
    drawCard(ctx, center: CGPoint(x: 532, y: 488), size: CGSize(width: 560, height: 440),
             angle: -6, back: false)
    ctx.restoreGState()

    // Thin inner rim highlight for definition.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.addPath(bodyPath)
    ctx.setLineWidth(4)
    ctx.setStrokeColor(rgb(0xffffff, 0.18))
    ctx.strokePath()
    ctx.restoreGState()
}

func drawCard(_ ctx: CGContext, center: CGPoint, size: CGSize, angle: CGFloat, back: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle * .pi / 180)
    let frame = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let framePath = roundedRect(frame, 34)

    // Card shadow + white frame.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x0a0630, 0.45))
    ctx.addPath(framePath)
    ctx.setFillColor(back ? rgb(0xe9e4ff) : rgb(0xffffff))
    ctx.fillPath()
    ctx.restoreGState()

    // Subtle paper gradient on the frame.
    ctx.saveGState()
    ctx.addPath(framePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xffffff, 0)), (1, rgb(0xb8b0e0, back ? 0.35 : 0.22))]),
                           start: CGPoint(x: 0, y: frame.maxY), end: CGPoint(x: 0, y: frame.minY), options: [])
    ctx.restoreGState()

    let photo = frame.insetBy(dx: 30, dy: 30)
    let photoPath = roundedRect(photo, 14)
    ctx.addPath(photoPath)
    ctx.clip()

    if back {
        // Back card: muted dusk scene.
        ctx.drawLinearGradient(gradient([(0, rgb(0x8f7fd6)), (1, rgb(0xf0a6c2))]),
                               start: CGPoint(x: 0, y: photo.maxY), end: CGPoint(x: 0, y: photo.minY), options: [])
        ctx.restoreGState()
        return
    }

    // Sky.
    ctx.drawLinearGradient(gradient([(0, rgb(0x3d8bff)), (0.6, rgb(0x8cc8ff)), (1, rgb(0xffd9a8))]),
                           start: CGPoint(x: 0, y: photo.maxY), end: CGPoint(x: 0, y: photo.minY), options: [])

    // Sun with halo.
    let sun = CGPoint(x: photo.maxX - 120, y: photo.maxY - 105)
    ctx.drawRadialGradient(gradient([(0, rgb(0xfff4c2, 0.9)), (1, rgb(0xfff4c2, 0))]),
                           startCenter: sun, startRadius: 30, endCenter: sun, endRadius: 140, options: [])
    let sunR: CGFloat = 52
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: sun.x - sunR, y: sun.y - sunR, width: sunR * 2, height: sunR * 2))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xfff1a0)), (1, rgb(0xffb23e))]),
                           start: CGPoint(x: sun.x, y: sun.y + sunR), end: CGPoint(x: sun.x, y: sun.y - sunR), options: [])
    ctx.restoreGState()

    let l = photo.minX, r = photo.maxX, b = photo.minY, w = photo.width, h = photo.height

    // Far mountain range.
    let far = CGMutablePath()
    far.move(to: CGPoint(x: l, y: b))
    far.addLine(to: CGPoint(x: l, y: b + h * 0.42))
    far.addLine(to: CGPoint(x: l + w * 0.22, y: b + h * 0.60))
    far.addLine(to: CGPoint(x: l + w * 0.40, y: b + h * 0.46))
    far.addLine(to: CGPoint(x: l + w * 0.62, y: b + h * 0.70))
    far.addLine(to: CGPoint(x: l + w * 0.82, y: b + h * 0.50))
    far.addLine(to: CGPoint(x: r, y: b + h * 0.58))
    far.addLine(to: CGPoint(x: r, y: b))
    far.closeSubpath()
    ctx.saveGState()
    ctx.addPath(far)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x6c7fd8)), (1, rgb(0x4a4fa6))]),
                           start: CGPoint(x: 0, y: b + h * 0.70), end: CGPoint(x: 0, y: b), options: [])
    ctx.restoreGState()

    // Near mountain with snow cap.
    let peak = CGPoint(x: l + w * 0.36, y: b + h * 0.78)
    let near = CGMutablePath()
    near.move(to: CGPoint(x: l, y: b))
    near.addLine(to: CGPoint(x: l, y: b + h * 0.22))
    near.addLine(to: peak)
    near.addLine(to: CGPoint(x: l + w * 0.58, y: b + h * 0.44))
    near.addLine(to: CGPoint(x: l + w * 0.70, y: b + h * 0.52))
    near.addLine(to: CGPoint(x: r, y: b + h * 0.18))
    near.addLine(to: CGPoint(x: r, y: b))
    near.closeSubpath()
    ctx.saveGState()
    ctx.addPath(near)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x2f3f9e)), (1, rgb(0x1c1f5e))]),
                           start: CGPoint(x: l, y: peak.y), end: CGPoint(x: r, y: b), options: [])
    // Snow cap: the part of the mountain above a jagged line.
    let snow = CGMutablePath()
    snow.move(to: CGPoint(x: peak.x - 140, y: peak.y + 10))
    snow.addLine(to: CGPoint(x: peak.x + 140, y: peak.y + 10))
    snow.addLine(to: CGPoint(x: peak.x + 62, y: peak.y - 92))
    snow.addLine(to: CGPoint(x: peak.x + 28, y: peak.y - 66))
    snow.addLine(to: CGPoint(x: peak.x - 4, y: peak.y - 98))
    snow.addLine(to: CGPoint(x: peak.x - 36, y: peak.y - 70))
    snow.addLine(to: CGPoint(x: peak.x - 72, y: peak.y - 96))
    snow.closeSubpath()
    ctx.addPath(snow)
    ctx.setFillColor(rgb(0xf4f6ff))
    ctx.fillPath()
    ctx.restoreGState()

    // Foreground hill.
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: l, y: b))
    hill.addLine(to: CGPoint(x: l, y: b + h * 0.16))
    hill.addCurve(to: CGPoint(x: r, y: b + h * 0.24),
                  control1: CGPoint(x: l + w * 0.35, y: b + h * 0.30),
                  control2: CGPoint(x: l + w * 0.65, y: b + h * 0.06))
    hill.addLine(to: CGPoint(x: r, y: b))
    hill.closeSubpath()
    ctx.saveGState()
    ctx.addPath(hill)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x18c29c)), (1, rgb(0x0b7a6e))]),
                           start: CGPoint(x: 0, y: b + h * 0.30), end: CGPoint(x: 0, y: b), options: [])
    ctx.restoreGState()

    ctx.restoreGState()
}

// MARK: - Rendering

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    drawIcon(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("build")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try! render(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// Extra sizes some tools expect (ignored by iconutil but handy to have).
try! render(pixels: 64).write(to: outDir.appendingPathComponent("icon-64.png"))
try! render(pixels: 1024).write(to: outDir.appendingPathComponent("icon-preview.png"))

let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(icns.path)")
print("Preview: \(outDir.appendingPathComponent("icon-preview.png").path)")
