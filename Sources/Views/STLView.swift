import SwiftUI
import SceneKit

/// Orbitable 3D view of an STL file: SceneKit viewport + model/info side panel.
struct STLView: View {
    /// Width of the info panel on the right; the shell keeps its overlays clear of it.
    static let sidePanelWidth: CGFloat = 260

    let url: URL
    @StateObject private var model = STLViewModel()

    var body: some View {
        HStack(spacing: 0) {
            viewport
            STLSidePanel(model: model)
        }
        .task(id: url) { await model.load(url) }
    }

    private var viewport: some View {
        ZStack {
            RadialGradient(colors: [STLPalette.gradientCenter, STLPalette.background],
                           center: .center, startRadius: 0, endRadius: 700)

            switch model.phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Loading \(url.lastPathComponent)…")
                        .font(.callout)
                        .foregroundStyle(STLPalette.secondaryText)
                }
            case .failed(let message):
                STLErrorView(fileName: url.lastPathComponent, message: message)
            case .loaded:
                STLSceneRepresentable(view: model.sceneView)
                VStack {
                    Spacer()
                    HStack {
                        Text("Drag to orbit · Scroll to zoom · Shift-drag to pan")
                            .font(.caption)
                            .foregroundStyle(STLPalette.secondaryText)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                    .padding(14)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// MARK: - Palette

enum STLPalette {
    static let background = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)
    static let gradientCenter = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x2B / 255)
    static let panel = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1E / 255)
    static let border = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2E / 255)
    static let button = Color(red: 0x23 / 255, green: 0x23 / 255, blue: 0x27 / 255)
    static let accent = Color(red: 0x4A / 255, green: 0x9E / 255, blue: 0xFF / 255)
    static let accentFill = Color(red: 0x1D / 255, green: 0x33 / 255, blue: 0x50 / 255)
    static let secondaryText = Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA8 / 255)
    static let primaryText = Color(white: 0.92)
}

// MARK: - View model

@MainActor
final class STLViewModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, failed(String) }
    enum RenderMode { case shaded, wireframe }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var info: STLModelInfo?
    @Published var renderMode: RenderMode = .shaded { didSet { applyRenderMode() } }
    @Published var showGrid = true { didSet { loaded?.gridNode.isHidden = !showGrid } }
    @Published var autoRotate = false { didSet { applyAutoRotate() } }

    let sceneView: STLSceneView = {
        let v = STLSceneView(frame: .zero, options: nil)
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = .clear
        v.autoenablesDefaultLighting = false
        v.rendersContinuously = false
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        return v
    }()

    private var loaded: STLLoadedScene?
    private var loadedURL: URL?
    private static let rotateKey = "stl.autorotate"

    func load(_ url: URL) async {
        if url == loadedURL, loaded != nil { return }
        phase = .loading
        info = nil
        loaded = nil
        loadedURL = nil
        sceneView.scene = nil

        let work = Task.detached(priority: .userInitiated) { () throws -> STLLoadedScene in
            try STLSceneBuilder.build(url: url)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            if Task.isCancelled { return }
            install(result, url: url)
        } catch {
            if Task.isCancelled { return }
            if case STLError.cancelled = error { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func install(_ scene: STLLoadedScene, url: URL) {
        loaded = scene
        loadedURL = url
        info = scene.info
        sceneView.scene = scene.scene
        sceneView.pointOfView = scene.cameraNode
        sceneView.defaultCameraController.pointOfView = scene.cameraNode
        sceneView.defaultCameraController.target = scene.target
        sceneView.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
        scene.gridNode.isHidden = !showGrid
        applyRenderMode()
        applyAutoRotate()
        phase = .loaded
    }

    private func applyRenderMode() {
        guard let loaded else { return }
        let mat = renderMode == .shaded ? loaded.shadedMaterial : loaded.wireMaterial
        STLSceneBuilder.applyMaterial(mat, to: loaded.modelNode)
    }

    private func applyAutoRotate() {
        guard let loaded else { return }
        loaded.turntable.removeAction(forKey: Self.rotateKey)
        sceneView.rendersContinuously = autoRotate
        if autoRotate {
            let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 24))
            loaded.turntable.runAction(spin, forKey: Self.rotateKey)
        }
    }

    func show(_ preset: STLSceneBuilder.Preset, animated: Bool = true) {
        guard let loaded else { return }
        sceneView.defaultCameraController.stopInertia()
        let pose = STLSceneBuilder.cameraPose(for: loaded, preset: preset)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.35 : 0
        loaded.cameraNode.position = pose.position
        loaded.cameraNode.look(at: loaded.target, up: pose.up, localFront: SCNVector3(0, 0, -1))
        SCNTransaction.commit()
        sceneView.defaultCameraController.target = loaded.target
    }

    func reset() {
        autoRotate = false
        loaded?.turntable.removeAllActions()
        loaded?.turntable.eulerAngles = SCNVector3(0, 0, 0)
        renderMode = .shaded
        show(.iso)
    }
}

