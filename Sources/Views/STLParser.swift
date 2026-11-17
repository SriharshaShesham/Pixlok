import Foundation
import simd

/// Errors produced while reading an STL file.
enum STLError: LocalizedError {
    case unreadable(String)
    case empty
    case notSTL
    case truncated(expected: Int, actual: Int)
    case malformedASCII(line: Int)
    case noTriangles
    case tooLarge(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason): return "The file could not be read. \(reason)"
        case .empty: return "The file is empty."
        case .notSTL: return "This file does not look like an STL model."
        case .truncated(let expected, let actual):
            return "The STL file is truncated (expected \(expected) bytes, found \(actual))."
        case .malformedASCII(let line): return "The ASCII STL file is malformed near line \(line)."
        case .noTriangles: return "The STL file contains no triangles."
        case .tooLarge(let count):
            return "The model is too large to display (\(count) triangles)."
        case .cancelled: return "Loading was cancelled."
        }
    }
}

/// A parsed STL mesh, already converted to SceneKit's coordinate system
/// (STL is Z-up; SceneKit is Y-up), centred on the origin in X/Z and resting
/// on Y = 0. Vertices are un-indexed: 3 per triangle, with a flat per-face normal.
struct STLMesh {
    enum Format { case binary, ascii
        var label: String { self == .binary ? "Binary STL" : "ASCII STL" }
    }

    var format: Format
    var triangleCount: Int
    /// Packed Float32 x,y,z per vertex (3 vertices per triangle).
    var positions: Data
    /// Packed Float32 x,y,z per vertex (face normal repeated per vertex).
    var normals: Data
    /// Extents in original STL axes (X, Y, Z) — assumed millimetres.
    var sizeSTL: SIMD3<Float>
    /// Extents in SceneKit axes after conversion (X, Y-up, Z).
    var sizeScene: SIMD3<Float>
}

enum STLParser {
    /// Hard upper bound to avoid absurd allocations from corrupt headers.
    static let maxTriangles = 25_000_000

    static func parse(url: URL) throws -> STLMesh {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw STLError.unreadable(error.localizedDescription)
        }
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> STLMesh {
        if data.isEmpty { throw STLError.empty }

        // Decide between binary and ASCII. Many binary exporters write "solid"
        // at the start of the 80-byte header, so the size check comes first.
        if data.count >= 84 {
            let count = Int(readUInt32LE(data, at: 80))
            let expected = 84 + count * 50
            if count > 0 && expected == data.count {
                return try parseBinary(data, count: count)
            }
        }
        if looksLikeASCII(data) {
            return try parseASCII(data)
        }
        if data.count >= 84 {
            let count = Int(readUInt32LE(data, at: 80))
            if count > maxTriangles { throw STLError.tooLarge(count) }
            let expected = 84 + count * 50
            if count == 0 { throw STLError.noTriangles }
            // Tolerate trailing padding/garbage after the declared triangles.
            if expected <= data.count { return try parseBinary(data, count: count) }
            throw STLError.truncated(expected: expected, actual: data.count)
        }
        throw STLError.notSTL
    }

