import SwiftUI

struct TerminalExcerptView: View {
    let lines: [TerminalLine]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 11.5, weight: weight(for: line.kind), design: .monospaced))
                        .foregroundStyle(color(for: line.kind))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Terminal excerpt")
    }

    private func color(for kind: TerminalLineKind) -> Color {
        switch kind {
        case .standard:
            Color(red: 0.13, green: 0.13, blue: 0.14)
        case .muted:
            Color(red: 0.46, green: 0.46, blue: 0.50)
        case .accent:
            Color(red: 0.02, green: 0.44, blue: 0.48)
        case .success:
            Color(red: 0.02, green: 0.48, blue: 0.23)
        case .warning:
            Color(red: 0.72, green: 0.35, blue: 0.00)
        }
    }

    private func weight(for kind: TerminalLineKind) -> Font.Weight {
        switch kind {
        case .accent, .success, .warning:
            .semibold
        case .standard:
            .medium
        case .muted:
            .regular
        }
    }
}

#Preview {
    TerminalExcerptView(lines: ActionCard.samples[0].terminalLines)
        .padding()
}
