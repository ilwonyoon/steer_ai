import SwiftUI
import AppKit

enum SteerColors {
    static let appBackground = dynamic(light: rgb(0.955, 0.955, 0.965), dark: rgb(0.075, 0.075, 0.085))
    static let cardBackground = dynamic(light: rgb(0.985, 0.985, 0.975), dark: rgb(0.12, 0.12, 0.13))
    static let cardBackplate = dynamic(light: rgb(0.985, 0.985, 0.975, 0.94), dark: rgb(0.18, 0.18, 0.19, 0.72))

    static let ink = dynamic(light: rgb(0.12, 0.12, 0.13), dark: rgb(0.91, 0.91, 0.93))
    static let secondaryInk = dynamic(light: rgb(0.44, 0.44, 0.48), dark: rgb(0.68, 0.68, 0.72))
    static let tertiaryInk = dynamic(light: rgb(0.62, 0.62, 0.66), dark: rgb(0.48, 0.48, 0.52))

    static let separator = dynamic(light: rgb(0, 0, 0, 0.10), dark: rgb(1, 1, 1, 0.12))
    static let softSeparator = dynamic(light: rgb(0, 0, 0, 0.075), dark: rgb(1, 1, 1, 0.10))
    static let subtleFill = dynamic(light: rgb(0, 0, 0, 0.035), dark: rgb(1, 1, 1, 0.07))
    static let inputFill = dynamic(light: rgb(0, 0, 0, 0.026), dark: rgb(1, 1, 1, 0.065))
    static let statusFill = dynamic(light: rgb(1, 1, 1, 0.52), dark: rgb(1, 1, 1, 0.08))

    static let controlFill = dynamic(light: rgb(1, 1, 1, 0.78), dark: rgb(1, 1, 1, 0.10))
    static let controlStroke = dynamic(light: rgb(1, 1, 1, 0.88), dark: rgb(1, 1, 1, 0.14))
    static let cardShadow = dynamic(light: rgb(0, 0, 0, 0.08), dark: rgb(0, 0, 0, 0.34))
    static let controlShadow = dynamic(light: rgb(0, 0, 0, 0.07), dark: rgb(0, 0, 0, 0.28))

    static let userInk = Color.white
    static let userBubble = Color.accentColor
    static let agentBubble = dynamic(light: rgb(1, 1, 1, 0.82), dark: rgb(1, 1, 1, 0.065))

    static let terminalStandard = dynamic(light: rgb(0.13, 0.13, 0.14), dark: rgb(0.88, 0.88, 0.90))
    static let terminalMuted = dynamic(light: rgb(0.46, 0.46, 0.50), dark: rgb(0.60, 0.60, 0.66))
    static let terminalAccent = dynamic(light: rgb(0.02, 0.44, 0.48), dark: rgb(0.47, 0.80, 0.84))
    static let terminalSuccess = dynamic(light: rgb(0.02, 0.48, 0.23), dark: rgb(0.45, 0.84, 0.57))
    static let terminalWarning = dynamic(light: rgb(0.72, 0.35, 0.00), dark: rgb(0.96, 0.68, 0.28))

    static let waiting = dynamic(light: rgb(1.0, 0.69, 0.13), dark: rgb(1.0, 0.74, 0.24))
    static let blocked = dynamic(light: rgb(1.0, 0.27, 0.23), dark: rgb(1.0, 0.38, 0.34))
    static let running = dynamic(light: rgb(0.20, 0.78, 0.35), dark: rgb(0.42, 0.86, 0.52))
    static let ended = dynamic(light: rgb(0.46, 0.46, 0.50), dark: rgb(0.58, 0.58, 0.64))
    static let disconnected = dynamic(light: rgb(0.72, 0.35, 0.00), dark: rgb(0.92, 0.58, 0.25))

    static func hueTint(hue: Double, intensity: Double = 1.0) -> Color {
        let normalized = hue / 360
        return Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                let saturation = 0.32 * intensity
                let brightness = 0.22 + 0.04 * intensity
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
