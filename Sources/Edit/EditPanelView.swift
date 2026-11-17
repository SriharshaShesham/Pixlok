import SwiftUI

/// Right-hand edit panel: Light / Color / Detail / Crop & Rotate sections in a scroll view,
/// with a sticky footer (Revert to Original · Cancel · Save).
struct EditPanelView: View {
    @ObservedObject var session: EditSession
    weak var handler: EditCommandHandler?

    static let width: CGFloat = 280
    static let panelColor = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1E / 255)   // #1B1B1E

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ViewerPalette.border)
            ScrollView(.vertical) {
                EditPanelSections(session: session)
                    .padding(16)
            }
            .scrollIndicators(.automatic)
            .disabled(session.source == nil || session.isSaving)
            footer
        }
        .font(.system(size: 12))
        .foregroundStyle(ViewerPalette.primaryText)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Self.panelColor)
        .overlay(alignment: .leading) { Rectangle().fill(ViewerPalette.border).frame(width: 1) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Edit")
                .font(.system(size: 13, weight: .semibold))
            if session.source != nil {
                let s = session.outputPixelSize
                Text(verbatim: "\(Int(s.width)) × \(Int(s.height))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(ViewerPalette.secondaryText)
            }
            Spacer()
            CompareButton(session: session)
                .disabled(session.source == nil || session.isSaving)
            Button("Reset all") { session.resetAll() }
                .buttonStyle(EditLinkButtonStyle())
                .disabled(session.isSaving || (session.recipe.isIdentity && !session.isCropping))
                .help("Undo every adjustment")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = session.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(ViewerPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if session.hasOriginal {
                Button {
                    handler?.editRequestRevert()
                } label: {
                    Label("Revert to Original", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(EditLinkButtonStyle())
                .disabled(session.isSaving)
                .help("Put back the untouched file kept in the “original” folder")
            }
            HStack(spacing: 8) {
                if session.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving…").foregroundStyle(ViewerPalette.secondaryText)
                }
                Spacer()
                Button("Cancel") { handler?.editRequestCancel() }
                    .buttonStyle(EditPanelButtonStyle(selected: false, fixed: true))
                    .disabled(session.isSaving)
                    .help("Leave edit mode (Esc)")
                Button("Save") { handler?.editSave() }
                    .buttonStyle(EditPanelButtonStyle(selected: false, prominent: true, fixed: true))
                    .disabled(!session.canSave)
                    .help("Save over the file; the untouched original is kept in “original/” (⌘S)")
            }
        }
        .padding(16)
        .background(Self.panelColor)
        .overlay(alignment: .top) { Rectangle().fill(ViewerPalette.border).frame(height: 1) }
    }
}

/// The scrollable adjustment sections of the edit panel.
struct EditPanelSections: View {
    @ObservedObject var session: EditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            lightSection
            colorSection
            detailSection
            cropSection
        }
        .font(.system(size: 12))
        .foregroundStyle(ViewerPalette.primaryText)
    }

    // MARK: Sections

    private var lightSection: some View {
        EditSection(title: "Light", canReset: lightChanged, onReset: session.resetLight) {
            EditSliderRow(label: "Exposure", value: $session.recipe.exposure, range: -3...3, format: EditSliderRow.evFormat)
            EditSliderRow(label: "Brightness", value: $session.recipe.brightness, range: -1...1)
            EditSliderRow(label: "Contrast", value: $session.recipe.contrast, range: -1...1)
            EditSliderRow(label: "Highlights", value: $session.recipe.highlights, range: -1...1)
            EditSliderRow(label: "Shadows", value: $session.recipe.shadows, range: -1...1)
        }
    }

    private var colorSection: some View {
        EditSection(title: "Color", canReset: colorChanged, onReset: session.resetColor) {
            EditSliderRow(label: "Saturation", value: $session.recipe.saturation, range: -1...1)
            EditSliderRow(label: "Vibrance", value: $session.recipe.vibrance, range: -1...1)
            EditSliderRow(label: "Warmth", value: $session.recipe.temperature, range: -1...1)
            EditSliderRow(label: "Tint", value: $session.recipe.tint, range: -1...1)
        }
    }

    private var detailSection: some View {
        EditSection(title: "Detail", canReset: session.recipe.sharpness != 0, onReset: session.resetDetail) {
            EditSliderRow(label: "Sharpness", value: $session.recipe.sharpness, range: 0...1,
                          format: EditSliderRow.unsignedPercentFormat)
        }
    }

    private var cropSection: some View {
        EditSection(title: "Crop & Rotate", canReset: geometryChanged, onReset: session.resetGeometry) {
            Button {
                session.toggleCrop()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "crop")
                    Text(session.isCropping ? "Apply Crop" : (session.recipe.crop == nil ? "Crop" : "Adjust Crop"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(EditPanelButtonStyle(selected: session.isCropping))
            .help(session.isCropping ? "Apply the crop (Return)" : "Show the crop frame")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(CropAspect.allCases) { aspect in
                    Button { session.setCropAspect(aspect) } label: {
                        Text(aspectLabel(aspect)).frame(maxWidth: .infinity)
                    }
                        .buttonStyle(EditPanelButtonStyle(selected: session.cropAspect == aspect, compact: true))
                        .help(aspectHelp(aspect))
                }
            }

            HStack(spacing: 6) {
                iconButton("rotate.left", help: "Rotate left (⌘L)") { session.rotate(clockwise: false) }
                iconButton("rotate.right", help: "Rotate right (⌘R)") { session.rotate(clockwise: true) }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal",
                           selected: session.recipe.flipHorizontal) { session.flip(horizontal: true) }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertical",
                           selected: session.recipe.flipVertical) { session.flip(horizontal: false) }
                iconButton("rectangle.portrait.rotate", help: "Swap crop orientation (landscape ↔ portrait)") {
                    session.toggleCropOrientation()
                }
                .disabled(!session.cropAspectCanSwap)
            }

            EditSliderRow(label: "Straighten", value: $session.recipe.straighten, range: -45...45,
                          format: EditSliderRow.degreeFormat)
        }
    }

    /// Preset label in its effective orientation ("9:16" when portrait).
    private func aspectLabel(_ aspect: CropAspect) -> String {
        guard let r = aspect.ratio, r != 1, session.cropIsPortrait else { return aspect.label }
        let parts = aspect.label.split(separator: ":")
        return parts.count == 2 ? "\(parts[1]):\(parts[0])" : aspect.label
    }

    private func aspectHelp(_ aspect: CropAspect) -> String {
        switch aspect {
        case .free: return "Crop freely"
        case .original: return "Keep the picture’s proportions"
        case .square: return "Crop to 1:1"
        default:
            let l = aspectLabel(aspect)
            return session.cropAspect == aspect ? "Crop to \(l) (click again to swap orientation)" : "Crop to \(l)"
        }
    }

    private func iconButton(_ symbol: String, help: String, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(EditPanelButtonStyle(selected: selected))
        .help(help)
    }

    private var lightChanged: Bool {
        let r = session.recipe
        return r.exposure != 0 || r.brightness != 0 || r.contrast != 0 || r.highlights != 0 || r.shadows != 0
    }
    private var colorChanged: Bool {
        let r = session.recipe
        return r.saturation != 0 || r.vibrance != 0 || r.temperature != 0 || r.tint != 0
    }
    private var geometryChanged: Bool { session.recipe.hasGeometryChange || session.isCropping }

}

