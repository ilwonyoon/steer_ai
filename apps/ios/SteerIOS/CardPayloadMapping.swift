import Foundation
import SteerCore

/// Inverse of Mac SteerCardMapping: pulls the relay's CardPayload back
/// into a UI-ready ActionCard so the Mac-style card view can render it.
enum CardPayloadMapping {
    static func actionCard(from card: CardPayload, now: Date = Date()) -> ActionCard {
        let provider = parseProvider(card.payload?["provider"]?.value)
        let project = stringValue(card.payload?["project"]?.value) ?? "—"
        let branchLabel = stringValue(card.payload?["branchLabel"]?.value)
        let chips = stringArrayValue(card.payload?["options"]?.value) ?? []
        let lines = stringArrayValue(card.payload?["terminalLines"]?.value) ?? []

        return ActionCard(
            id: card.cardId,
            sessionId: card.sessionId,
            project: project,
            provider: provider,
            state: stateForCategory(card.category),
            age: ageString(from: card.updatedAt, now: now),
            title: card.title,
            summary: card.summary,
            reason: card.actionPrompt ?? "",
            terminalLines: lines.map { TerminalLine($0, kind: lineKind(for: $0)) },
            chips: chips,
            category: card.category,
            // Prefer the hue Mac computed from project identity (git
            // origin) so both clients agree on color per repo. Fall
            // back to the category-driven palette for legacy payloads
            // that don't carry an accentHue yet.
            accentHue: doubleValue(card.payload?["accentHue"]?.value) ?? hue(for: card.category),
            branchLabel: (branchLabel?.isEmpty == false) ? branchLabel : nil,
            thread: []
        )
    }

    private static func doubleValue(_ value: AnyCodableValue?) -> Double? {
        switch value {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    private static func parseProvider(_ value: AnyCodableValue?) -> ProviderKind {
        if case .string(let s) = value, let kind = ProviderKind(rawValue: s) { return kind }
        return .custom
    }

    private static func stringValue(_ value: AnyCodableValue?) -> String? {
        if case .string(let s) = value { return s }
        return nil
    }

    private static func stringArrayValue(_ value: AnyCodableValue?) -> [String]? {
        if case .stringArray(let arr) = value { return arr }
        return nil
    }

    private static func stateForCategory(_ category: String) -> SessionState {
        switch category {
        case "blocker": .blocked
        case "waiting": .waiting
        case "completion": .ended
        case "disconnected": .disconnected
        default: .running
        }
    }

    private static func hue(for category: String) -> Double {
        switch category {
        case "blocker": 6
        case "question": 218
        case "decision": 280
        case "waiting": 38
        case "completion": 142
        default: 200
        }
    }

    /// Heuristic mirroring what Mac's classifier-driven view does for
    /// pure relay payloads: emphasize bullet/number lines as accent,
    /// blank lines as standard, comments/notes as muted.
    private static func lineKind(for raw: String) -> TerminalLineKind {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .standard }
        if trimmed.hasPrefix("$ ") { return .accent }
        if trimmed.hasPrefix("•") || trimmed.hasPrefix("✓") { return .success }
        if trimmed.lowercased().contains("error") || trimmed.lowercased().contains("failed") {
            return .warning
        }
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("#") {
            return .muted
        }
        return .standard
    }

    private static func ageString(from updatedAtMs: Int64, now: Date) -> String {
        let updated = Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000.0)
        let secs = max(0, Int(now.timeIntervalSince(updated)))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86_400)d ago"
    }
}
