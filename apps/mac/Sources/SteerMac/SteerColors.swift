import SwiftUI
import AppKit

enum SteerColors {
    // Dark mode neutrals carry a subtle warm undertone (R slightly >
    // G > B) so the palette echoes the orange brand mark without
    // tinting. Brightness was lifted across surfaces — the previous
    // dark theme read as "dim charcoal grey"; this one is closer to
    // the warm neutral used by Claude desktop and ChatGPT macOS.
    static let appBackground = dynamic(light: rgb(0.955, 0.955, 0.965), dark: rgb(0.115, 0.108, 0.103))
    static let cardBackground = dynamic(light: rgb(0.985, 0.985, 0.975), dark: rgb(0.168, 0.158, 0.150))
    static let cardBackplate = dynamic(light: rgb(0.985, 0.985, 0.975, 0.94), dark: rgb(0.215, 0.202, 0.190, 0.78))

    static let ink = dynamic(light: rgb(0.12, 0.12, 0.13), dark: rgb(0.945, 0.935, 0.925))
    static let secondaryInk = dynamic(light: rgb(0.44, 0.44, 0.48), dark: rgb(0.760, 0.745, 0.730))
    static let tertiaryInk = dynamic(light: rgb(0.62, 0.62, 0.66), dark: rgb(0.555, 0.540, 0.525))

    static let separator = dynamic(light: rgb(0, 0, 0, 0.10), dark: rgb(1, 0.96, 0.92, 0.14))
    static let softSeparator = dynamic(light: rgb(0, 0, 0, 0.075), dark: rgb(1, 0.96, 0.92, 0.10))
    static let subtleFill = dynamic(light: rgb(0, 0, 0, 0.035), dark: rgb(1, 0.96, 0.92, 0.075))
    static let inputFill = dynamic(light: rgb(0, 0, 0, 0.026), dark: rgb(1, 0.96, 0.92, 0.070))
    static let statusFill = dynamic(light: rgb(1, 1, 1, 0.52), dark: rgb(1, 0.96, 0.92, 0.09))

    static let controlFill = dynamic(light: rgb(1, 1, 1, 0.78), dark: rgb(1, 0.96, 0.92, 0.11))
    static let controlStroke = dynamic(light: rgb(1, 1, 1, 0.88), dark: rgb(1, 0.96, 0.92, 0.15))
    static let cardShadow = dynamic(light: rgb(0, 0, 0, 0.08), dark: rgb(0, 0, 0, 0.34))
    static let controlShadow = dynamic(light: rgb(0, 0, 0, 0.07), dark: rgb(0, 0, 0, 0.28))

    static let userInk = Color.white
    static let userBubble = Color.accentColor
    static let agentBubble = dynamic(light: rgb(1, 1, 1, 0.82), dark: rgb(1, 0.96, 0.92, 0.075))

    static let terminalStandard = dynamic(light: rgb(0.13, 0.13, 0.14), dark: rgb(0.910, 0.900, 0.890))
    static let terminalMuted = dynamic(light: rgb(0.46, 0.46, 0.50), dark: rgb(0.660, 0.645, 0.630))
    static let terminalAccent = dynamic(light: rgb(0.02, 0.44, 0.48), dark: rgb(0.55, 0.83, 0.86))
    static let terminalSuccess = dynamic(light: rgb(0.02, 0.48, 0.23), dark: rgb(0.52, 0.86, 0.60))
    static let terminalWarning = dynamic(light: rgb(0.72, 0.35, 0.00), dark: rgb(1.0, 0.72, 0.34))

    static let waiting = dynamic(light: rgb(1.0, 0.69, 0.13), dark: rgb(1.0, 0.78, 0.30))
    static let blocked = dynamic(light: rgb(1.0, 0.27, 0.23), dark: rgb(1.0, 0.44, 0.40))
    static let running = dynamic(light: rgb(0.20, 0.78, 0.35), dark: rgb(0.48, 0.88, 0.58))
    static let ended = dynamic(light: rgb(0.46, 0.46, 0.50), dark: rgb(0.62, 0.60, 0.58))
    static let disconnected = dynamic(light: rgb(0.72, 0.35, 0.00), dark: rgb(1.0, 0.66, 0.32))

    static func hueTint(hue: Double, intensity: Double = 1.0) -> Color {
        let normalized = hue / 360
        return Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                // Lifted brightness + slightly higher saturation so the
                // header tints read against the brighter card surface
                // without becoming candy. Previous values blended into
                // the dim grey background.
                let saturation = 0.34 * intensity
                let brightness = 0.30 + 0.05 * intensity
                return NSColor(hue: normalized, saturation: saturation, brightness: brightness, alpha: 1)
            }
            let saturation = 0.20 * intensity
            let brightness = 0.99
            return NSColor(hue: normalized, saturation: saturation, brightness: brightness, alpha: 1)
        })
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return dark
            }
            return light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
