import SwiftUI
import UIKit

/// Direct port of the Mac SteerColors — same palette, same names, dark
/// vs light dynamic resolution swapped to UIKit's UITraitCollection.
enum SteerColors {
    // Mirrors apps/mac/.../SteerColors.swift. Dark neutrals carry a
    // subtle warm undertone (R slightly > G > B) so they echo the
    // orange brand mark, and the whole palette is brighter than v1.
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
        let normalized = CGFloat(hue / 360.0)
        return Color(uiColor: UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                let saturation: CGFloat = 0.34 * CGFloat(intensity)
                let brightness: CGFloat = 0.30 + 0.05 * CGFloat(intensity)
                return UIColor(hue: normalized, saturation: saturation, brightness: brightness, alpha: 1)
            }
            let saturation: CGFloat = 0.20 * CGFloat(intensity)
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
