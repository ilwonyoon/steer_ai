import SwiftUI

/// Direct port of the Mac Models. ProviderKind, SessionState,
/// TerminalLine etc are identical so the rendered card looks the same.
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
    enum Sender { case agent; case user }
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
    let category: String
    let accentHue: Double
    let branchLabel: String?
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
        category: String = "",
        accentHue: Double = 0,
        branchLabel: String? = nil,
        thread: [ThreadMessage] = []
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
        self.category = category
        self.accentHue = accentHue
        self.branchLabel = branchLabel
        self.thread = thread
    }
}
