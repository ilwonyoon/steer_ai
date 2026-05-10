import SwiftUI

/// iOS port of Mac ActionCardView. Same layout: tinted SessionHeader,
/// terminal excerpt, ReplyDock — wrapped in a rounded card with a
/// subtle stroke and shadow.
struct ActionCardView: View {
    let card: ActionCard
    @Binding var reply: String
    let onSend: (String) -> Void
    var replyFieldFocused: FocusState<Bool>.Binding? = nil

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

            ReplyDock(reply: $reply, onSend: onSend, externalFocus: replyFieldFocused)
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
                ProviderMark(provider: card.provider)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.project)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SteerColors.ink)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(card.state.color)
                            .frame(width: 6, height: 6)
                        Text(card.branchLabel ?? card.provider.displayName)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(SteerColors.secondaryInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            Text(card.age)
                .font(.system(size: 12, design: .monospaced))
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
               let image = UIImage(named: iconName) {
                Image(uiImage: image)
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
