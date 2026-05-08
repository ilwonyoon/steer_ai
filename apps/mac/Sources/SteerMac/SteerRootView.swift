import SwiftUI

struct SteerRootView: View {
    private let store = LocalSteerStore()
    private let notificationService = ActionNotificationService.shared
    @ObservedObject private var status = SteerAppDelegate.status

    @State private var cards: [ActionCard] = []
    @State private var liveChips: [LiveSessionChip] = []
    @State private var currentIndex = 0
    @State private var cardDragOffset: CGFloat = 0
    @State private var isLoading = true
    @State private var lastError: String?
    @State private var didLoadInitialCards = false
    @State private var notifiedCardFingerprints = Set<String>()
    @State private var liveChipsExpanded = false
    @Namespace private var sessionTransition

    private var currentCard: ActionCard? {
        guard cards.indices.contains(currentIndex) else { return nil }
        return cards[currentIndex]
    }

    var body: some View {
        ZStack(alignment: .top) {
            SteerColors.appBackground
                .ignoresSafeArea()

            Text("Steer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SteerColors.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 28)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            VStack(spacing: 12) {
                if let lastError {
                    ErrorBanner(message: lastError, onDismiss: { self.lastError = nil })
                }

                if !liveChips.isEmpty {
                    LiveSessionChipRow(
                        chips: liveChips,
                        isExpanded: $liveChipsExpanded
                    )
                    .padding(.leading, 4)
                }

                cardStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ActionCardCarousel(
                    cards: cards,
                    currentIndex: currentIndex,
                    namespace: sessionTransition,
                    onSelect: { tappedIndex in
                        guard cards.indices.contains(tappedIndex) else { return }
                        withAnimation(.snappy(duration: 0.24)) {
                            currentIndex = tappedIndex
                        }
                    }
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 36)
            .padding(.bottom, 12)
        }
        .frame(width: 375, height: 600)
        .background(keyboardShortcuts)
        .animation(.snappy(duration: 0.22), value: currentIndex)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: cards.map(\.sessionId))
        .onChange(of: status.pendingFocusSessionId) { _, newValue in
            guard let sessionId = newValue else { return }
            if let index = cards.firstIndex(where: { $0.sessionId == sessionId }) {
                withAnimation(.snappy(duration: 0.24)) {
                    currentIndex = index
                }
            }
            status.pendingFocusSessionId = nil
        }
        .task {
            await refreshLoop()
        }
    }

    @ViewBuilder
    private var cardStack: some View {
        if isLoading && cards.isEmpty {
            ProgressView()
                .controlSize(.small)
        } else if let currentCard {
            ActionCardView(
                card: currentCard,
                onSend: { text, attachments in sendFromCard(text, attachments: attachments) }
            )
            .matchedGeometryEffect(id: currentCard.sessionId, in: sessionTransition)
            .id(currentCard.id)
            .offset(x: cardDragOffset)
            .rotationEffect(.degrees(cardDragOffset / 34))
            .gesture(cardSwipeGesture)
        } else {
            EmptyStateView(message: emptyStateMessage, detail: emptyStateDetail)
        }
    }

    private var emptyStateMessage: String {
        if let lastError {
            return lastError
        }
        if !liveChips.isEmpty {
            return "No waiting actions"
        }
        return "No Steer sessions yet"
    }

    private var emptyStateDetail: String {
        if !liveChips.isEmpty {
            return "Running sessions appear here when they stop."
        }
        return "In a terminal:\n  cd ~/your/project\n  steer codex   # or steer claude"
    }

    private func move(_ delta: Int) {
        guard !cards.isEmpty else { return }
        currentIndex = (currentIndex + delta + cards.count) % cards.count
    }