/// Section with an uppercase header (STL/settings panel style) and a "Reset" link.
struct EditSection<Content: View>: View {
    let title: String
    let canReset: Bool
    let onReset: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(ViewerPalette.secondaryText)
                Spacer()
                if canReset {
                    Button("Reset", action: onReset)
                        .buttonStyle(EditLinkButtonStyle())
                }
            }
            .frame(height: 16)
            content()
        }
    }
}

/// "Compare" button: shows the unedited picture while pressed (same as holding "\").
private struct CompareButton: View {
    @ObservedObject var session: EditSession
    @State private var pressed = false

    var body: some View {
        Image(systemName: "square.split.2x1")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(pressed ? ViewerPalette.accent : ViewerPalette.primaryText)
            .frame(width: 28, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(pressed ? 0.12 : 0.05)))
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 60, maximumDistance: 200, pressing: { down in
                pressed = down
                session.showingOriginal = down
            }, perform: {})
            .help("Hold to compare with the original (or hold \\)")
            .accessibilityLabel("Compare with original")
    }
}

/// Dark rounded panel button (selected state uses the accent outline; prominent = blue fill).
struct EditPanelButtonStyle: ButtonStyle {
    var selected: Bool
    var prominent = false
    var compact = false
    var fixed = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent || selected ? .semibold : .regular))
            .foregroundStyle(prominent || selected ? Color.white : ViewerPalette.primaryText)
            .padding(.horizontal, fixed ? 14 : 6)
            .padding(.vertical, compact ? 5 : 6)
            .frame(minWidth: fixed ? 64 : nil)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? ViewerPalette.accent
                          : (selected ? ViewerPalette.accent.opacity(0.22) : ViewerPalette.pill))
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(prominent ? Color.clear : (selected ? ViewerPalette.accent : ViewerPalette.border), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Small accent text button ("Reset", "Revert to Original").
struct EditLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5))
            .foregroundStyle(ViewerPalette.accent.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35))
            .contentShape(Rectangle())
    }
}
