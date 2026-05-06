import SwiftUI

struct SteerRootView: View {
    @State private var cards = ActionCard.samples
    @State private var currentIndex = 0
    @State private var isShowingDetail = false
    @State private var cardDragOffset: CGFloat = 0

    private var currentCard: ActionCard {
        cards[currentIndex]
    }

    var body: some View {
        ZStack {
            Color(red: 0.97, green: 0.97, blue: 0.98)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                topBar

                ZStack {
                    CardBackplate(offset: 34, scale: 0.92, opacity: 0.20)
                    CardBackplate(offset: 18, scale: 0.96, opacity: 0.42)

                    ActionCardView(
                        card: currentCard,
                        onOpenDetail: { isShowingDetail = true },
                        onSend: { text in sendFromCard(text) }
                    )
                    .id(currentCard.id)
                    .offset(x: cardDragOffset)
                    .rotationEffect(.degrees(cardDragOffset / 34))
                    .gesture(cardSwipeGesture)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PageDots(count: cards.count, index: currentIndex)
                    .padding(.bottom, 8)
            }
            .padding(14)

            if isShowingDetail {
                DetailView(
                    card: currentCard,
                    onClose: { isShowingDetail = false },
                    onSend: { text in insertReply(text) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 375, height: 812)
        .animation(.snappy(duration: 0.22), value: currentIndex)
        .animation(.snappy(duration: 0.22), value: isShowingDetail)
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Steer")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(cards.count) waiting actions")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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

    private func move(_ delta: Int) {
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
        cards[currentIndex].thread.append(ThreadMessage(sender: .user, text: text))
        move(1)
    }

    private func insertReply(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cards[currentIndex].thread.append(ThreadMessage(sender: .user, text: text))
    }
}

private struct RoundIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .steerGlass(cornerRadius: 18, interactive: true)
        .accessibilityLabel(systemName == "chevron.left" ? "Previous card" : "Next card")
    }
}

private struct CardBackplate: View {
    let offset: CGFloat
    let scale: CGFloat
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
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
                    .fill(item == index ? Color.accentColor : Color.black.opacity(0.08))
                    .frame(width: item == index ? 20 : 7, height: 7)
            }
        }
        .frame(height: 38)
    }
}

#Preview {
    SteerRootView()
}
