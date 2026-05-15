import SwiftUI

/// Direct port of Mac's LiveSessionChipRow + RunningBadge +
/// LiveSessionChipPill + ActionCardCarousel + CompactActionCardView.
/// Same visuals so iPhone shows the running pill at top and a
/// horizontal-scrolling compact carousel under the focused card.

struct LiveSessionChipRow: View {
    let chips: [LiveSessionChip]
    @Binding var isExpanded: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        LiveSessionChipPill(chip: chip)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 4)
            }
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)

            HStack {
                RunningBadge(chips: chips)
                Spacer(minLength: 0)
            }
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(!isExpanded)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
        }
    }
}

struct RunningBadge: View {
    let chips: [LiveSessionChip]

    private var runningCount: Int { chips.filter { $0.runState == "running" }.count }
    private var waitingCount: Int { chips.filter { $0.runState == "waiting" }.count }
    private var blockedCount: Int { chips.filter { $0.runState == "blocked" }.count }

    private var dominantColor: Color {
        if blockedCount > 0 { return SteerColors.blocked }
        if runningCount > 0 { return SteerColors.running }
        return SteerColors.waiting
    }

    private var label: String {
        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if waitingCount > 0 { parts.append("\(waitingCount) waiting") }
        if blockedCount > 0 { parts.append("\(blockedCount) blocked") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dominantColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SteerColors.secondaryInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(SteerColors.cardBackground, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(SteerColors.softSeparator, lineWidth: 1)
        }
        .shadow(color: SteerColors.cardShadow.opacity(0.5), radius: 6, y: 2)
        .accessibilityLabel("\(chips.count) live session\(chips.count == 1 ? "" : "s"); \(label)")
        .accessibilityHint("Tap to expand")
    }
}

struct LiveSessionChipPill: View {
    let chip: LiveSessionChip

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(chip.project)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SteerColors.secondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(SteerColors.cardBackground, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(SteerColors.softSeparator, lineWidth: 1)
        }
        .shadow(color: SteerColors.cardShadow.opacity(0.5), radius: 6, y: 2)
        .accessibilityLabel("\(chip.project), \(chip.runState)")
    }

    private var stateColor: Color {
        switch chip.runState {
        case "blocked": return SteerColors.blocked
        case "waiting": return SteerColors.waiting
        default: return SteerColors.running
        }
    }
}

struct ActionCardCarousel<Card: CardDisplayable & Identifiable>: View
    where Card.ID == String
{
    let cards: [Card]
    let currentIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        if cards.isEmpty {
            Color.clear.frame(height: 0)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            CompactActionCardView(card: card, isCurrent: index == currentIndex)
                                .onTapGesture { onSelect(index) }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 0)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: 100)
            }
        }
    }
}

struct CompactActionCardView<Card: CardDisplayable>: View {
    let card: Card
    let isCurrent: Bool

    private var headerTint: Color {
        SteerColors.hueTint(hue: card.accentHue, intensity: 1.0)
    }

    private var summaryLine: AttributedString {
        let trimmed = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? card.title : trimmed
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attributed
        }
        return AttributedString(raw)
    }

    // Compact carousel ride-along for the secondary cards. Mac uses a
    // narrower 132pt window; iOS gets a touch more breathing room for
    // touch targets but keeps the same proportions. Typography is SF
    // (was monospaced) so the project label reads like a label, not
    // a debug field.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProjectMark(emoji: card.emoji, size: 14)
                Text(card.project)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SteerColors.ink)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(headerTint)

            Text(summaryLine)
                .font(.system(size: 12))
                .foregroundStyle(SteerColors.secondaryInk)
                .lineLimit(3, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 11)
                .padding(.vertical, 11)
                .background(SteerColors.cardBackground)
        }
        .frame(width: 132, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isCurrent ? Color.accentColor.opacity(0.7) : SteerColors.softSeparator,
                    lineWidth: isCurrent ? 1.5 : 1
                )
        }
    }
}
