import SwiftUI

struct DetailView: View {
    let card: ActionCard
    let onClose: () -> Void
    let onSend: (String, [ReplyAttachment]) -> Void

    @State private var reply = ""
    @State private var attachments: [ReplyAttachment] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back", action: onClose)
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Spacer()

                HStack(spacing: 8) {
                    Text("\(card.project) · \(card.provider.displayName)")
                        .font(.system(size: 12))
                        .foregroundStyle(SteerColors.secondaryInk)
                        .lineLimit(1)
                    Text(card.state.rawValue)
                        .font(.system(size: 12))
                        .foregroundStyle(SteerColors.secondaryInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(SteerColors.statusFill, in: Capsule())
                }
            }
            .frame(height: 48)
            .padding(.horizontal, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Terminal tail")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SteerColors.secondaryInk)
                        TerminalExcerptView(lines: card.terminalLines)
                            .padding(14)
                            .background(SteerColors.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SteerColors.softSeparator, lineWidth: 1)
                            }
                            .frame(height: 240)
                    }
                    .padding(.bottom, 8)

                    ForEach(card.thread) { message in
                        ThreadBubble(message: message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            ReplyDock(chips: card.chips, reply: $reply, attachments: $attachments, onSend: { text, atts in
                onSend(text, atts)
                reply = ""
                attachments = []
            })
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 375, height: 600)
        .background(SteerColors.appBackground)
    }
}

private struct ThreadBubble: View {
    let message: ThreadMessage

    var body: some View {
        Text(message.text)
            .font(.system(size: 15))
            .lineSpacing(4)
            .foregroundStyle(message.sender == .user ? SteerColors.userInk : SteerColors.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(background)
            .frame(maxWidth: .infinity, alignment: message.sender == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var background: some View {
        if message.sender == .user {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor)
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SteerColors.agentBubble)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(SteerColors.softSeparator, lineWidth: 1)
                }
        }
    }
}
