import SwiftUI
import UIKit
import UserNotifications

@main
struct SteerIOSApp: App {
    @UIApplicationDelegateAdaptor(SteerAppDelegate.self) private var appDelegate
    @StateObject private var inbox = { SyncInbox.shared }()

    var body: some Scene {
        WindowGroup {
            RootTabView(inbox: inbox)
                .task {
                    if !SyncInbox.fixtureModeEnabled {
                        await inbox.refreshMe()
                    }
                }
        }
    }
}

/// Owns the APNS lifecycle: request authorization, register with
/// Apple's push service, forward the device token to SyncInbox, and
/// route notification taps back into the inbox so the right card
/// surfaces.
final class SteerAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Become the notification delegate so willPresent / didReceive
        // come through us. SwiftUI's @main App also wires this up but
        // only when one of its scenes is alive — using the AppDelegate
        // is more durable across background launches.
        UNUserNotificationCenter.current().delegate = self

        // Register for remote notifications when the user already
        // granted permission in a previous session. The first-launch
        // prompt is driven from SyncInbox.requestNotificationPermissionIfNeeded
        // after sign-in.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
                return
            }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        NSLog("[APNS] registered, token len=\(hex.count)")
        Task { @MainActor in
            await SyncInbox.shared.updateAPNSToken(hex)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Surface the failure to Settings so the user can see why
        // notifications aren't reaching the lock screen.
        NSLog("[APNS] registration FAILED: \(error.localizedDescription)")
        Task { @MainActor in
            SyncInbox.shared.recordAPNSRegistrationError(error.localizedDescription)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground delivery: still show the banner + play the sound,
    /// don't silently drop it. Without this iOS suppresses notifications
    /// while the app is active.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Tap on a notification (lock screen, banner, or Notification
    /// Center). The relay-side fanout includes cardId/sessionId in the
    /// payload; we hand it to SyncInbox so InboxView can scroll to
    /// that card.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let cardId = info["cardId"] as? String
        let sessionId = info["sessionId"] as? String
        Task { @MainActor in
            SyncInbox.shared.requestFocus(cardId: cardId, sessionId: sessionId)
            completionHandler()
        }
    }
}

/// Bottom tab nav. iOS 26+ renders the bar with the system Liquid
/// Glass material automatically, and child scrollables (the inbox
/// card-stack content) auto-inset for the bar — no manual padding.
private struct RootTabView: View {
    @ObservedObject var inbox: SyncInbox

    var body: some View {
        TabView {
            InboxView(inbox: inbox)
                .tabItem {
                    // Image's accessibilityIdentifier ends up on the
                    // tab-bar button — InboxView's own identifier is
                    // owned by its body and isn't what XCUITest needs
                    // to switch tabs.
                    Image(systemName: "rectangle.stack.fill")
                        .accessibilityIdentifier("tab-inbox")
                }
            SettingsView(inbox: inbox)
                .tabItem {
                    Image(systemName: "gearshape")
                        .accessibilityIdentifier("tab-settings")
                }
        }
    }
}
