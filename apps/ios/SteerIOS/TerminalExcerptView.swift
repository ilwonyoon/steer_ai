import SwiftUI

/// Direct port of Mac TerminalExcerptView. Same monospaced rendering,
/// markdown support, and per-kind color via SteerColors.terminal*.
struct TerminalExcerptView: View {
    let lines: [TerminalLine]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(lines) { line in
                    Text(renderedLine(line.text))
                        .font(.system(size: 11.5, weight: weight(for: line.kind), design: .monospaced))
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
        case .standard: SteerColors.terminalStandard
        case .muted: SteerColors.terminalMuted
        case .accent: SteerColors.terminalAccent
        case .success: SteerColors.terminalSuccess
        case .warning: SteerColors.terminalWarning
        }
    }

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
        case .accent, .success, .warning: .semibold
        case .standard: .medium
        case .muted: .regular
        }
    }
}
