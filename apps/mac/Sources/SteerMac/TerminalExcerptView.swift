import SwiftUI

struct TerminalExcerptView: View {
    let lines: [TerminalLine]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(lines) { line in
                    // macOS terminal-style body: 12pt SF Mono. The
                    // previous 11.5pt was below the ~12pt baseline
                    // that Xcode console and iTerm default to.
                    Text(renderedLine(line.text))
                        .font(.system(size: 12, weight: weight(for: line.kind), design: .monospaced))
                        .foregroundStyle(color(for: line.kind))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Inline markdown for the bits that show up in real codex / claude
    /// output: **bold**, *italic*, `code`, [link](url). Anything that fails
    /// to parse falls back to literal text so model output never breaks the
    /// UI.
    private func renderedLine(_ raw: String) -> AttributedString {
        let text = raw.isEmpty ? " " : raw
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attributed
        }
        return AttributedString(text)
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
