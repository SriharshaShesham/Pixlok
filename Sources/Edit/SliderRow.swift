import SwiftUI
import AppKit

/// Compact edit-panel slider: label left, value right, thin track below.
/// Bipolar sliders show a centre tick and fill from the centre. Double-click resets.
/// Dragging across the centre tick catches the knob at neutral (a 3pt detent, only while crossing);
/// Option-drag moves at 1/10 speed relative to where the fine drag started.
struct EditSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var format: (Double) -> String = EditSliderRow.percentFormat
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @State private var hovering = false
    /// Where the current drag (or fine-drag segment) started: pointer x, value, and whether fine.
    @State private var dragStart: (x: CGFloat, value: Double, fine: Bool)? = nil

    private var bipolar: Bool { range.lowerBound < neutral && neutral < range.upperBound }
    private var changed: Bool { abs(value - neutral) > 0.0005 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(changed ? ViewerPalette.primaryText : ViewerPalette.secondaryText)
                Spacer(minLength: 8)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(changed ? ViewerPalette.accent : ViewerPalette.secondaryText)
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset() }
            .help("Double-click to reset · Option-drag for fine control")

            track
                .frame(height: 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 100
            switch dir {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knob: CGFloat = dragging ? 13 : 11
            let usable = max(w - knob, 1)
            let x = knob / 2 + usable * min(max(fraction(value), 0), 1)
            let origin = knob / 2 + usable * (bipolar ? fraction(neutral) : 0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 3)
                    .padding(.horizontal, knob / 2)
                if bipolar {
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 1, height: 9)
                        .offset(x: origin - 0.5)
                }
                Rectangle()
                    .fill(ViewerPalette.accent)
                    .frame(width: abs(x - origin), height: 3)
                    .offset(x: min(x, origin))
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(hovering || dragging ? ViewerPalette.accent : Color.clear, lineWidth: 1))
                    .offset(x: x - knob / 2)
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let span = range.upperBound - range.lowerBound
                        let fine = NSEvent.modifierFlags.contains(.option)
                        // (Re)start the relative segment when the drag begins or Option changes.
                        if dragStart == nil || dragStart?.fine != fine {
                            dragStart = (dragStart == nil ? g.startLocation.x : g.location.x, value, fine)
                        }
                        var v: Double
                        if fine, let s = dragStart {
                            v = s.value + Double(g.location.x - s.x) / Double(usable) * span * 0.1
                        } else {
                            let f = Double(min(max((g.location.x - knob / 2) / usable, 0), 1))
                            v = range.lowerBound + f * span
                        }
                        v = min(max(v, range.lowerBound), range.upperBound)
                        // Detent: catch the knob at neutral only when this move crosses the centre
                        // tick and lands within 3pt of it, so small values near zero stay reachable.
                        if bipolar, !fine, (value - neutral) * (v - neutral) < 0 {
                            let px = knob / 2 + usable * fraction(v)
                            if abs(px - origin) < 3 { v = neutral }
                        }
                        if v != value { value = v }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        dragging = false
                        onEditingChanged(false)
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
            .onHover { hovering = $0 }
        }
    }

    private func reset() {
        if value != neutral { value = neutral }
    }

    // MARK: Formats

    /// -1…1 shown as −100…+100.
    static func percentFormat(_ v: Double) -> String { signed(Int((v * 100).rounded())) }
    /// 0…1 shown as 0…100.
    static func unsignedPercentFormat(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }
    /// EV stops, "+0.7".
    static func evFormat(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        if r == 0 { return "0.0" }
        return (r > 0 ? "+" : "−") + String(format: "%.1f", abs(r))
    }
    /// Degrees, "+3.5°".
    static func degreeFormat(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        if r == 0 { return "0°" }
        return (r > 0 ? "+" : "−") + String(format: "%.1f°", abs(r))
    }
    private static func signed(_ i: Int) -> String {
        i == 0 ? "0" : (i > 0 ? "+\(i)" : "−\(-i)")
    }
}
