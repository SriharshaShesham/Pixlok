import AppKit
import SceneKit
import ModelIO
import SceneKit.ModelIO
import simd

/// Summary shown in the STL side panel.
struct STLModelInfo: Equatable {
    var triangleCount: Int
    /// Width (X) × Height (Z) × Depth (Y) in STL units, assumed millimetres.
    var width: Double
    var height: Double
    var depth: Double
    var formatLabel: String
    var fileSize: Int64?
}

/// A fully built scene for one STL file. Built off the main thread and handed
/// to the main actor once; SceneKit objects are not mutated concurrently.
final class STLLoadedScene: @unchecked Sendable {
    let scene: SCNScene
    let turntable: SCNNode
    let modelNode: SCNNode
    let gridNode: SCNNode
    let cameraNode: SCNNode
    let shadedMaterial: SCNMaterial
    let wireMaterial: SCNMaterial
    /// Size of the model in SceneKit units (X, Y-up, Z).
    let size: SIMD3<Float>
    let info: STLModelInfo

    init(scene: SCNScene, turntable: SCNNode, modelNode: SCNNode, gridNode: SCNNode, cameraNode: SCNNode,
         shadedMaterial: SCNMaterial, wireMaterial: SCNMaterial, size: SIMD3<Float>, info: STLModelInfo) {
        self.scene = scene; self.turntable = turntable; self.modelNode = modelNode
        self.gridNode = gridNode; self.cameraNode = cameraNode
        self.shadedMaterial = shadedMaterial; self.wireMaterial = wireMaterial
        self.size = size; self.info = info
    }

    var target: SCNVector3 { SCNVector3(0, CGFloat(size.y) / 2, 0) }
    var radius: CGFloat { max(CGFloat(simd_length(size)) / 2, 0.001) }
}

enum STLSceneBuilder {
    static let modelColor = NSColor(srgbRed: 0x5F / 255.0, green: 0x8F / 255.0, blue: 0xCF / 255.0, alpha: 1)
    static let cameraFOV: CGFloat = 35

    /// Parses `url` and builds a scene. Throws STLError (or a ModelIO-derived error).
    static func build(url: URL) throws -> STLLoadedScene {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        let modelNode: SCNNode
        let size: SIMD3<Float>
        var info: STLModelInfo

        do {
            let mesh = try STLParser.parse(url: url)
            try checkCancelled()
            modelNode = SCNNode(geometry: geometry(from: mesh))
            size = mesh.sizeScene
            info = STLModelInfo(triangleCount: mesh.triangleCount,
                                width: Double(mesh.sizeSTL.x), height: Double(mesh.sizeSTL.z),
                                depth: Double(mesh.sizeSTL.y), formatLabel: mesh.format.label,
                                fileSize: fileSize)
        } catch STLError.cancelled {
            throw STLError.cancelled
        } catch let primaryError {
            // Fall back to ModelIO for anything our parser rejected.
            guard let fallback = modelIOFallback(url: url) else { throw primaryError }
            try checkCancelled()
            modelNode = fallback.node
            size = fallback.size
            info = STLModelInfo(triangleCount: fallback.triangles,
                                width: Double(size.x), height: Double(size.y), depth: Double(size.z),
                                formatLabel: "STL", fileSize: fileSize)
        }

        let shaded = SCNMaterial()
        shaded.lightingModel = .blinn
        shaded.diffuse.contents = modelColor
        shaded.specular.contents = NSColor(white: 0.35, alpha: 1)
        shaded.shininess = 0.25
        shaded.isDoubleSided = true

        let wire = SCNMaterial()
        wire.lightingModel = .constant
        wire.diffuse.contents = modelColor.blended(withFraction: 0.25, of: .white) ?? modelColor
        wire.fillMode = .lines
        wire.isDoubleSided = true

        applyMaterial(shaded, to: modelNode)
        modelNode.name = "model"

        let scene = SCNScene()
        scene.background.contents = nil

        let turntable = SCNNode()
        turntable.name = "turntable"
        turntable.addChildNode(modelNode)
        scene.rootNode.addChildNode(turntable)

        let grid = gridNode(for: size)
        scene.rootNode.addChildNode(grid)

        addLights(to: scene, size: size)

        let camera = SCNCamera()
        camera.fieldOfView = cameraFOV
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let loaded = STLLoadedScene(scene: scene, turntable: turntable, modelNode: modelNode, gridNode: grid,
                                    cameraNode: cameraNode, shadedMaterial: shaded, wireMaterial: wire,
                                    size: size, info: info)
        place(loaded, preset: .iso)
        return loaded
    }

