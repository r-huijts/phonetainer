import SwiftUI

/// Semantic color and shape tokens (light theme). Views use these names only,
/// so a dark theme can later be added by changing the values here.
enum Theme {
    static let background = Color(hex: 0xF4F6F9)
    static let surface = Color(hex: 0xFFFFFF)
    static let border = Color(hex: 0xDDE2E9)
    static let borderStrong = Color(hex: 0xCBD2DC)
    static let text = Color(hex: 0x12171F)
    static let secondaryText = Color(hex: 0x5A6574)
    static let accent = Color(hex: 0x1F6FEB)
    static let onAccent = Color(hex: 0xFFFFFF)

    static let successText = Color(hex: 0x136C4A)
    static let successFill = Color(hex: 0xDDF3E8)
    static let warningText = Color(hex: 0x8A5300)
    static let warningFill = Color(hex: 0xFBEBCB)
    static let dangerText = Color(hex: 0xA12A22)
    static let dangerFill = Color(hex: 0xFBE0DD)
    static let neutralText = secondaryText
    static let neutralFill = Color(hex: 0xEDF0F4)

    static let cardRadius: CGFloat = 18
    static let buttonRadius: CGFloat = 12
    static let sheetRadius: CGFloat = 28
    static let minTouchHeight: CGFloat = 44
    static let gutter: CGFloat = 16
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouchHeight)
            .foregroundStyle(isEnabled ? Theme.onAccent : Theme.secondaryText)
            .background(
                isEnabled ? Theme.accent : Theme.border,
                in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouchHeight)
            .foregroundStyle(Theme.text)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                    .strokeBorder(Theme.borderStrong, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
