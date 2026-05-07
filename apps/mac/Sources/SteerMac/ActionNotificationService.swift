import Foundation
import UserNotifications

@MainActor
final class ActionNotificationService {
    static let shared = ActionNotificationService()

    private var didRequestAuthorization = false
    private var isAuthorized = false

    private init() {}

    func notify(card: ActionCard) async {
        guard await ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = card.title
        content.body = card.summary
        content.sound = .default
        content.userInfo = [
            "cardId": card.id,
            "sessionId": card.sessionId
        ]

        let request = UNNotificationRequest(
            identifier: "steer-card-\(card.id)-\(stableNotificationSuffix(for: card))",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    private func ensureAuthorization() async -> Bool {
        if didRequestAuthorization {
            return isAuthorized
        }

        didRequestAuthorization = true

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }

        return isAuthorized
    }
}

func notificationFingerprint(for card: ActionCard) -> String {
    "\(card.id)|\(card.summary)"
}

private func stableNotificationSuffix(for card: ActionCard) -> String {
    String(abs(notificationFingerprint(for: card).hashValue))
}
