import SwiftUI

struct ActionCardView: View {
    let card: ActionCard
    @Binding var reply: String
    @Binding var attachments: [ReplyAttachment]
    let onSend: (String, [ReplyAttachment]) -> Void

    private var headerTint: Color {
        SteerColors.hueTint(hue: card.accentHue, intensity: 0.65)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionHeader(card: card)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)
                .background(headerTint)

            Divider()

            TerminalExcerptView(lines: card.terminalLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .layoutPriority(1)

            Divider()

            ReplyDock(chips: card.chips, reply: $reply, attachments: $attachments, onSend: onSend, provider: card.provider)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SteerColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(SteerColors.separator, lineWidth: 1)
        }
        .shadow(color: SteerColors.cardShadow, radius: 24, y: 16)
    }
}

struct SessionHeader: View {
    let card: ActionCard

    var body: some View {
        HStack(alignment: .top) {
            HStack(spacing: 8) {
                ProjectMark(emoji: card.emoji)

                VStack(alignment: .leading, spacing: 2) {
                    // macOS HIG body weight: 13–14pt SF Text. The
                    // previous monospaced 12.5pt read like a debug
                    // panel; Claude/ChatGPT desktop use SF body for
                    // identity rows like this.
                    Text(card.project)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SteerColors.ink)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(card.state.color)
                            .frame(width: 6, height: 6)
                        Text(card.branchLabel ?? card.provider.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(SteerColors.secondaryInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            Text(card.age)
                .font(.system(size: 11))
                .foregroundStyle(SteerColors.secondaryInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(SteerColors.subtleFill, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(SteerColors.softSeparator, lineWidth: 1)
                }
        }
    }
}

struct ProviderMark: View {
    let provider: ProviderKind
    var size: CGFloat = 24

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
                    .font(.system(size: max(8, size * 0.46), weight: .bold))
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
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(provider.displayName)
    }
}

/// Project emoji marker for a card. Stage 1 — purely informational
/// (deterministic emoji from cwd basename). Stage 2 will make this
/// interactive so the user can override the glyph per session;
/// keeping the View name `ProjectMark` (not `ProviderMark`) reflects
/// the new identity model: the card represents a project location,
/// not which CLI happens to be open in it.
struct ProjectMark: View {
    let emoji: String
    var size: CGFloat = 24

    var body: some View {
        Text(emoji)
            // Same trade-off as iOS — the previous disc background
            // was there to clip a rectangular Image. Emoji read as a
            // self-contained mark; no need for an extra container.
            .font(.system(size: size))
            .frame(width: size, height: size)
            .accessibilityLabel("Project marker \(emoji)")
    }
}
