import SwiftUI

struct ActionCardView: View {
    let card: ActionCard
    let onOpenDetail: () -> Void
    let onSend: (String) -> Void

    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionHeader(card: card)

            Divider()
                .padding(.top, 14)

            TerminalMetaView(card: card)
                .padding(.top, 12)

            Divider()
                .padding(.vertical, 12)

            TerminalExcerptView(lines: card.terminalLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)

            Divider()
                .padding(.bottom, 12)

            ReplyDock(chips: card.chips, reply: $reply, onSend: onSend)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .frame(height: 590)
        .background(Color(red: 0.985, green: 0.985, blue: 0.975), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 24, y: 16)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onOpenDetail)
    }
}

private struct TerminalMetaView: View {
    let card: ActionCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TerminalMetaLine(label: "title", value: card.title, color: .primary, weight: .semibold)
            TerminalMetaLine(label: "status", value: statusValue, color: card.state.color, weight: .semibold)
            TerminalMetaLine(label: "reason", value: card.summary, color: .secondary, weight: .regular)
        }
    }

    private var statusValue: String {
        switch card.state {
        case .waiting:
            "waiting_for_decision"
        case .blocked:
            "blocked"
        case .running:
            "running"
        }
    }
}

private struct TerminalMetaLine: View {
    let label: String
    let value: String
    let color: Color
    let weight: Font.Weight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .foregroundStyle(color)
                .fontWeight(weight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

struct SessionHeader: View {
    let card: ActionCard

    var body: some View {
        HStack(alignment: .top) {
            HStack(spacing: 8) {
                ProviderMark(provider: card.provider)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.project)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(card.state.color)
                            .frame(width: 6, height: 6)
                        Text(card.provider.displayName)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(card.age)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.035), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.black.opacity(0.07), lineWidth: 1)
                }
        }
    }
}

struct ProviderMark: View {
    let provider: ProviderKind

    var body: some View {
        Group {
            if let iconName = provider.iconName,
               let url = Bundle.module.url(forResource: iconName, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(provider.fallbackLetter)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.11, green: 0.11, blue: 0.12), Color(red: 0.37, green: 0.42, blue: 0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .accessibilityLabel(provider.displayName)
    }
}