    /// Assigns `material` to every geometry in the node's hierarchy.
    static func applyMaterial(_ material: SCNMaterial, to node: SCNNode) {
        node.enumerateHierarchy { n, _ in n.geometry?.materials = [material] }
    }

    private static func checkCancelled() throws {
        if Task.isCancelled { throw STLError.cancelled }
    }

    // MARK: Geometry

    private static func geometry(from mesh: STLMesh) -> SCNGeometry {
        let vertexCount = mesh.triangleCount * 3
        let stride = MemoryLayout<Float>.size * 3
        let posSource = SCNGeometrySource(data: mesh.positions, semantic: .vertex, vectorCount: vertexCount,
                                          usesFloatComponents: true, componentsPerVector: 3,
                                          bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride)
        let nrmSource = SCNGeometrySource(data: mesh.normals, semantic: .normal, vectorCount: vertexCount,
                                          usesFloatComponents: true, componentsPerVector: 3,
                                          bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride)
        var indexData = Data(count: vertexCount * MemoryLayout<UInt32>.size)
        indexData.withUnsafeMutableBytes { raw in
            let idx = raw.bindMemory(to: UInt32.self)
            for i in 0..<vertexCount { idx[i] = UInt32(truncatingIfNeeded: i) }
        }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                         primitiveCount: mesh.triangleCount, bytesPerIndex: MemoryLayout<UInt32>.size)
        return SCNGeometry(sources: [posSource, nrmSource], elements: [element])
    }

    private struct Fallback { var node: SCNNode; var size: SIMD3<Float>; var triangles: Int }

    /// ModelIO path for files our parser could not read. Returns nil if ModelIO fails too.
    private static func modelIOFallback(url: URL) -> Fallback? {
        guard MDLAsset.canImportFileExtension(url.pathExtension.lowercased()) else { return nil }
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { return nil }
        let inner = SCNNode()
        var triangles = 0
        for i in 0..<asset.count {
            guard let mesh = asset.object(at: i) as? MDLMesh else { continue }
            for case let sub as MDLSubmesh in mesh.submeshes ?? [] { triangles += sub.indexCount / 3 }
            inner.addChildNode(SCNNode(geometry: SCNGeometry(mdlMesh: mesh)))
        }
        guard triangles > 0, !inner.childNodes.isEmpty else { return nil }
        // Z-up -> Y-up.
        inner.eulerAngles.x = -.pi / 2
        let outer = SCNNode()
        outer.addChildNode(inner)
        let (lo, hi) = outer.boundingBox
        let size = SIMD3<Float>(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z))
        guard size.x.isFinite, size.y.isFinite, size.z.isFinite, max(size.x, size.y, size.z) > 0 else { return nil }
        inner.position = SCNVector3(-(lo.x + hi.x) / 2, -lo.y, -(lo.z + hi.z) / 2)
        return Fallback(node: outer, size: size, triangles: triangles)
    }

    // MARK: Grid & lights

    private static func niceStep(for span: Float) -> Float {
        let rough = max(span / 12, 0.0001)
        let mag = powf(10, floorf(log10f(rough)))
        for m in [1, 2, 5, 10] as [Float] where mag * m >= rough { return mag * m }
        return mag * 10
    }

    private static func gridNode(for size: SIMD3<Float>) -> SCNNode {
        let footprint = max(size.x, size.z, size.y * 0.5, 0.001)
        let step = niceStep(for: footprint * 1.6)
        let half = ceilf(footprint * 0.8 / step) * step
        let lines = Int((half * 2 / step).rounded())
        var verts: [SCNVector3] = []
        verts.reserveCapacity((lines + 1) * 4)
        let y = CGFloat(-max(size.y, footprint) * 0.0005)
        for i in 0...lines {
            let v = CGFloat(-half + Float(i) * step)
            verts.append(SCNVector3(v, y, CGFloat(-half))); verts.append(SCNVector3(v, y, CGFloat(half)))
            verts.append(SCNVector3(CGFloat(-half), y, v)); verts.append(SCNVector3(CGFloat(half), y, v))
        }
        let indices = (0..<UInt32(verts.count)).map { $0 }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                              elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = NSColor(white: 1, alpha: 0.10)
        mat.writesToDepthBuffer = false
        mat.isDoubleSided = true
        geo.materials = [mat]
        let node = SCNNode(geometry: geo)
        node.name = "grid"
        node.renderingOrder = -1
        return node
    }

    private static func addLights(to scene: SCNScene, size: SIMD3<Float>) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 380
        ambient.color = NSColor(white: 0.85, alpha: 1)
        let ambientNode = SCNNode(); ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        func directional(_ intensity: CGFloat, _ angles: SCNVector3) {
            let l = SCNLight()
            l.type = .directional
            l.intensity = intensity
            l.color = NSColor.white
            let n = SCNNode(); n.light = l; n.eulerAngles = angles
            scene.rootNode.addChildNode(n)
        }
        directional(850, SCNVector3(-CGFloat.pi / 3.2, CGFloat.pi / 5, 0))    // key, above-front-right
        directional(320, SCNVector3(-CGFloat.pi / 6, -CGFloat.pi * 0.75, 0))  // fill from back-left
        directional(180, SCNVector3(CGFloat.pi / 2.5, 0, 0))                  // soft under-light
    }

    // MARK: Camera presets

    enum Preset { case front, top, iso }

    static func cameraPose(for loaded: STLLoadedScene, preset: Preset) -> (position: SCNVector3, up: SCNVector3) {
        let r = loaded.radius
        let dist = r / sin(cameraFOV * .pi / 360) * 1.12
        let t = loaded.target
        switch preset {
        case .front:
            return (SCNVector3(t.x, t.y, t.z + dist), SCNVector3(0, 1, 0))
        case .top:
            return (SCNVector3(t.x, t.y + dist, t.z), SCNVector3(0, 0, -1))
        case .iso:
            let d = simd_normalize(SIMD3<Double>(1, 0.8, 1)) * Double(dist)
            return (SCNVector3(t.x + CGFloat(d.x), t.y + CGFloat(d.y), t.z + CGFloat(d.z)), SCNVector3(0, 1, 0))
        }
    }

    static func place(_ loaded: STLLoadedScene, preset: Preset) {
        let pose = cameraPose(for: loaded, preset: preset)
        loaded.cameraNode.position = pose.position
        loaded.cameraNode.look(at: loaded.target, up: pose.up, localFront: SCNVector3(0, 0, -1))
    }
}

/// SCNView that never takes keyboard focus (the window uses ← / → for file
/// navigation) and adds Shift-drag panning on top of the built-in camera control.
final class STLSceneView: SCNView {
    override var acceptsFirstResponder: Bool { false }
    override func keyDown(with event: NSEvent) { nextResponder?.keyDown(with: event) }

    override func mouseDragged(with event: NSEvent) {
        guard event.modifierFlags.contains(.shift), allowsCameraControl,
              let pov = pointOfView, let cam = pov.camera else {
            super.mouseDragged(with: event)
            return
        }
        let controller = defaultCameraController
        let target = controller.target
        let p = pov.presentation.worldPosition
        let dist = CGFloat(simd_length(SIMD3<Double>(Double(p.x - target.x), Double(p.y - target.y), Double(p.z - target.z))))
        let viewHeight = max(bounds.height, 1)
        let unitsPerPoint = 2 * dist * tan(cam.fieldOfView * .pi / 360) / viewHeight
        controller.translateInCameraSpaceBy(x: Float(-event.deltaX * unitsPerPoint),
                                            y: Float(event.deltaY * unitsPerPoint),
                                            z: 0)
    }
}
