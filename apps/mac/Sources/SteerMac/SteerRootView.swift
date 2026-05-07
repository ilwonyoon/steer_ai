import SwiftUI

struct SteerRootView: View {
    private let store = LocalSteerStore()

    @State private var cards: [ActionCard] = []
    @State private var currentIndex = 0
    @State private var cardDragOffset: CGFloat = 0
    @State private var isLoading = true
    @State private var lastError: String?

    private var currentCard: ActionCard? {
        guard cards.indices.contains(currentIndex) else { return nil }
        return cards[currentIndex]
    }

    var body: some View {
        ZStack {
            SteerColors.appBackground
                .ignoresSafeArea()

            VStack(spacing: 12) {
                topBar

                cardStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                PageDots(count: cards.count, index: currentIndex)
                    .padding(.bottom, 8)
            }
            .padding(14)
        }
        .frame(width: 375, height: 812)
        .animation(.snappy(duration: 0.22), value: currentIndex)
        .task {
            await refreshLoop()
        }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Steer")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SteerColors.ink)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(SteerColors.secondaryInk)
            }

            Spacer()

            HStack(spacing: 8) {
                RoundIconButton(systemName: "chevron.left") {
                    move(-1)
                }
                RoundIconButton(systemName: "chevron.right") {
                    move(1)
                }
            }
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var cardStack: some View {
        if isLoading && cards.isEmpty {
            ProgressView()
                .controlSize(.small)
        } else if let currentCard {
            ZStack {
                CardBackplate(offset: 34, scale: 0.92, opacity: 0.20)
                CardBackplate(offset: 18, scale: 0.96, opacity: 0.42)

                ActionCardView(
                    card: currentCard,
                    onSend: { text in sendFromCard(text) }
                )
                .id(currentCard.id)
                .offset(x: cardDragOffset)
                .rotationEffect(.degrees(cardDragOffset / 34))
                .gesture(cardSwipeGesture)
            }
        } else {
            EmptyStateView(message: lastError ?? "No Steer sessions yet")
        }
    }

    private var statusText: String {
        if let lastError {
            return lastError
        }
        if cards.isEmpty {
            return isLoading ? "loading sessions" : "no active sessions"
        }
        return "\(cards.count) sessions"
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

    private func sendFromCard(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let currentCard else { return }

        Task {
            await send(text, to: currentCard.sessionId)
            move(1)
        }
    }

    private func send(_ text: String, to sessionId: String) async {
        do {
            try await store.send(text, to: sessionId)
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

    private func reload() async {
        let loadedCards = await store.loadCards()
        cards = loadedCards
        isLoading = false
        if currentIndex >= cards.count {
            currentIndex = max(cards.count - 1, 0)
        }
        if !loadedCards.isEmpty {
            lastError = nil
        }
    }
}

private struct RoundIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SteerColors.ink)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .background(SteerColors.controlFill, in: Circle())
        .overlay {
            Circle()
                .stroke(SteerColors.controlStroke, lineWidth: 1)
        }
        .shadow(color: SteerColors.controlShadow, radius: 12, y: 5)
        .accessibilityLabel(systemName == "chevron.left" ? "Previous card" : "Next card")
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

private struct EmptyStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(SteerColors.tertiaryInk)
            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(SteerColors.secondaryInk)
            Text("Run steer claude or steer codex in a terminal.")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(SteerColors.tertiaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: 590)
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
