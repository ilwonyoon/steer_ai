import SwiftUI
import SteerCore
import AuthenticationServices
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
    /// Memoized projection of `inbox.cards` -> `[ActionCard]`. Recomputed
    /// only when `inbox.cards` actually changes, not on every SwiftUI
    /// re-render. Markdown rendering inside CardPayloadMapping was
    /// running on every keystroke / focus tick and stalling input
    /// response on the device.
    @State private var cards: [ActionCard] = []
    @FocusState private var replyFieldFocused: Bool
    /// Tracks the actual keyboard phase (will-show / did-hide). The
    /// compact carousel renders only when this is false, so it never
    /// reinserts mid-keyboard-dismiss — it waits for didHide instead
    /// of guessing with a time-based delay.
    @StateObject private var keyboard = KeyboardObserver()
    @StateObject private var devicePresence: DevicePresenceObserver
    @State private var showsMacSyncStatus = false
    @State private var showsSettings = false
    /// Sticks in UserDefaults so the onboarding flow runs exactly
    /// once per install. `@AppStorage` keeps the state synced with
    /// the persisted bool; setting it to `true` is what advances
    /// the user out of OnboardingFlowView into SignInPrompt.
    @AppStorage("ai.steer.onboardingCompleted")
    private var onboardingCompleted: Bool = false

    private func completeOnboarding() {
        withAnimation(.easeInOut(duration: 0.28)) {
            onboardingCompleted = true
        }
    }

    init(inbox: SyncInbox) {
        self.inbox = inbox
        _devicePresence = StateObject(wrappedValue: DevicePresenceObserver(inbox: inbox))
    }

    /// Driven by an .onReceive observer below. Don't recompute inside
    /// computed properties — markdown parsing in CardPayloadMapping is
    /// expensive enough to be visible on input focus.

    /// Mac populates this from `loadLiveSessions(excluding: activeSessionIds)`
    /// — sessions that are running but not currently surfacing an action
    /// card. The relay payload doesn't carry a separate live-session
    /// feed yet, so iOS leaves it empty until the backend exposes it.
    /// Don't synthesize chips from cards: that's what Mac explicitly
    /// excludes.
    private var liveChips: [LiveSessionChip] { [] }

    private var isMacOfflineWithCards: Bool {
        guard !cards.isEmpty else { return false }
        switch devicePresence.state {
        case .stale, .offline: return true
        default: return false
        }
    }

    private var failedRepliesCount: Int {
        inbox.pendingReplies.reduce(0) { acc, p in
            if case .failed = p.status { return acc + 1 }
            return acc
        }
    }

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
            // Solid fill only — gestures live on a separate layer below.
            SteerColors.appBackground.ignoresSafeArea()

            // Keyboard-dismiss layer. Active only while the keyboard
            // is up (`keyboard.height > 0`), otherwise allows hit-test
            // to pass straight through to whatever's underneath. This
            // is what makes "tap any blank space → keyboard closes"
            // work without stealing the first tap on HeaderBar's
            // Settings or Mac chip buttons. Buttons sit higher in the
            // ZStack and SwiftUI's hit-test consults them first; this
            // layer only catches taps that hit empty background.
            if keyboard.height > 0 {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        replyFieldFocused = false
                    }
                    .accessibilityHidden(true)
            }

            // Order: SignIn → Onboarding → Inbox. The user
            // ratifies their identity first (the standard "this is
            // an account-bound app" mental model), then we teach
            // them how the card flow works *as our authenticated
            // user*, then we drop them in their real inbox.
            if !inbox.isSignedIn {
                SignInPrompt(inbox: inbox)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("sign-in-prompt")
            } else if !onboardingCompleted {
                OnboardingFlowView(onComplete: completeOnboarding)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("onboarding-flow")
                    .transition(.opacity)
            } else {
                content
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("inbox-content")
            }
        }
        .sheet(isPresented: $showsMacSyncStatus) {
            MacSyncStatusView(
                observer: devicePresence,
                pendingReplies: inbox.pendingReplies,
                onRetry: { inbox.retryPendingReply($0) },
                onCancel: { inbox.cancelPendingReply($0) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView(inbox: inbox)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showsSettings = false }
                        }
                    }
            }
        }
        .task {
            devicePresence.start()
            cards = inbox.cards.map { CardPayloadMapping.actionCard(from: $0) }
            await inbox.refreshNotificationPermission()
        }
        .onReceive(inbox.$cards) { newCards in
            cards = newCards.map { CardPayloadMapping.actionCard(from: $0) }
            // If a deep-link tap arrived before the card showed up
            // (relay round trip), re-honor it once the card lands.
            if let pending = inbox.pendingFocusSessionId,
               cards.contains(where: { $0.sessionId == pending }) {
                focusedSessionId = pending
                inbox.clearPendingFocus()
            }
        }
        .onReceive(inbox.$pendingFocusSessionId) { pending in
            guard let sessionId = pending,
                  cards.contains(where: { $0.sessionId == sessionId }) else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                focusedSessionId = sessionId
            }
            inbox.clearPendingFocus()
        }
        .onDisappear {
            devicePresence.stop()
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
    private var emptyState: some View {
        switch devicePresence.state {
        case .demo:
            EmptyStateView(
                icon: "tray",
                message: "Demo cards",
                detail: "Tap Use Live Sync to connect your Mac."
            )
        case .connecting:
            // First poll still in flight after sign-in. Reads as
            // "we're trying" — not "no Mac" yet. Same shape as
            // .neverConnected; just softer copy.
            EmptyStateView(
                icon: "antenna.radiowaves.left.and.right",
                message: "Reaching your Mac",
                detail: "Looking for a paired Steer for Mac…"
            )
        case .neverConnected:
            // First poll returned and confirmed no paired Mac.
            // CTAs surface here so the user has an obvious path
            // forward.
            EmptyStateView(
                icon: "terminal",
                message: "No Steer sessions yet",
                detail: "In a terminal:\n  cd ~/your/project\n  steer codex   # or steer claude",
                primaryCTA: ("Set Up Mac", { showsMacSyncStatus = true }),
                secondaryCTA: ("Try Demo", { inbox.enterDemoMode() })
            )
        case .connected:
            // Mac is reachable. Mirror Mac's "No waiting actions"
            // exactly — same icon, same copy. No CTAs (the user is
            // already wired up and just needs a session to pause).
            EmptyStateView(
                icon: "terminal",
                message: "No waiting actions",
                detail: "Running sessions appear here when they stop."
            )
        case .stale, .offline:
            // No CTA — there's nothing the user can do from the
            // phone to bring the Mac back online; surfacing a "Mac
            // Status" button just made them tap something that
            // restated the same fact. The chip at the top already
            // signals offline/stale, the detail line tells them
            // replies queue.
            EmptyStateView(
                icon: "wifi.slash",
                message: "Mac offline",
                detail: "Replies will queue until your Mac is back."
            )
        case .error:
            // Same reasoning as .stale / .offline — opening the Mac
            // Sync sheet doesn't fix a relay outage. Keep the surface
            // honest: the line tells them what's wrong, and that's it.
            EmptyStateView(
                icon: "exclamationmark.triangle",
                message: "Sync issue",
                detail: "Can't reach the relay."
            )
        }
    }

    @ViewBuilder
    private var cardArea: some View {
        VStack(spacing: 12) {
            HeaderBar(
                isDemo: inbox.isDemoMode,
                onExitDemo: { inbox.exitDemoMode() },
                connectionState: devicePresence.state,
                // Chip "N running" now derives from iPhone-local
                // state — the user's own pending replies that
                // haven't yet been answered by a new card. This is
                // the same set the Mac side computes from
                // `instructedSessions`. The relay's
                // /v1/sync/sessions polling is no longer the source.
                runningCount: inbox.activeSessionIds.count,
                failedCount: failedRepliesCount,
                onTapChip: { showsMacSyncStatus = true },
                onTapSettings: { showsSettings = true }
            )

            if isMacOfflineWithCards {
                MacOfflineBanner { showsMacSyncStatus = true }
            }

            if inbox.notificationPermission == .denied {
                NotificationsDeniedBanner()
            }
            // PendingRepliesChip + LiveSessionChipRow were separate
            // capsules stacked below the header — that broke the
            // user's mental model that header chip and activity state
            // are the same slot. The MacConnectionChip now folds
            // sending / failed / running counts into its label, and
            // MacSyncStatusView (sheet) lists the per-row detail.

            if inbox.loadPhase != .ready && cards.isEmpty {
                // Cold-start placeholder. HeaderBar above stays
                // rendered and tappable; the card area waits until
                // the first card list lands so the user doesn't see
                // cards reshuffling. We also gate on cards.isEmpty
                // so a warm-launch (process still alive with cards
                // in memory) jumps straight to the cards instead of
                // flashing the spinner for one frame.
                SyncingPlaceholder()
                    .frame(maxHeight: .infinity)
            } else if cards.isEmpty {
                emptyState
                    .frame(maxHeight: .infinity)
            } else if let card = currentCard {
                ActionCardView(
                    card: card,
                    reply: replyBinding(for: card.sessionId),
                    onSend: { text in send(text, to: card.sessionId) },
                    replyFieldFocused: $replyFieldFocused,
                    onBodyTap: { replyFieldFocused = false }
                )
                .id(card.id)
                .offset(x: cardDragOffset)
                .gesture(cardSwipeGesture)
                // Keyboard-dismiss on tap is delegated to the
                // appBackground layer (which never sits over a
                // Button). Re-adding a simultaneousGesture here
                // steals first taps from HeaderBar's Settings/chip
                // buttons (they live inside this card-area subtree),
                // and the user has to tap 4–5x to actually open
                // Settings.
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

    // Carousel height (100) + breathing room above (16) + breathing
    // room below (12). The top breathing room is what visually
    // separates the main card from the compact strip — matches the
    // 12pt VStack spacing the Mac shell uses between cardStack and
    // ActionCardCarousel.
    private var carouselFootprint: CGFloat { 100 + 16 + 12 }

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
        // Clear the draft + dismiss focus FIRST so the keyboard can
        // start retreating in the same frame. Network work happens
        // optimistically inside sendReply.
        replyDrafts[sessionId] = nil
        replyFieldFocused = false
        guard let payload = inbox.cards.first(where: { $0.sessionId == sessionId }) else { return }
        if inbox.isDemoMode {
            Task { await inbox.sendDemoReply(text: trimmed, for: payload) }
        } else {
            inbox.sendReply(text: trimmed, for: payload)  // already optimistic + Task internally
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

/// Applies the real iOS 26 Liquid Glass effect (`.glassEffect`) to
/// the receiving view, falling back to a translucent material on
/// iOS 17–25 so the capsule still reads against the dark card
/// stack. `interactive()` gives the iOS 26 highlight on press.
extension View {
    @ViewBuilder
    func steerGlass<S: Shape>(shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(SteerColors.softSeparator, lineWidth: 0.5))
        }
    }
}

private struct HeaderBar: View {
    var isDemo: Bool = false
    var onExitDemo: (() -> Void)? = nil
    var connectionState: DevicePresenceObserver.State = .neverConnected
    var runningCount: Int = 0
    var failedCount: Int = 0
    var onTapChip: (() -> Void)? = nil
    var onTapSettings: (() -> Void)? = nil

    var body: some View {
        // Layout: Mac connection status on the leading edge (the
        // first glance answers "is this even connected?"), Settings
        // on the trailing edge (where Done buttons live).
        // 44×44 hit targets per iOS 26 HIG.
        HStack(spacing: 8) {
            if isDemo, let onExitDemo {
                Button("Use Live Sync", action: onExitDemo)
                    .font(.system(size: 14, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .steerGlass(shape: Capsule())
            } else if let onTapChip {
                MacConnectionChip(
                    state: connectionState,
                    runningCount: runningCount,
                    failedCount: failedCount,
                    onTap: onTapChip
                )
            }

            Spacer()

            if let onTapSettings {
                Button(action: onTapSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(SteerColors.ink)
                        .frame(width: 44, height: 44)
                        .steerGlass(shape: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-button")
            }
        }
        .frame(height: 56)
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

/// Cold-start placeholder. Renders quietly while
/// `SyncInbox.loadPhase` != .ready. HeaderBar stays mounted above
/// so Settings and the Mac chip are tappable from frame zero.
/// See section B2 of docs/SYNC_ARCHITECTURE_V2.md.
private struct SyncingPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("Syncing…")
                .font(.system(size: 14))
                .foregroundStyle(SteerColors.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("syncing-placeholder")
    }
}

private struct MacOfflineBanner: View {
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(SteerColors.disconnected)
                Text("Mac offline — replies will queue")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SteerColors.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SteerColors.tertiaryInk)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SteerColors.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SteerColors.softSeparator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct NotificationsDeniedBanner: View {
    var body: some View {
        Button(action: openSettings) {
            HStack(spacing: 8) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(SteerColors.secondaryInk)
                Text("Allow notifications to get lock-screen banners")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SteerColors.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SteerColors.tertiaryInk)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SteerColors.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SteerColors.softSeparator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Empty state styled exactly like Mac SteerRootView's
/// EmptyStateView so the two clients feel like the same product:
/// terminal SF Symbol, monospaced message, card-shaped container.
/// Optional CTAs are only used by the signed-out / demo / never-
/// connected paths; the canonical "no cards waiting" state shows
/// only the icon + two lines of monospaced text, mirroring Mac.
private struct EmptyStateView: View {
    let icon: String
    let message: String
    let detail: String
    var primaryCTA: (label: String, action: () -> Void)? = nil
    var secondaryCTA: (label: String, action: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(SteerColors.tertiaryInk)
            Text(message)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SteerColors.secondaryInk)
                .multilineTextAlignment(.center)
            // Shell snippet stays monospaced — it's literal commands
            // the user copies. Headline above is SF body weight per
            // iOS HIG.
            Text(detail)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(SteerColors.tertiaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            if primaryCTA != nil || secondaryCTA != nil {
                VStack(spacing: 8) {
                    if let primary = primaryCTA {
                        Button(primary.label, action: primary.action)
                            .font(.callout.weight(.semibold))
                            .frame(width: 240, height: 40)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .buttonStyle(.plain)
                    }
                    if let secondary = secondaryCTA {
                        Button(secondary.label, action: secondary.action)
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SteerColors.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(SteerColors.separator, lineWidth: 1)
        }
    }
}

private struct SignInPrompt: View {
    @ObservedObject var inbox: SyncInbox
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSigningIn = false

    var body: some View {
        ZStack {
            // Animated dot grid + bezier "attention" routing. Pure
            // background — every interactive element sits in the
            // VStack above it.
            RoutingFieldView()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // Light bottom vignette so the CTA stays legible
            // without washing out the whole field. Top stays
            // open — the routing is the hero.
            LinearGradient(
                colors: [
                    SteerColors.appBackground.opacity(0.0),
                    SteerColors.appBackground.opacity(0.0),
                    SteerColors.appBackground.opacity(0.35),
                    SteerColors.appBackground.opacity(0.55)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            .ignoresSafeArea()

            VStack(spacing: 14) {
                Spacer()

                // App icon sits above the wordmark so the screen
                // reads as "this is Steer" the moment it appears.
                // Without it, the SignIn page was just typography
                // on a moving grid and the user couldn't tell which
                // app it belonged to. The imageset is a copy of
                // AppIcon's 1024 master, so the lock-screen icon
                // and this in-app glyph stay in sync.
                Image("steer-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .shadow(color: Color.black.opacity(0.18), radius: 14, y: 6)
                    .padding(.bottom, 6)

                // Mono wordmark + value prop. The routing field
                // is the visual hero; the foreground stays
                // typographic. SF Mono is the closest built-in
                // approximation of JetBrains Mono — same kind of
                // even-rhythm geometric grotesque — so we don't
                // need to ship a custom font binary.
                Text("Steer")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SteerColors.ink)

                Text("Never let your AI sit idle.")
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 2)

                if let err = inbox.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 14) {
                    // Apple's native button is required by App
                    // Store guideline 4.8. XCUITest can't drive
                    // the system Apple ID sheet, so under the
                    // `--uitest-signed-out` mode we render a
                    // placeholder.
                    if SyncInbox.uitestSignedOutMode {
                        Text("Sign in with Apple (disabled in UI tests)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 320)
                            .frame(height: 56)
                            .accessibilityIdentifier("apple-signin-stub")
                    } else {
                        // SignInWithAppleButton's Apple logo + label
                        // are sized internally by the system as a
                        // fixed ratio of the button's height — we
                        // can't tune them independently. A taller
                        // button gives a more prominent logo. 56pt
                        // is the largest height Apple's HIG
                        // examples use; combined with radius 20 it
                        // reads as a primary CTA pill.
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                        } onCompletion: { result in
                            Task {
                                isSigningIn = true
                                await inbox.handleAppleSignInResult(result)
                                isSigningIn = false
                            }
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(maxWidth: 320)
                        .frame(height: 56)
                        .cornerRadius(20)
                        .disabled(isSigningIn)
                        .accessibilityIdentifier("apple-signin-button")
                    }
                    if isSigningIn {
                        ProgressView().controlSize(.small)
                    }

                    HStack(spacing: 16) {
                        Link("Privacy", destination: URL(string: "https://steer-legal.pages.dev/privacy/")!)
                        Text("·").foregroundStyle(SteerColors.tertiaryInk)
                        Link("Terms", destination: URL(string: "https://steer-legal.pages.dev/terms/")!)
                        Text("·").foregroundStyle(SteerColors.tertiaryInk)
                        Link("Support", destination: URL(string: "mailto:superwedge.labs@gmail.com?subject=Steer%20Feedback")!)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .padding(.top, 4)
                }
                .padding(.bottom, 36)
            }
            .padding(.horizontal, 24)
        }
    }

}
