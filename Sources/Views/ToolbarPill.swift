import SwiftUI

/// Floating rounded toolbar at the bottom of the viewer:
/// zoom out · zoom label · zoom in · 1:1 | previous · slideshow · next | rotate left · rotate right | edit | delete
struct ToolbarPill: View {
    @ObservedObject var state: ViewerState
    let zoomEnabled: Bool
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSlideshow: () -> Void
    let onDelete: () -> Void
    var editEnabled: Bool = false
    var editHelp: String = "Edit (E)"
    var onEdit: () -> Void = {}

    var body: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(symbol: "minus.magnifyingglass", help: "Zoom out (⌘−)", enabled: zoomEnabled) {
                state.zoomOut()
            }
            Button {
                if state.zoom == .fit { state.actualSize() } else { state.fit() }
            } label: {
                Text(zoomEnabled ? state.zoomLabel : "—")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(ViewerPalette.primaryText.opacity(zoomEnabled ? 1 : 0.35))
                    .frame(minWidth: 46, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!zoomEnabled)
            .help("Toggle Fit / Actual size")
            ToolbarIconButton(symbol: "plus.magnifyingglass", help: "Zoom in (⌘+)", enabled: zoomEnabled) {
                state.zoomIn()
            }
            ToolbarIconButton(text: "1:1", help: "Actual size (⌘0)", enabled: zoomEnabled) {
                state.actualSize()
            }

            ToolbarDivider()

            ToolbarIconButton(symbol: "chevron.left", help: "Previous (←)", enabled: canGoPrevious, action: onPrevious)
            Button(action: onSlideshow) {
                Image(systemName: state.isSlideshowRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(ViewerPalette.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 2)
            .help(state.isSlideshowRunning ? "Stop slideshow (Esc)" : "Start slideshow (F5)")
            ToolbarIconButton(symbol: "chevron.right", help: "Next (→)", enabled: canGoNext, action: onNext)

            ToolbarDivider()

            ToolbarIconButton(symbol: "rotate.left", help: "Rotate left (⌘L)", enabled: zoomEnabled) {
                state.rotateLeft()
            }
            ToolbarIconButton(symbol: "rotate.right", help: "Rotate right (⌘R)", enabled: zoomEnabled) {
                state.rotateRight()
            }

            ToolbarDivider()

            ToolbarIconButton(symbol: "slider.horizontal.3", help: editHelp, enabled: editEnabled, action: onEdit)

            ToolbarDivider()

            ToolbarIconButton(symbol: "trash", help: "Move to Trash (Delete)", enabled: true,
                              tint: ViewerPalette.danger, action: onDelete)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(ViewerPalette.pill.opacity(0.96)))
        .overlay(Capsule().strokeBorder(ViewerPalette.border))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
        .fixedSize()
    }
}

struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(ViewerPalette.border)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 6)
    }
}

/// 32×30 toolbar button with hover highlight; shows an SF Symbol or a short text.
struct ToolbarIconButton: View {
    var symbol: String? = nil
    var text: String? = nil
    let help: String
    var enabled: Bool = true
    var tint: Color = ViewerPalette.primaryText
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                } else {
                    Text(text ?? "").font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(tint.opacity(enabled ? 1 : 0.32))
            .frame(width: 32, height: 30)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(hovering && enabled ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}