// MARK: - SceneKit host

private struct STLSceneRepresentable: NSViewRepresentable {
    let view: STLSceneView
    func makeNSView(context: Context) -> STLSceneView { view }
    func updateNSView(_ nsView: STLSceneView, context: Context) {}
}

// MARK: - Side panel

private struct STLSidePanel: View {
    @ObservedObject var model: STLViewModel

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    private static let sizeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()

    private var enabled: Bool { model.phase == .loaded }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Model") {
                row("Triangles", model.info.map { Self.countFormatter.string(from: NSNumber(value: $0.triangleCount)) ?? "\($0.triangleCount)" })
                row("Size (mm)", model.info.map { "\(mm($0.width)) × \(mm($0.height)) × \(mm($0.depth))" })
                row("Format", model.info?.formatLabel)
                row("File size", model.info?.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
            }

            section("View") {
                HStack(spacing: 6) {
                    PanelButton(title: "Shaded", selected: model.renderMode == .shaded) { model.renderMode = .shaded }
                    PanelButton(title: "Wireframe", selected: model.renderMode == .wireframe) { model.renderMode = .wireframe }
                    PanelButton(title: "Reset", selected: false) { model.reset() }
                }
                Toggle("Show build plate grid", isOn: $model.showGrid)
                    .toggleStyle(.checkbox)
                Toggle("Auto-rotate", isOn: $model.autoRotate)
                    .toggleStyle(.checkbox)
            }

            section("Camera") {
                HStack(spacing: 6) {
                    PanelButton(title: "Front", selected: false) { model.show(.front) }
                    PanelButton(title: "Top", selected: false) { model.show(.top) }
                    PanelButton(title: "Iso", selected: false) { model.show(.iso) }
                }
            }
            Spacer(minLength: 0)
        }
        .disabled(!enabled)
        .font(.system(size: 12))
        .foregroundStyle(STLPalette.primaryText)
        .padding(16)
        .frame(width: STLView.sidePanelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(STLPalette.panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(STLPalette.border).frame(width: 1)
        }
    }

    private func mm(_ v: Double) -> String {
        Self.sizeFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.1f", v)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(STLPalette.secondaryText)
            content()
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(STLPalette.secondaryText)
            Spacer(minLength: 8)
            Text(value ?? "—")
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct PanelButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : STLPalette.primaryText)
                .background(selected ? STLPalette.accentFill : STLPalette.button,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? STLPalette.accent : STLPalette.border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// MARK: - Error

private struct STLErrorView: View {
    let fileName: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color(red: 1, green: 0x8A / 255, blue: 0x80 / 255))
            Text("Can’t display \(fileName)")
                .font(.headline)
                .foregroundStyle(STLPalette.primaryText)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(STLPalette.secondaryText)
                .frame(maxWidth: 420)
        }
        .padding(24)
    }
}
