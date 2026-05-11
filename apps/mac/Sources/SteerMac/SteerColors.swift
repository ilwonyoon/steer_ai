import SwiftUI
import AppKit

enum SteerColors {
    // Light palette is dialed in by the user — do not touch.
    // Dark palette carries a very faint warm undertone so the orange
    // app icon doesn't read as foreign next to the chrome. The push
    // is small (R ~0.008 above G, B another notch lower) — much less
    // than the PR #4 overreach that was rolled back. Reads as plain
    // dark grey at a glance; the warmth only registers as "does not
    // feel like a generic IDE."
    static let appBackground = dynamic(light: rgb(0.955, 0.955, 0.965), dark: rgb(0.113, 0.105, 0.100))
    static let cardBackground = dynamic(light: rgb(0.985, 0.985, 0.975), dark: rgb(0.163, 0.155, 0.150))
    static let cardBackplate = dynamic(light: rgb(0.985, 0.985, 0.975, 0.94), dark: rgb(0.213, 0.205, 0.200, 0.78))

    static let ink = dynamic(light: rgb(0.12, 0.12, 0.13), dark: rgb(0.935, 0.935, 0.945))
    static let secondaryInk = dynamic(light: rgb(0.44, 0.44, 0.48), dark: rgb(0.74, 0.74, 0.76))
    static let tertiaryInk = dynamic(light: rgb(0.62, 0.62, 0.66), dark: rgb(0.54, 0.54, 0.56))

    static let separator = dynamic(light: rgb(0, 0, 0, 0.10), dark: rgb(1, 1, 1, 0.14))
    static let softSeparator = dynamic(light: rgb(0, 0, 0, 0.075), dark: rgb(1, 1, 1, 0.10))
    static let subtleFill = dynamic(light: rgb(0, 0, 0, 0.035), dark: rgb(1, 1, 1, 0.075))
    static let inputFill = dynamic(light: rgb(0, 0, 0, 0.026), dark: rgb(1, 1, 1, 0.070))
    static let statusFill = dynamic(light: rgb(1, 1, 1, 0.52), dark: rgb(1, 1, 1, 0.09))

    static let controlFill = dynamic(light: rgb(1, 1, 1, 0.78), dark: rgb(1, 1, 1, 0.11))
    static let controlStroke = dynamic(light: rgb(1, 1, 1, 0.88), dark: rgb(1, 1, 1, 0.15))
    static let cardShadow = dynamic(light: rgb(0, 0, 0, 0.08), dark: rgb(0, 0, 0, 0.34))
    static let controlShadow = dynamic(light: rgb(0, 0, 0, 0.07), dark: rgb(0, 0, 0, 0.28))

    static let userInk = Color.white
    static let userBubble = Color.accentColor
    static let agentBubble = dynamic(light: rgb(1, 1, 1, 0.82), dark: rgb(1, 1, 1, 0.075))

    static let terminalStandard = dynamic(light: rgb(0.13, 0.13, 0.14), dark: rgb(0.90, 0.90, 0.92))
    static let terminalMuted = dynamic(light: rgb(0.46, 0.46, 0.50), dark: rgb(0.64, 0.64, 0.68))
    static let terminalAccent = dynamic(light: rgb(0.02, 0.44, 0.48), dark: rgb(0.50, 0.82, 0.86))
    static let terminalSuccess = dynamic(light: rgb(0.02, 0.48, 0.23), dark: rgb(0.50, 0.86, 0.60))
    static let terminalWarning = dynamic(light: rgb(0.72, 0.35, 0.00), dark: rgb(1.0, 0.72, 0.34))

    static let waiting = dynamic(light: rgb(1.0, 0.69, 0.13), dark: rgb(1.0, 0.78, 0.30))
    static let blocked = dynamic(light: rgb(1.0, 0.27, 0.23), dark: rgb(1.0, 0.44, 0.40))
    static let running = dynamic(light: rgb(0.20, 0.78, 0.35), dark: rgb(0.48, 0.88, 0.58))
    static let ended = dynamic(light: rgb(0.46, 0.46, 0.50), dark: rgb(0.62, 0.62, 0.66))
    static let disconnected = dynamic(light: rgb(0.72, 0.35, 0.00), dark: rgb(1.0, 0.66, 0.32))

    static func hueTint(hue: Double, intensity: Double = 1.0) -> Color {
        // Per-project header tint. The user-visible rule is "dark mode
        // should feel like the same color from light mode, just placed
        // on a dark surface" — not a completely different palette.
        // So both modes share the same hue and the same low saturation
        // (0.18 light, 0.16 dark — dark trims a touch because the same
        // chroma reads more saturated against black). Only brightness
        // flips: 0.99 in light gives a near-paper pastel; 0.16 in dark
        // gives a faint inked-paper tint of the same hue. Result:
        // Documents/Steer_ai stays the same blue family in both modes.
        let normalized = hue / 360
        return Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                let saturation = 0.16 * intensity
                let brightness = 0.16 + 0.03 * intensity
                return NSColor(hue: normalized, saturation: saturation, brightness: brightness, alpha: 1)
            }
            let saturation = 0.18 * intensity
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
