import Foundation
import AppKit
import UserNotifications

@MainActor
final class ActionNotificationService {
    static let shared = ActionNotificationService()

    private var didRequestAuthorization = false
    private var isAuthorized = false
    private let delegate = SteerNotificationDelegate()
    private let canUseNotificationCenter: Bool

    private init() {
        canUseNotificationCenter = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.bundleIdentifier != nil

        if canUseNotificationCenter {
            UNUserNotificationCenter.current().delegate = delegate
        }
    }

    func notify(card: ActionCard) async {
        guard canUseNotificationCenter else { return }
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
        guard canUseNotificationCenter else { return false }

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
    card.id
}

private func stableNotificationSuffix(for card: ActionCard) -> String {
    String(abs(notificationFingerprint(for: card).hashValue))
}

private final class SteerNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            for window in NSApplication.shared.windows where window.canBecomeKey {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
