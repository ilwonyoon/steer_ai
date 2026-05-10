import SwiftUI
import SteerCore

/// iOS Inbox uses the same card-stack pattern as Mac SteerRootView:
/// the central canvas always shows ONE ActionCardView at a time, and
/// horizontal swipes move between cards. There's no carousel and no
/// bottom navigation — sticking with a single focused card matches
/// the Mac UX so the two clients feel like the same product.
struct InboxView: View {
    @ObservedObject var inbox: SyncInbox

    @State private var focusedSessionId: String? = nil
    @State private var cardDragOffset: CGFloat = 0
    @State private var replyDrafts: [String: String] = [:]
    @State private var detailCard: ActionCard? = nil
    @State private var liveChipsExpanded = false

    private var cards: [ActionCard] {
        inbox.cards.map { CardPayloadMapping.actionCard(from: $0) }
    }

    /// Mac populates this from `loadLiveSessions(excluding: activeSessionIds)`
    /// — sessions that are running but not currently surfacing an action
    /// card. The relay payload doesn't carry a separate live-session
    /// feed yet, so iOS leaves it empty until the backend exposes it.
    /// Don't synthesize chips from cards: that's what Mac explicitly
    /// excludes.
    private var liveChips: [LiveSessionChip] { [] }

    private var currentIndex: Int {
        guard let focusedSessionId,
              let idx = cards.firstIndex(where: { $0.sessionId == focusedSessionId })
        else { return 0 }
        return idx
    }

    private var currentCard: ActionCard? {
        guard cards.indices.contains(currentIndex) else { return nil }
        return cards[currentIndex]
    }

    var body: some View {
        ZStack(alignment: .top) {
            SteerColors.appBackground.ignoresSafeArea()

            if !inbox.isSignedIn {
                SignInPrompt(inbox: inbox)
            } else {
                content
            }
        }
        .sheet(item: $detailCard) { card in
            DetailView(
                card: card,
                onClose: { detailCard = nil },
                onSend: { text in
                    Task {
                        if let payload = inbox.cards.first(where: { $0.sessionId == card.sessionId }) {
                            await inbox.sendReply(text: text, for: payload)
                        }
                        detailCard = nil
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
            HeaderBar()

            if !liveChips.isEmpty {
                LiveSessionChipRow(
                    chips: liveChips,
                    isExpanded: $liveChipsExpanded
                )
                .padding(.leading, 4)
            }

            if cards.isEmpty {
                EmptyStateView(
                    message: "No waiting actions",
                    detail: "Open Steer for Mac, turn on iPhone Sync, and let a wrapped session ask a question."
                )
                .frame(maxHeight: .infinity)
            } else if let card = currentCard {
                ActionCardView(
                    card: card,
                    reply: replyBinding(for: card.sessionId),
                    onSend: { text in send(text, to: card.sessionId) }
                )
                .id(card.id)
                .offset(x: cardDragOffset)
                .rotationEffect(.degrees(cardDragOffset / 34))
                .onTapGesture(count: 2) { detailCard = card }
                .gesture(cardSwipeGesture)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ActionCardCarousel(
                    cards: cards,
                    currentIndex: currentIndex,
                    onSelect: { tappedIndex in
                        guard cards.indices.contains(tappedIndex) else { return }
                        withAnimation(.snappy(duration: 0.24)) {
                            focusedSessionId = cards[tappedIndex].sessionId
                        }
                    }
                )
                .padding(.horizontal, -14) // bleed past parent's 14pt h-padding so the last tile isn't clipped at the screen edge
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .animation(.snappy(duration: 0.22), value: currentIndex)
    }

    private func replyBinding(for sessionId: String) -> Binding<String> {
        Binding(
            get: { replyDrafts[sessionId] ?? "" },
            set: { replyDrafts[sessionId] = $0.isEmpty ? nil : $0 }
        )
    }

    private func move(_ delta: Int) {
        guard !cards.isEmpty else { return }
        let next = (currentIndex + delta + cards.count) % cards.count
        focusedSessionId = cards[next].sessionId
    }

    private func send(_ text: String, to sessionId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            if let payload = inbox.cards.first(where: { $0.sessionId == sessionId }) {
                await inbox.sendReply(text: trimmed, for: payload)
            }
            replyDrafts[sessionId] = nil
        }
    }

    private var cardSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in cardDragOffset = value.translation.width }
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
}

private struct HeaderBar: View {
    var body: some View {
        HStack {
            Text("Steer")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SteerColors.secondaryInk)
            Spacer()
        }
        .frame(height: 28)
    }
}

private struct PageIndicator: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { idx in
                Circle()
                    .fill(idx == current ? SteerColors.ink : SteerColors.softSeparator)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.top, 4)
    }
}

private struct EmptyStateView: View {
    let message: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(SteerColors.tertiaryInk)
            Text(message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SteerColors.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(SteerColors.secondaryInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }
}

private struct SignInPrompt: View {
    @ObservedObject var inbox: SyncInbox
    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 56))
                .foregroundStyle(SteerColors.tertiaryInk)
            Text("Sign in to see Steer cards from your Mac")
                .font(.headline)
                .multilineTextAlignment(.center)
            if let err = inbox.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                Task {
                    isSigningIn = true
                    await inbox.startSignInWithApple()
                    isSigningIn = false
                }
            } label: {
                HStack {
                    if isSigningIn { ProgressView().controlSize(.small) }
                    Text(isSigningIn ? "Signing in…" : "Sign in with Apple")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.black)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .disabled(isSigningIn)
            Spacer()
        }
        .padding()
    }
}

extension CardPayload: Identifiable {
    public var id: String { cardId }
}
