import SwiftUI
import AppKit

/// Colours for the Settings window (dark graphite design).
enum SettingsPalette {
    static let background = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)
    static let card = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x21 / 255)
    static let border = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2E / 255)
    static let control = Color(red: 0x23 / 255, green: 0x23 / 255, blue: 0x27 / 255)
    static let secondaryText = Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA8 / 255)
    static let accent = Color(red: 0x4A / 255, green: 0x9E / 255, blue: 0xFF / 255)
    static let danger = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x80 / 255)
    static let success = Color(red: 0x7C / 255, green: 0xD9 / 255, blue: 0x92 / 255)
}

/// A titled rounded card used for each Settings section.
struct SettingsSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(SettingsPalette.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.border, lineWidth: 1))
        }
    }
}

/// Label column + control row inside a section.
struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .foregroundStyle(SettingsPalette.secondaryText)
                .frame(width: 150, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// Small plain text button in the accent colour ("Select all").
struct SettingsLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(SettingsPalette.accent)
        }
        .buttonStyle(.plain)
        .settingsHoverCursor()
    }
}

/// Bordered dark button used for secondary actions.
struct SettingsButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = prominent ? .white : (destructive ? SettingsPalette.danger : .white)
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .regular))
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? SettingsPalette.accent : SettingsPalette.control)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(prominent ? Color.clear : SettingsPalette.border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

extension View {
    /// Shows the pointing-hand cursor while hovering.
    func settingsHoverCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension NSImage {
    /// A copy drawn at `size` points (for menu item icons, which otherwise render at full size).
    func settingsResized(to size: CGFloat) -> NSImage {
        let target = NSSize(width: size, height: size)
        let img = NSImage(size: target, flipped: false) { rect in
            self.draw(in: rect)
            return true
        }
        return img
    }
}
