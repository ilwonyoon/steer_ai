import SwiftUI

/// Liquid Glass surface used throughout the Mac shell. The app's
/// deployment target is now macOS 26, so we drop the pre-26
/// material-fallback branch and rely on the system glass directly.
struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let isInteractive: Bool

    func body(content: Content) -> some View {
        if isInteractive {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func steerGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, isInteractive: interactive))
    }
}
