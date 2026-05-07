import SwiftUI

struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let isInteractive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isInteractive {
                content
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                content
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(SteerColors.controlFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(SteerColors.controlStroke, lineWidth: 1)
                }
                .shadow(color: SteerColors.controlShadow, radius: 14, y: 6)
        }
    }
}

extension View {
    func steerGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, isInteractive: interactive))
    }
}
