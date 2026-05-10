import SwiftUI
import SteerCore
import os.log

private let diagLog = Logger(subsystem: "ai.steer.ios", category: "diag")

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
    @State private var liveChipsExpanded = false
    @FocusState private var replyFieldFocused: Bool
    /// Tracks the actual keyboard phase (will-show / did-hide). The
    /// compact carousel renders only when this is false, so it never
    /// reinserts mid-keyboard-dismiss — it waits for didHide instead
    /// of guessing with a time-based delay.
    @StateObject private var keyboard = KeyboardObserver()

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
                .contentShape(Rectangle())
                .onTapGesture { replyFieldFocused = false }

            if !inbox.isSignedIn {
                SignInPrompt(inbox: inbox)
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        // Two independent containers, NOT a single VStack column:
        //   - cardArea: header + card. Lives in its own VStack and
        //     responds to system keyboard avoidance directly.
        //   - carousel: pinned to bottom in a separate layer. Renders
        //     only when keyboard is fully hidden (KeyboardObserver
        //     listens for keyboardDidHide). Its insert/remove no
        //     longer changes the card area's frame.
        ZStack(alignment: .bottom) {
            cardArea

            if !cards.isEmpty {
                ActionCardCarousel(
                    cards: cards,
                    currentIndex: currentIndex,
                    onSelect: { tappedIndex in
                        guard cards.indices.contains(tappedIndex) else { return }
                        withAnimation(.easeOut(duration: 0.22)) {
                            focusedSessionId = cards[tappedIndex].sessionId
                        }
                    }
                )
                .padding(.bottom, 12)
                // Carousel always exists at the bottom of the screen
                // and slides DOWN by exactly the keyboard's height.
                // Result: as the keyboard rises, it appears to "push"
                // the carousel off-screen; as the keyboard slides
                // down, the carousel slides up behind it on the same
                // curve. No discrete insert/remove, no empty band.
                .offset(y: keyboard.height)
                .ignoresSafeArea(.keyboard)
            }
        }
    }

    @ViewBuilder
    private var cardArea: some View {
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
                    onSend: { text in send(text, to: card.sessionId) },
                    replyFieldFocused: $replyFieldFocused
                )
                .id(card.id)
                .offset(x: cardDragOffset)
                .gesture(cardSwipeGesture)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.height) { old, new in
                            diagLog.notice("card.height \(old, format: .fixed(precision: 1)) -> \(new, format: .fixed(precision: 1))")
                        }
                    }
                )
                .onChange(of: replyFieldFocused) { _, focused in
                    diagLog.notice("focus -> \(focused)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        // Reserve carousel's footprint when the keyboard is hidden, so
        // the card never sits under the carousel layer below. When the
        // keyboard is visible the system pushes us up so the input is
        // visible — at that moment carousel isn't rendered, so we drop
        // the reserved space too. This keeps card height stable
        // throughout the dismiss animation: the only thing changing is
        // the keyboard frame, which the system handles smoothly.
        // Padding shrinks as the keyboard rises by the same amount
        // the carousel slides off-screen. KeyboardObserver wraps the
        // height update in UIKit's exact keyboard animation curve,
        // so this padding follows the keyboard in lockstep — no flash,
        // no empty band above the keyboard.
        .padding(.bottom, max(12, carouselFootprint - keyboard.height))
        .animation(.easeOut(duration: 0.22), value: currentIndex)
    }

    private var carouselFootprint: CGFloat { 100 + 12 }

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
                    // Snap back without spring overshoot — Mac uses
                    // a softer interactive spring but on iPhone the
                    // bounce reads as the card "shaking".
                    withAnimation(.easeOut(duration: 0.18)) {
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
            Spacer()
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
