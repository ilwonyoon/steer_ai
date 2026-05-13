import Foundation

/// Onboarding cards reuse the visual chrome of `ActionCard` but live
/// in their own data type. They never round-trip through SQLite or
/// the relay; they exist purely to teach the user what the app does
/// before sign-in (and again, on demand, in the Inbox "Preview
/// without Mac" path).
///
/// Visual reuse goes through `CardDisplayable` (next step) so we
/// can render onboarding cards through the same view code that
/// renders real action cards. Lifecycle reuse stops there — there
/// is no instructionId, no sessionId, no card → server publish.
///
/// Streaming behavior: the terminal lines fade in one at a time on
/// a fixed cadence so the card reads like an arriving response, not
/// a static blob. `OnboardingFlowView` (next step) drives the
/// reveal cursor; the data here is the script.
struct OnboardingCard: Identifiable {
    let id: String
    /// Header copy — shows up in SessionHeader's project slot.
    let project: String
    /// Faux provider so the ProviderMark + state dot render in a
    /// recognizable style. We pick `.codex` arbitrarily; the
    /// onboarding context makes it read as Steer-branded rather
    /// than provider-specific.
    let provider: ProviderKind
    /// Card body lines, each rendered through TerminalLineKind so
    /// they pick up the same color treatment as real terminal
    /// excerpts. Mix kinds to emphasize key sentences. These lines
    /// stream in one at a time on a fixed cadence.
    let terminalLines: [TerminalLine]
    /// Last line, appended only after every `terminalLines` row has
    /// finished streaming. It's the explicit prompt that nudges
    /// the user to either type something or just hit send — the
    /// mechanic that teaches the reply flow before they ever see
    /// a real card. Rendered with `.accent` to read like a CTA.
    let actionPromptLine: TerminalLine
    /// Placeholder shown inside the ReplyDock pill once the action
    /// prompt is on screen. Same word the prompt suggests typing,
    /// so the user can either type it manually or send blank.
    let replyPlaceholder: String
}

enum OnboardingScript {
    /// Three cards, ordered. See product spec — the user pushed for
    /// "정석 (3 cards then sign in)" and asked the copy to capture
    /// these beats:
    ///   1. What this app is.
    ///   2. How the conversation actually works.
    ///   3. Mac app is required + where to get it.
    /// Each card ends with a single placeholder the user can either
    /// type into or just send blank to advance.
    static let cards: [OnboardingCard] = [
        OnboardingCard(
            id: "ob-1-intro",
            project: "Steer",
            provider: .codex,
            terminalLines: [
                TerminalLine("Welcome.", kind: .accent),
                TerminalLine(""),
                TerminalLine("Your Mac runs an AI coding agent."),
                TerminalLine("Sometimes it stops mid-task and waits"),
                TerminalLine("for you to decide what's next."),
                TerminalLine(""),
                TerminalLine("Steer brings those moments to your phone,", kind: .standard),
                TerminalLine("so the agent doesn't sit idle.", kind: .standard),
            ],
            actionPromptLine: TerminalLine("Type 'next' or just hit send →", kind: .accent),
            replyPlaceholder: "next"
        ),
        OnboardingCard(
            id: "ob-2-how",
            project: "Steer",
            provider: .codex,
            terminalLines: [
                TerminalLine("Here's the flow:", kind: .accent),
                TerminalLine(""),
                TerminalLine("• The agent stops and asks a question."),
                TerminalLine("• A card lands here with the context."),
                TerminalLine("• You reply — yes, no, or anything else."),
                TerminalLine("• The agent picks up and keeps going.", kind: .success),
                TerminalLine(""),
                TerminalLine("That's the whole loop.", kind: .muted),
            ],
            actionPromptLine: TerminalLine("Type 'next' or just hit send →", kind: .accent),
            replyPlaceholder: "next"
        ),
        OnboardingCard(
            id: "ob-3-mac",
            project: "Steer",
            provider: .codex,
            terminalLines: [
                TerminalLine("One thing first.", kind: .accent),
                TerminalLine(""),
                TerminalLine("Steer needs the Mac companion app."),
                TerminalLine("It wraps the AI agent (Claude Code,"),
                TerminalLine("Codex CLI, …) and ferries cards here."),
                TerminalLine(""),
                TerminalLine("Open this on your Mac:", kind: .accent),
                TerminalLine("steer.app/download", kind: .standard),
                TerminalLine(""),
                TerminalLine("After install, sign in on both sides.", kind: .muted),
            ],
            actionPromptLine: TerminalLine("Type 'done' or just hit send →", kind: .accent),
            replyPlaceholder: "done"
        ),
    ]
}