    // MARK: - Binary

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            guard offset + 4 <= raw.count else { return 0 }
            return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func parseBinary(_ data: Data, count: Int) throws -> STLMesh {
        if count > maxTriangles { throw STLError.tooLarge(count) }
        var raw = [Float](repeating: 0, count: count * 9)
        try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            try raw.withUnsafeMutableBufferPointer { dst in
                for t in 0..<count {
                    if t & 0xFFFF == 0 && Task.isCancelled { throw STLError.cancelled }
                    let base = 84 + t * 50 + 12 // skip stored normal
                    for k in 0..<9 {
                        let bits = UInt32(littleEndian: src.loadUnaligned(fromByteOffset: base + k * 4, as: UInt32.self))
                        dst[t * 9 + k] = Float(bitPattern: bits)
                    }
                }
            }
        }
        return try buildMesh(raw: raw, triangleCount: count, format: .binary)
    }

    // MARK: - ASCII

    private static func looksLikeASCII(_ data: Data) -> Bool {
        let prefix = data.prefix(512)
        guard let text = String(data: prefix, encoding: .ascii) ?? String(data: prefix, encoding: .utf8) else {
            return false
        }
        let trimmed = text.drop { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" || $0 == "\u{FEFF}" }
        guard trimmed.lowercased().hasPrefix("solid") else { return false }
        // A real ASCII file has "facet" or "endsolid" near the top.
        let lower = text.lowercased()
        return lower.contains("facet") || lower.contains("endsolid") || data.count < 512
    }

    private static func parseASCII(_ data: Data) throws -> STLMesh {
        // Null-terminated copy so strtof can never run past the end.
        var bytes = [UInt8](data)
        bytes.append(0)
        var raw: [Float] = []
        raw.reserveCapacity(max(9, data.count / 28))

        try bytes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let n = buf.count - 1
            var i = 0
            var line = 1
            var seen = 0

            @inline(__always) func isSpace(_ c: UInt8) -> Bool {
                c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12
            }
            @inline(__always) func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c + 32 : c }
            let vertexWord: [UInt8] = Array("vertex".utf8)

            while i < n {
                // Skip whitespace, counting lines.
                while i < n && isSpace(buf[i]) { if buf[i] == 10 { line += 1 }; i += 1 }
                if i >= n { break }
                let start = i
                while i < n && !isSpace(buf[i]) { i += 1 }
                let len = i - start
                guard len == 6 else { continue }
                var match = true
                for k in 0..<6 where lower(buf[start + k]) != vertexWord[k] { match = false; break }
                guard match else { continue }

                for _ in 0..<3 {
                    while i < n && isSpace(buf[i]) { if buf[i] == 10 { line += 1 }; i += 1 }
                    let p = UnsafeMutablePointer<CChar>(OpaquePointer(base + i))
                    var end: UnsafeMutablePointer<CChar>? = nil
                    let v = strtof(p, &end)
                    guard let e = end, e != p else { throw STLError.malformedASCII(line: line) }
                    i += e - p
                    raw.append(v)
                }
                seen += 1
                if seen & 0x3FFF == 0 && Task.isCancelled { throw STLError.cancelled }
            }
        }
        let tris = raw.count / 9
        if tris == 0 { throw STLError.noTriangles }
        if tris > maxTriangles { throw STLError.tooLarge(tris) }
        if raw.count != tris * 9 { raw.removeLast(raw.count - tris * 9) }
        return try buildMesh(raw: raw, triangleCount: tris, format: .ascii)
    }

    // MARK: - Mesh building

    /// `raw` holds 9 floats per triangle in STL coordinates (Z-up).
    private static func buildMesh(raw: [Float], triangleCount count: Int, format: STLMesh.Format) throws -> STLMesh {
        guard count > 0 else { throw STLError.noTriangles }

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var finiteVertices = 0
        raw.withUnsafeBufferPointer { r in
            var j = 0
            while j + 2 < r.count {
                let v = SIMD3<Float>(r[j], r[j + 1], r[j + 2])
                if v.x.isFinite && v.y.isFinite && v.z.isFinite {
                    lo = simd_min(lo, v); hi = simd_max(hi, v); finiteVertices += 1
                }
                j += 3
            }
        }
        guard finiteVertices > 0 else { throw STLError.noTriangles }
        let sizeSTL = hi - lo
        // Centre in X/Y (STL), rest on Z = min.
        let offset = SIMD3<Float>((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z)

        let floatsPerArray = count * 9
        var pos = Data(count: floatsPerArray * MemoryLayout<Float>.size)
        var nrm = Data(count: floatsPerArray * MemoryLayout<Float>.size)

        try raw.withUnsafeBufferPointer { r in
            try pos.withUnsafeMutableBytes { pRaw in
                try nrm.withUnsafeMutableBytes { nRaw in
                    let p = pRaw.bindMemory(to: Float.self)
                    let nb = nRaw.bindMemory(to: Float.self)
                    for t in 0..<count {
                        if t & 0xFFFF == 0 && Task.isCancelled { throw STLError.cancelled }
                        let b = t * 9
                        // Convert Z-up STL (x, y, z) -> Y-up SceneKit (x, z, -y).
                        @inline(__always) func conv(_ k: Int) -> SIMD3<Float> {
                            var s = SIMD3<Float>(r[b + k], r[b + k + 1], r[b + k + 2]) - offset
                            if !(s.x.isFinite && s.y.isFinite && s.z.isFinite) { s = .zero }
                            return SIMD3<Float>(s.x, s.z, -s.y)
                        }
                        @inline(__always) func store(_ v: SIMD3<Float>, _ n: SIMD3<Float>, at o: Int) {
                            p[o] = v.x; p[o + 1] = v.y; p[o + 2] = v.z
                            nb[o] = n.x; nb[o + 1] = n.y; nb[o + 2] = n.z
                        }
                        let a = conv(0), c1 = conv(3), c2 = conv(6)
                        var normal = simd_cross(c1 - a, c2 - a)
                        let len = simd_length(normal)
                        normal = len > 0 && len.isFinite ? normal / len : SIMD3<Float>(0, 1, 0)
                        store(a, normal, at: b)
                        store(c1, normal, at: b + 3)
                        store(c2, normal, at: b + 6)
                    }
                }
            }
        }

        return STLMesh(format: format,
                       triangleCount: count,
                       positions: pos,
                       normals: nrm,
                       sizeSTL: sizeSTL,
                       sizeScene: SIMD3<Float>(sizeSTL.x, sizeSTL.z, sizeSTL.y))
    }
}
