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
                .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.72), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
        }
    }
}

extension View {
    func steerGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, isInteractive: interactive))
    }
}
