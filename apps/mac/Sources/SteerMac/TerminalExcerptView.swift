import SwiftUI

struct TerminalExcerptView: View {
    let lines: [TerminalLine]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 11.5, weight: line.kind == .accent ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(color(for: line.kind))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.10, green: 0.10, blue: 0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
        .accessibilityLabel("Terminal excerpt")
    }

    private func color(for kind: TerminalLineKind) -> Color {
        switch kind {
        case .standard:
            Color(red: 0.92, green: 0.92, blue: 0.93)
        case .muted:
            Color(red: 0.62, green: 0.63, blue: 0.66)
        case .accent:
            Color(red: 0.53, green: 0.80, blue: 0.81)
        case .success:
            Color(red: 0.62, green: 0.88, blue: 0.66)
        case .warning:
            Color(red: 1.00, green: 0.78, blue: 0.42)
        }
    }
}

#Preview {
    TerminalExcerptView(lines: ActionCard.samples[0].terminalLines)
        .padding()
}
