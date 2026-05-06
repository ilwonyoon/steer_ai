import SwiftUI

struct ActionCardView: View {
    let card: ActionCard
    let onOpenDetail: () -> Void
    let onSend: (String) -> Void

    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionHeader(card: card)

            Text(card.title)
                .font(.system(size: 28, weight: .bold))
                .lineSpacing(-1)
                .padding(.top, 46)

            Text(card.summary)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            Text(card.reason)
                .font(.system(size: 14))
                .lineSpacing(4)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                }
                .padding(.top, 18)

            Spacer(minLength: 24)

            ReplyDock(chips: card.chips, reply: $reply, onSend: onSend)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: 590)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 34, y: 22)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: onOpenDetail)
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
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(card.state.color)
                            .frame(width: 6, height: 6)
                        Text(card.provider.displayName)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(card.age)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.52), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
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
