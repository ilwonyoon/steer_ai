import SwiftUI

enum ProviderKind: String {
    case claude
    case codex
    case gemini
    case custom

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .gemini: "Gemini CLI"
        case .custom: "CLI Session"
        }
    }

    var iconName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex-color"
        case .gemini, .custom: nil
        }
    }

    var fallbackLetter: String {
        switch self {
        case .claude: "C"
        case .codex: "C"
        case .gemini: "G"
        case .custom: ">"
        }
    }
}

enum SessionState: String {
    case waiting
    case blocked
    case running
    case ended
    case disconnected

    var color: Color {
        switch self {
        case .waiting: SteerColors.waiting
        case .blocked: SteerColors.blocked
        case .running: SteerColors.running
        case .ended: SteerColors.ended
        case .disconnected: SteerColors.disconnected
        }
    }
}

struct ThreadMessage: Identifiable {
    enum Sender {
        case agent
        case user
    }

    let id: String
    let sender: Sender
    let text: String

    init(id: String = UUID().uuidString, sender: Sender, text: String) {
        self.id = id
        self.sender = sender
        self.text = text
    }
}

enum TerminalLineKind {
    case standard
    case muted
    case accent
    case success
    case warning
}

struct TerminalLine: Identifiable {
    let id: String
    let text: String
    let kind: TerminalLineKind

    init(_ text: String, kind: TerminalLineKind = .standard, id: String = UUID().uuidString) {
        self.id = id
        self.text = text
        self.kind = kind
    }
}

struct ActionCard: Identifiable {
    let id: String
    let sessionId: String
    let project: String
    let provider: ProviderKind
    let state: SessionState
    let age: String
    let title: String
    let summary: String
    let reason: String
    let terminalLines: [TerminalLine]
    let chips: [String]
    let shouldNotify: Bool
    var thread: [ThreadMessage]

    init(
        id: String = UUID().uuidString,
        sessionId: String = "",
        project: String,
        provider: ProviderKind,
        state: SessionState,
        age: String,
        title: String,
        summary: String,
        reason: String,
        terminalLines: [TerminalLine],
        chips: [String],
        shouldNotify: Bool = false,
        thread: [ThreadMessage]
    ) {
        self.id = id
        self.sessionId = sessionId.isEmpty ? id : sessionId
        self.project = project
        self.provider = provider
        self.state = state
        self.age = age
        self.title = title
        self.summary = summary
        self.reason = reason
        self.terminalLines = terminalLines
        self.chips = chips
        self.shouldNotify = shouldNotify
        self.thread = thread
    }
}

extension ActionCard {
    static let samples: [ActionCard] = [
        ActionCard(
            project: "brief-app",
            provider: .claude,
            state: .waiting,
            age: "waiting 12m",
            title: "Supabase RLS decision needed",
            summary: "Claude is waiting for the RLS scope before applying migrations.",
            reason: "Workspace-level RLS supports future collaboration, but user-level RLS is simpler for the first dogfood build.",
            terminalLines: [
                TerminalLine("• Schema pass complete. One policy decision is blocking migration.", kind: .success),
                TerminalLine(""),
                TerminalLine("Decision needed:", kind: .accent),
                TerminalLine("- Option A: user-level RLS", kind: .standard),
                TerminalLine("  simpler first dogfood build, fewer membership joins", kind: .muted),
                TerminalLine("- Option B: workspace-level RLS", kind: .standard),
                TerminalLine("  better future collaboration, more schema surface now", kind: .muted),
                TerminalLine(""),
                TerminalLine("Next:", kind: .accent),
                TerminalLine("Choose one so I can generate policies and run migrations.", kind: .warning)
            ],
            chips: ["Use user-level", "Use workspace-level", "Explain"],
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
            summary: "Codex needs the default Mac window rule before locking SwiftUI constraints.",
            reason: "A mobile-sized Mac window makes iOS porting easier, but the desktop version still needs optional side rails at wider sizes.",
            terminalLines: [
                TerminalLine("• Found conflicting layout assumptions in DESIGN.md and SwiftUI shell.", kind: .warning),
                TerminalLine(""),
                TerminalLine("Blocked on:", kind: .accent),
                TerminalLine("- default fixed utility window", kind: .standard),
                TerminalLine("- resizable desktop-first app shell", kind: .standard),
                TerminalLine(""),
                TerminalLine("Recommended:", kind: .accent),
                TerminalLine("Use 375 x 812 for v1 preview.", kind: .success),
                TerminalLine("Allow side rail only after the base iOS-portable stack works.", kind: .muted)
            ],
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
            summary: "Gemini can turn the Happy research into the first adapter spike.",
            reason: "No answer is required, but you can send a proactive next instruction while the context is fresh.",
            terminalLines: [
                TerminalLine("• Happy wrapper research summarized.", kind: .success),
                TerminalLine(""),
                TerminalLine("Learned:", kind: .accent),
                TerminalLine("- Claude path: Agent SDK / hooks / session scanner", kind: .standard),
                TerminalLine("- Codex path: codex app-server JSON-RPC", kind: .standard),
                TerminalLine("- raw pty should be fallback, not ideology", kind: .muted),
                TerminalLine(""),
                TerminalLine("Next:", kind: .accent),
                TerminalLine("Pick one provider adapter and prove bidirectional delivery.", kind: .success)
            ],
            chips: ["Start Codex adapter", "Start Claude adapter", "Write spike tasks"],
            thread: [
                ThreadMessage(sender: .agent, text: "Happy is not a raw pty wrapper anymore. Claude and Codex use provider-native control paths where available."),
                ThreadMessage(sender: .agent, text: "Recommended next step: pick one provider adapter and prove bidirectional instruction delivery.")
            ]
        )
    ]
}
