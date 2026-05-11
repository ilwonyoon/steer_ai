import SwiftUI

/// Direct port of Mac TerminalExcerptView. Same monospaced rendering,
/// markdown support, and per-kind color via SteerColors.terminal*.
/// `scrollBounceBehavior(.basedOnSize)` keeps the terminal panel from
/// rubber-banding when its content is shorter than the visible area —
/// that bounce was reading as "the card is shaking".
struct TerminalExcerptView: View {
    let lines: [TerminalLine]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(lines) { line in
                    // iOS body 17pt is too dense for monospaced runs;
                    // 15pt SF Mono (one notch under SF body) keeps
                    // the terminal excerpt readable without
                    // overwhelming the surrounding chrome. Was 14pt
                    // which read small on iPhone next to body copy.
                    Text(renderedLine(line.text))
                        .font(.system(size: 15, weight: weight(for: line.kind), design: .monospaced))
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
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        // Don't let the keyboard adjust this scroll view's content
        // insets — it's nested inside a card whose frame is already
        // managed by the parent's keyboard avoidance, so doubling up
        // makes the text appear to flash on focus changes.
        .ignoresSafeArea(.keyboard)
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
