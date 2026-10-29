import os
import SwiftUI
import UIKit

/// The app's design foundation: colours, type and button styles from `docs/design/designretningslinjer.txt`.
/// Self-contained on purpose: screens opt in one by one; nothing here knows about the rest of the app.
enum Theme {
    // MARK: Colour

    enum Colour {
        /// Brand palette, fixed in both appearances.
        static let forest = Color(hex: 0x123D38)
        static let ivory = Color(hex: 0xFFF8E9)
        static let coral = Color(hex: 0xEC795D)
        static let stone = Color(hex: 0xDDD8CD)

        /// Window background: ivory in light mode, forest green in dark mode.
        static let background = adaptive(light: 0xFFF8E9, dark: 0x123D38)
        /// Running text: forest green in light mode, ivory in dark mode.
        static let text = adaptive(light: 0x123D38, dark: 0xFFF8E9)
        /// Tint for controls: same pairing as `text`, so it is legible on `background`.
        static let accent = text
        /// Fill of the primary forest button: it flips in dark mode, where forest would vanish into the background.
        static let primaryFill = adaptive(light: 0x123D38, dark: 0xFFF8E9)
        /// Text on the primary forest button.
        static let onPrimaryFill = adaptive(light: 0xFFF8E9, dark: 0x123D38)

        private static func adaptive(light: UInt32, dark: UInt32) -> Color {
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        }
    }

    // MARK: Type

    /// Real PostScript names of the bundled fonts. Playfair Display ships as one variable file; its named
    /// instance below is the SemiBold (wght 600) cut. Verified to resolve through `UIFont(name:)` on iOS 26.
    enum FontName {
        static let display = "PlayfairDisplayRoman-SemiBold"
        static let regular = "Inter-Regular"
        static let medium = "Inter-Medium"
        static let all = [display, regular, medium]
    }

    enum Font {
        /// 34 pt, scales with the large-title style.
        static let display = SwiftUI.Font.custom(FontName.display, size: 34, relativeTo: .largeTitle)
        /// 28 pt, scales with the title style.
        static let title = SwiftUI.Font.custom(FontName.display, size: 28, relativeTo: .title)
        /// 17 pt, scales with the body style.
        static let body = SwiftUI.Font.custom(FontName.regular, size: 17, relativeTo: .body)
        static let bodyMedium = SwiftUI.Font.custom(FontName.medium, size: 17, relativeTo: .body)
        /// 13 pt, scales with the caption style.
        static let caption = SwiftUI.Font.custom(FontName.regular, size: 13, relativeTo: .caption)

        nonisolated private static let log = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "design")

        /// A font missing at run time makes SwiftUI use the system font without a word. This reports it, once
        /// per process: call it at launch.
        static func verifyBundled() { _ = verified }

        nonisolated private static let verified: Void = {
            for name in FontName.all where UIFont(name: name, size: 17) == nil {
                log.error("bundled font \(name, privacy: .public) is missing; the system font is used instead")
            }
        }()
    }

    // MARK: Buttons

    /// Spacing rhythm: 8 pt steps, 16-24 pt side margins.
    enum Spacing {
        static let unit: CGFloat = 8
        static let margin: CGFloat = 16
        static let wideMargin: CGFloat = 24
    }

    static let minimumTouchHeight: CGFloat = 44
    static let buttonCorner: CGFloat = 18

    enum PrimaryColour { case forest, coral }

    /// Forest green with ivory text, or coral with forest-green text (never light text on coral).
    struct PrimaryButtonStyle: ButtonStyle {
        var colour: PrimaryColour = .coral

        func makeBody(configuration: Configuration) -> some View {
            Label(configuration: configuration, fill: fill, foreground: foreground)
        }

        private var fill: Color { colour == .forest ? Colour.primaryFill : Colour.coral }
        private var foreground: Color { colour == .forest ? Colour.onPrimaryFill : Colour.forest }
    }

    /// Stone surface with forest-green text.
    struct SecondaryButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Label(configuration: configuration, fill: Colour.stone, foreground: Colour.forest)
        }
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        let fill: Color
        let foreground: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Font.bodyMedium)
                .foregroundStyle(foreground)
                .padding(.horizontal, Spacing.margin)
                .frame(maxWidth: .infinity, minHeight: minimumTouchHeight)
                .background(fill, in: RoundedRectangle(cornerRadius: buttonCorner, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: buttonCorner, style: .continuous))
        }
    }
}

extension ButtonStyle where Self == Theme.PrimaryButtonStyle {
    /// The main button: coral with forest-green text by default (the design's main-button colour); `.forest` on request.
    static func themePrimary(_ colour: Theme.PrimaryColour = .coral) -> Theme.PrimaryButtonStyle {
        Theme.PrimaryButtonStyle(colour: colour)
    }
}

extension ButtonStyle where Self == Theme.SecondaryButtonStyle {
    static var themeSecondary: Theme.SecondaryButtonStyle { Theme.SecondaryButtonStyle() }
}

private extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
