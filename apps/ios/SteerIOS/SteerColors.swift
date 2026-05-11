import SwiftUI
import UIKit

/// Direct port of the Mac SteerColors — same palette, same names, dark
/// vs light dynamic resolution swapped to UIKit's UITraitCollection.
enum SteerColors {
    // Light palette is dialed in by the user — do not touch.
    // Dark palette carries a very faint warm undertone so the orange
    // app icon doesn't read as foreign next to the chrome. The push
    // is small (R a touch above G, B another notch lower) — much
    // less than the PR #4 overreach that was rolled back. Mirrors
    // apps/mac/.../SteerColors.swift.
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
        // Mirror of the Mac path. Same hue in both modes, only
        // brightness flips. Saturation trimmed a touch in dark so the
        // same chroma reads as a faint tint of paper, not a slab of
        // saturated color against black.
        let normalized = CGFloat(hue / 360.0)
        return Color(uiColor: UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                let saturation: CGFloat = 0.16 * CGFloat(intensity)
                let brightness: CGFloat = 0.16 + 0.03 * CGFloat(intensity)
                return UIColor(hue: normalized, saturation: saturation, brightness: brightness, alpha: 1)
            }
            let saturation: CGFloat = 0.18 * CGFloat(intensity)
            let brightness: CGFloat = 0.99
            return UIColor(hue: normalized, saturation: saturation, brightness: brightness, alpha: 1)
        })
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
