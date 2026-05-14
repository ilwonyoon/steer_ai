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
        guard SteerSettings.shared.shouldNotify(category: card.category) else { return }
        guard await ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        // Title = project name ("Documents/Steer_ai") so the user can
        // see at a glance which repo paged them. Falls back to the
        // classifier headline only when project is empty (legacy
        // ActionCard rows had unknown-project default).
        let projectTitle = card.project.trimmingCharacters(in: .whitespaces)
        content.title = !projectTitle.isEmpty && projectTitle != "unknown-project"
            ? projectTitle
            : card.title
        content.body = card.summary
        content.sound = SteerSettings.shared.soundEnabled ? .default : nil
        content.userInfo = [
            "cardId": card.id,
            "sessionId": card.sessionId
        ]
        if let attachment = providerIconAttachment(for: card) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "steer-card-\(card.id)-\(stableNotificationSuffix(for: card))",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    // UNNotificationAttachment requires the file to live somewhere
    // UserNotificationsUI can read it from after we hand it over. The bundled
    // PNG inside SteerMac_SteerMac.bundle works at load time but the system
    // re-reads attachments on its own daemon, which can't see our bundle
    // contents directly — copying once to NSTemporaryDirectory() makes the
    // file readable by the notification daemon without leaking outside the
    // sandbox. We cache by provider so we don't write on every notification.
    private var iconAttachmentCache: [String: URL] = [:]

    private func providerIconAttachment(for card: ActionCard) -> UNNotificationAttachment? {
        guard let iconName = card.provider.iconName else { return nil }
        let url: URL
        if let cached = iconAttachmentCache[iconName] {
            url = cached
        } else {
            guard let bundled = Bundle.module.url(forResource: iconName, withExtension: "png") else { return nil }
            let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("steer-notification-icons", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(iconName).png")
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: bundled, to: dest)
            }
            iconAttachmentCache[iconName] = dest
            url = dest
        }
        return try? UNNotificationAttachment(
            identifier: "provider-\(iconName)",
            url: url,
            options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
        )
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
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            for window in NSApplication.shared.windows where window.canBecomeKey {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
            if let sessionId {
                SteerAppDelegate.status.pendingFocusSessionId = sessionId
            }
        }
    }
}
