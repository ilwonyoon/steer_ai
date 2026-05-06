import SwiftUI

enum ProviderKind: String {
    case claude
    case codex
    case gemini

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .gemini: "Gemini CLI"
        }
    }

    var iconName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex-color"
        case .gemini: nil
        }
    }

    var fallbackLetter: String {
        switch self {
        case .claude: "C"
        case .codex: "C"
        case .gemini: "G"
        }
    }
}

enum SessionState: String {
    case waiting
    case blocked
    case running

    var color: Color {
        switch self {
        case .waiting: Color(red: 1.0, green: 0.69, blue: 0.13)
        case .blocked: Color(red: 1.0, green: 0.27, blue: 0.23)
        case .running: Color(red: 0.20, green: 0.78, blue: 0.35)
        }
    }
}

struct ThreadMessage: Identifiable {
    enum Sender {
        case agent
        case user
    }

    let id = UUID()
    let sender: Sender
    let text: String
}

struct ActionCard: Identifiable {
    let id = UUID()
    let project: String
    let provider: ProviderKind
    let state: SessionState
    let age: String
    let title: String
    let summary: String
    let reason: String
    let chips: [String]
    var thread: [ThreadMessage]
}

extension ActionCard {
    static let samples: [ActionCard] = [
        ActionCard(
            project: "brief-app",
            provider: .claude,
            state: .waiting,
            age: "waiting 12m",
            title: "Supabase RLS decision needed",
            summary: "Claude finished the schema pass and is blocked on choosing row isolation. It can continue once you choose user-level or workspace-level policies.",
            reason: "Workspace-level RLS supports future collaboration, but user-level RLS is simpler for the first dogfood build.",
            chips: ["Use user-level", "Use workspace-level", "Explain tradeoffs"],
            thread: [
                ThreadMessage(sender: .agent, text: "I finished the table sketch and found one decision before writing policies."),
                ThreadMessage(sender: .agent, text: "Option A: user-level RLS. It is faster and safer for single-player dogfooding.\n\nOption B: workspace-level RLS. It fits collaboration later but adds membership joins now."),
                ThreadMessage(sender: .user, text: "Keep v1 scoped. Which option reduces launch risk?"),
                ThreadMessage(sender: .agent, text: "User-level RLS reduces launch risk. I need approval before applying migrations.")
            ]
        ),
        ActionCard(
            project: "steer-docs",
            provider: .codex,
            state: .blocked,
            age: "blocked 4m",
            title: "Mac app window model is unresolved",
            summary: "Codex is ready to update the app shell spec, but needs a default window size decision before creating SwiftUI layout constraints.",
            reason: "A mobile-sized Mac window makes iOS porting easier, but the desktop version still needs optional side rails at wider sizes.",
            chips: ["Use 375 x 812", "Allow resize", "Add side rail later"],
            thread: [
                ThreadMessage(sender: .agent, text: "I recommend a focused utility window: 375px wide by 812px tall by default, with a later resizable desktop split view."),
                ThreadMessage(sender: .agent, text: "This keeps the primary card stack portable to iOS while preserving Mac keyboard and menu bar affordances.")
            ]
        ),
        ActionCard(
            project: "happy-research",
            provider: .gemini,
            state: .running,
            age: "running",
            title: "Happy adapter notes are ready",
            summary: "Gemini summarized the provider-control approach and can now turn it into a first adapter spike plan.",
            reason: "No answer is required, but you can send a proactive next instruction while the context is fresh.",
            chips: ["Start Codex adapter", "Start Claude adapter", "Write spike tasks"],
            thread: [
                ThreadMessage(sender: .agent, text: "Happy is not a raw pty wrapper anymore. Claude and Codex use provider-native control paths where available."),
                ThreadMessage(sender: .agent, text: "Recommended next step: pick one provider adapter and prove bidirectional instruction delivery.")
            ]
        )
    ]
}
