import SwiftUI

struct TerminalExcerptView: View {
    let lines: [TerminalLine]

    var body: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 11.5, weight: weight(for: line.kind), design: .monospaced))
                        .foregroundStyle(color(for: line.kind))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Terminal excerpt")
    }

    private func color(for kind: TerminalLineKind) -> Color {
        switch kind {
        case .standard:
            SteerColors.terminalStandard
        case .muted:
            SteerColors.terminalMuted
        case .accent:
            SteerColors.terminalAccent
        case .success:
            SteerColors.terminalSuccess
        case .warning:
            SteerColors.terminalWarning
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