    private var cardSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                cardDragOffset = value.translation.width
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard abs(horizontal) > 82, abs(horizontal) > vertical else {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)) {
                        cardDragOffset = 0
                    }
                    return
                }

                let direction = horizontal < 0 ? 1 : -1
                let exitOffset: CGFloat = horizontal < 0 ? -460 : 460
                withAnimation(.easeIn(duration: 0.16)) {
                    cardDragOffset = exitOffset
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
                    move(direction)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        cardDragOffset = 0
                    }
                }
            }
    }

    private func sendFromCard(_ text: String, attachments: [ReplyAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let currentCard else { return }

        Task {
            await send(trimmed, attachments: attachments, to: currentCard.sessionId)
            move(1)
        }
    }

    private func send(_ text: String, attachments: [ReplyAttachment] = [], to sessionId: String) async {
        do {
            try await store.send(text, attachments: attachments.map(\.url), to: sessionId)
            await reload()
        } catch {
            lastError = "send failed"
        }
    }

    private func refreshLoop() async {
        await reload()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            await reload()
        }
    }

    private var keyboardShortcuts: some View {
        ZStack {
            Button("Previous card") { move(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next card") { move(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Refresh") {
                Task { await reload() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func reload() async {
        let loadedCards = await store.loadCards()
        await notifyForNewCards(loadedCards)
        let activeSessionIds = Set(loadedCards.map(\.sessionId))
        let loadedChips = await store.loadLiveSessions(excluding: activeSessionIds)
        cards = loadedCards
        liveChips = loadedChips
        isLoading = false
        if currentIndex >= cards.count {
            currentIndex = max(cards.count - 1, 0)
        }
        if !loadedCards.isEmpty || !loadedChips.isEmpty {
            lastError = nil
        }
        SteerAppDelegate.status.waitingCount = loadedCards.count
    }

    private func notifyForNewCards(_ loadedCards: [ActionCard]) async {
        let notifiableCards = loadedCards.filter(\.shouldNotify)
        let activeFingerprints = Set(notifiableCards.map(notificationFingerprint(for:)))

        guard didLoadInitialCards else {
            notifiedCardFingerprints = activeFingerprints
            didLoadInitialCards = true
            return
        }

        for card in notifiableCards where !notifiedCardFingerprints.contains(notificationFingerprint(for: card)) {
            await notificationService.notify(card: card)
        }

        notifiedCardFingerprints = activeFingerprints
    }
}


private struct CardBackplate: View {
    let offset: CGFloat
    let scale: CGFloat
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(SteerColors.cardBackplate)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(SteerColors.softSeparator, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: 590)
            .scaleEffect(scale)
            .offset(y: offset)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { item in
                Capsule()
                    .fill(item == index ? Color.accentColor : SteerColors.subtleFill)
                    .frame(width: item == index ? 20 : 7, height: 7)
            }
        }
        .frame(height: 38)
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(SteerColors.blocked)
            Text(message)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(SteerColors.ink)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(SteerColors.blocked.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SteerColors.blocked.opacity(0.30), lineWidth: 1)
        }
    }
}

private struct LiveSessionChipRow: View {
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
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        }
    }
}

private struct RunningBadge: View {
    let chips: [LiveSessionChip]

    private var runningCount: Int {
        chips.filter { $0.runState == "running" }.count
    }
    private var waitingCount: Int {
        chips.filter { $0.runState == "waiting" }.count
    }
    private var blockedCount: Int {
        chips.filter { $0.runState == "blocked" }.count
    }

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
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(SteerColors.secondaryInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
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

private struct LiveSessionChipPill: View {
    let chip: LiveSessionChip

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(chip.project)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
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

private struct ActionCardCarousel: View {
    let cards: [ActionCard]
    let currentIndex: Int
    let namespace: Namespace.ID
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
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                                    removal: .scale(scale: 0.95).combined(with: .opacity)
                                ))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 0)
                    .padding(.trailing, 18)
                }
                .frame(height: 100)
            }
        }
    }
}

private struct CompactActionCardView: View {
    let card: ActionCard
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProviderMark(provider: card.provider, size: 11)
                Text(card.project)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SteerColors.ink)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(headerTint)

            Text(summaryLine)
                .font(.system(size: 10.5, design: .monospaced))
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
                .stroke(isCurrent ? Color.accentColor.opacity(0.55) : SteerColors.softSeparator, lineWidth: isCurrent ? 1.4 : 1)
        }
    }
}

private struct EmptyStateView: View {
    let message: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(SteerColors.tertiaryInk)
            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(SteerColors.secondaryInk)
            Text(detail)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(SteerColors.tertiaryInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: 540)
        .background(SteerColors.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(SteerColors.separator, lineWidth: 1)
        }
    }
}

#Preview {
    SteerRootView()
}
