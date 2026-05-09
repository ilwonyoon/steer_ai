import Foundation
import SteerCore

/// Translates Mac-local model values into SteerCore's CloudKit-shaped
/// snapshots. Centralised so the rules (what does / does not leave the
/// Mac) live in one file the privacy review can audit.
enum SteerCoreMapping {
    static func card(from card: ActionCard) -> CardSnapshot {
        CardSnapshot(
            cardId: card.id,
            sessionId: card.sessionId,
            category: card.state.rawValue,
            priority: "normal",
            title: card.title,
            summary: card.summary,
            actionPrompt: nil,
            terminalLines: card.terminalLines.map(\.text),
            options: card.chips,
            state: "active",
            createdAt: Date(),
            updatedAt: Date(),
            sourceFingerprint: "\(card.sessionId)/\(card.summary.hashValue)"
        )
    }

    static func session(from card: ActionCard) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: card.sessionId,
            provider: card.provider.rawValue,
            projectName: card.project,
            branchLabel: card.branchLabel,
            runState: card.state.rawValue,
            lastActivityAt: Date(),
            macDeviceId: deviceId(),
            isDeliverable: true
        )
    }

    static func session(from chip: LiveSessionChip) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: chip.sessionId,
            provider: chip.provider.rawValue,
            projectName: chip.project,
            branchLabel: nil,
            runState: chip.runState,
            lastActivityAt: chip.lastActivityAt,
            macDeviceId: deviceId(),
            isDeliverable: true
        )
    }

    private static func deviceId() -> String {
        let key = "ai.steer.mac.cloudkit.deviceId"
        return UserDefaults.standard.string(forKey: key) ?? ""
    }
}
