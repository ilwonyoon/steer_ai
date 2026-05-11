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
                "branchLabel": AnyCodable(card.branchLabel ?? ""),
                // Mac resolves the project identity hue from git origin
                // (so two worktrees of the same repo share a color).
                // Forward it on the wire so iOS uses the same hue
                // instead of bucketing by category — keeps the two
                // clients visually consistent for the same session.
                "accentHue": AnyCodable(card.accentHue)
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

extension CardPayload {
    /// Hash that excludes `createdAt` / `updatedAt`. The Mac reload
    /// loop stamps both on every tick (~2s) without any real state
    /// change, so a hash that included them would invalidate on
    /// every cycle and trigger spurious relay PUTs. This fingerprint
    /// is what SteerRootView.diffCardsForPublish compares against to
    /// decide whether to send the next PUT.
    var publishFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(cardId)
        hasher.combine(sessionId)
        hasher.combine(category)
        hasher.combine(priority)
        hasher.combine(title)
        hasher.combine(summary)
        hasher.combine(actionPrompt)
        hasher.combine(state)
        // payload is [String: AnyCodable]; AnyCodable is Hashable.
        // Canonicalize key order so dictionary iteration order
        // doesn't change the hash across re-encodes.
        if let payload {
            for key in payload.keys.sorted() {
                hasher.combine(key)
                hasher.combine(payload[key])
            }
        }
        return hasher.finalize()
    }
}
