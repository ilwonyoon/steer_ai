import SwiftUI

/// Three-card scripted intro that runs once on first launch (and
/// again, on demand, from the Inbox's "Preview without Mac" path).
/// Reuses ActionCardView so the visual chrome stays identical to
/// real cards.
///
/// Per-card lifecycle:
///   1. Card mounts. terminalLines stream in one at a time on a
///      fixed cadence (LINE_INTERVAL_MS). ReplyDock is disabled.
///   2. After every body line is on screen, a short pause
///      (PROMPT_DELAY_MS), then the actionPromptLine slides in.
///   3. ReplyDock activates with `allowEmptySend=true` — the user
///      can type the suggested word ("next" / "done") or just
///      hit send.
///   4. Send → fade out the card, advance to the next, repeat.
///      Last card sends → onComplete().
///
/// Tap-anywhere shortcut: tapping inside the card body while
/// streaming jumps straight to the end (all lines visible +
/// prompt + ReplyDock active). Lets impatient users skip without
/// adding a separate Skip button.
struct OnboardingFlowView: View {
    /// Fires when the user finishes the last card (or replays
    /// from a parent that resets the state).
    let onComplete: () -> Void

    private let cards = OnboardingScript.cards

    @State private var currentIndex = 0
    /// Index of the line currently being typed, plus how many of
    /// its characters are visible. Lines before `streamLine` are
    /// fully revealed; lines after are hidden.
    @State private var streamLine = 0
    @State private var streamChar = 0
    @State private var promptVisible = false
    @State private var replyText = ""
    @FocusState private var replyFocused: Bool
    @State private var streamTask: Task<Void, Never>?

    // Tunables. Character-level typing speed. 32 ms / char reads
    // as natural typing without being slow enough to drag. Empty
    // lines (blank rows) get a quick fixed pause rather than zero
    // so the rhythm doesn't snap. 700 ms pause before the prompt
    // is the "okay, your turn" beat.
    private let charIntervalMs: UInt64 = 32
    private let blankLinePauseMs: UInt64 = 120
    private let promptDelayMs: UInt64 = 700

    var body: some View {
        ZStack(alignment: .top) {
            SteerColors.appBackground.ignoresSafeArea()

            content
                .padding(.horizontal, 14)
                .padding(.top, 36)
                .padding(.bottom, 12)
        }
        .onAppear { startStreaming(forIndex: 0) }
        .onDisappear { streamTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if cards.indices.contains(currentIndex) {
            let raw = cards[currentIndex]
            let projected = projectedCard(raw)
            ActionCardView(
                card: projected,
                reply: $replyText,
                onSend: { _ in advance() },
                replyFieldFocused: $replyFocused,
                onBodyTap: { skipToEnd() },
                replyPlaceholder: raw.replyPlaceholder
            )
            // The ReplyDock inside ActionCardView reads its
            // canSend gate from allowEmptySend on the dock itself,
            // not from this caller. We surface that flag by reaching
            // through a wrapping environment value below.
            .environment(\.onboardingAllowEmptySend, promptVisible)
            .id(raw.id)  // forces a fresh subview on advance
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))
            ))
        }
    }

    /// Build a `RenderableOnboardingCard` whose terminalLines are
    /// the current typewriter state: every line before `streamLine`
    /// fully revealed, line `streamLine` truncated to `streamChar`
    /// characters, lines after hidden. Once `promptVisible` flips,
    /// the action-prompt line appends as its own fully-revealed row.
    private func projectedCard(_ raw: OnboardingCard) -> RenderableOnboardingCard {
        var out: [TerminalLine] = []
        for (idx, line) in raw.terminalLines.enumerated() {
            if idx < streamLine {
                out.append(line)
            } else if idx == streamLine {
                // Always emit the in-progress line so its height
                // is reserved (otherwise the card shifts up as
                // each line lands). When `streamChar == 0` we
                // still emit a blank line of the same kind so the
                // SF font picks the same baseline.
                let typed = String(line.text.prefix(streamChar))
                out.append(TerminalLine(typed.isEmpty ? " " : typed, kind: line.kind, id: line.id))
                break
            }
        }
        if promptVisible {
            out.append(TerminalLine(""))
            out.append(raw.actionPromptLine)
        }
        return RenderableOnboardingCard(
            id: raw.id,
            project: raw.project,
            provider: raw.provider,
            terminalLines: out
        )
    }

    private func startStreaming(forIndex idx: Int) {
        streamTask?.cancel()
        streamLine = 0
        streamChar = 0
        promptVisible = false
        guard cards.indices.contains(idx) else { return }
        let lines = cards[idx].terminalLines
        let task = Task { @MainActor in
            for (lineIdx, line) in lines.enumerated() {
                if Task.isCancelled { return }
                streamLine = lineIdx
                streamChar = 0
                if line.text.isEmpty {
                    // Blank line — just a small pause so the
                    // cadence breathes.
                    try? await Task.sleep(nanoseconds: blankLinePauseMs * 1_000_000)
                    continue
                }
                let chars = Array(line.text)
                for c in 0..<chars.count {
                    try? await Task.sleep(nanoseconds: charIntervalMs * 1_000_000)
                    if Task.isCancelled { return }
                    streamChar = c + 1
                }
            }
            // Advance one past the last line so projectedCard
            // doesn't keep emitting the in-progress placeholder.
            streamLine = lines.count
            streamChar = 0
            try? await Task.sleep(nanoseconds: promptDelayMs * 1_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.28)) {
                promptVisible = true
            }
        }
        streamTask = task
    }

    private func skipToEnd() {
        streamTask?.cancel()
        let lines = cards[currentIndex].terminalLines
        withAnimation(.easeOut(duration: 0.18)) {
            streamLine = lines.count
            streamChar = 0
            promptVisible = true
        }
    }

    private func advance() {
        replyText = ""
        replyFocused = false
        let next = currentIndex + 1
        if next >= cards.count {
            onComplete()
            return
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            currentIndex = next
        }
        startStreaming(forIndex: next)
    }
}

/// Concrete CardDisplayable instance the view layer renders. We
/// re-project on every state change instead of mutating the source
/// `OnboardingCard` because OnboardingScript.cards is a `let`
/// constant and we want the source data immutable.
private struct RenderableOnboardingCard: CardDisplayable, Identifiable {
    let id: String
    let project: String
    let provider: ProviderKind
    let terminalLines: [TerminalLine]
    // Same defaults OnboardingCard's extension provides.
    var state: SessionState { .waiting }
    var age: String { "" }
    var branchLabel: String? { nil }
    var accentHue: Double { 28 }
}

/// Environment hook so ActionCardView's nested ReplyDock can pick
/// up the "allow empty send" override without us threading a
/// boolean through every initializer. Only the onboarding flow
/// sets this; real cards see the default (false).
struct OnboardingAllowEmptySendKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var onboardingAllowEmptySend: Bool {
        get { self[OnboardingAllowEmptySendKey.self] }
        set { self[OnboardingAllowEmptySendKey.self] = newValue }
    }
}
