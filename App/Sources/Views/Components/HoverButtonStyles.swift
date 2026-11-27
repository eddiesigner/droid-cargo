import SwiftUI

/// Text link in the app accent color: pointing-hand cursor and underline on hover, dimmed while pressed.
/// The stock `.link` style gives no hover feedback at all.
struct HoverLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLink(configuration: configuration)
    }

    private struct HoverLink: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .underline(isHovered && isEnabled)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(.rect)
                .onHover { isHovered = $0 }
                .pointerStyle(isEnabled ? .link : nil)
        }
    }
}

/// Small icon or text button with a rounded highlight on hover, like the
/// inline buttons in Safari's and Finder's bars.
struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIcon(configuration: configuration)
    }

    private struct HoverIcon: View {
        private static let padding: CGFloat = 4
        private static let cornerRadius: CGFloat = 6
        private static let disabledOpacity = 0.4

        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        private var highlight: AnyShapeStyle {
            if configuration.isPressed {
                return AnyShapeStyle(.quaternary)
            }
            return isHovered && isEnabled ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear)
        }

        var body: some View {
            configuration.label
                .padding(Self.padding)
                .background(highlight, in: .rect(cornerRadius: Self.cornerRadius))
                .opacity(isEnabled ? 1 : Self.disabledOpacity)
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}

extension ButtonStyle where Self == HoverLinkButtonStyle {
    static var hoverLink: HoverLinkButtonStyle { HoverLinkButtonStyle() }
}

extension ButtonStyle where Self == HoverIconButtonStyle {
    static var hoverIcon: HoverIconButtonStyle { HoverIconButtonStyle() }
}

/// Darkens a stock button slightly under the pointer. macOS push buttons
/// have no hover state, which makes a lone call-to-action feel inert.
/// Darkening (not lightening) raises the contrast of white labels.
private struct HoverHighlight: ViewModifier {
    private static let brightness = -0.06
    private static let fade = Animation.easeOut(duration: 0.12)

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .brightness(isHovered && isEnabled ? Self.brightness : 0)
            .animation(Self.fade, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlight())
    }
}
