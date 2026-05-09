import Foundation
import SteerCore

/// Bridges the Mac UI's ActionCard struct to the SyncProtocol shape
/// the relay backend speaks. Keeps the wire format isolated from UI
/// concerns so the iOS reader doesn't need to know about ProviderKind
/// or SessionState enums.
enum SteerCardMapping {
    static func payload(from card: ActionCard) -> CardPayload {
        let now = Date()
        return CardPayload(
            cardId: card.id,
            sessionId: card.sessionId,
            category: card.category,
            priority: "normal",
            title: card.title,
            summary: card.summary,
            actionPrompt: card.reason.isEmpty ? nil : card.reason,
            payload: [
                "terminalLines": AnyCodable(card.terminalLines.map(\.text)),
                "options": AnyCodable(card.chips),
                "project": AnyCodable(card.project),
                "provider": AnyCodable(card.provider.rawValue),
                "branchLabel": AnyCodable(card.branchLabel ?? "")
            ],
            state: cardState(card.state),
            createdAt: timestampMs(now),
            updatedAt: timestampMs(now)
        )
    }

    private static func cardState(_ state: SessionState) -> String {
        switch state {
        case .blocked, .waiting, .running: return "active"
        case .ended, .disconnected: return "done"
        }
    }

    private static func timestampMs(_ date: Date) -> Int64 {
        return Int64(date.timeIntervalSince1970 * 1000.0)
    }
}
