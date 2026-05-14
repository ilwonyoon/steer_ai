import SwiftUI
import UIKit
import UserNotifications

@main
struct SteerIOSApp: App {
    @UIApplicationDelegateAdaptor(SteerAppDelegate.self) private var appDelegate
    @StateObject private var inbox = { SyncInbox.shared }()

    var body: some Scene {
        WindowGroup {
            RootView(inbox: inbox)
                .task {
                    if !SyncInbox.fixtureModeEnabled {
                        await inbox.refreshMe()
                    }
                }
        }
    }
}

/// Single-screen root. The bottom TabView is gone; Settings lives
/// behind a Liquid-Glass capsule in the inbox header (top-left),
/// matching the Mac shell. The card stack uses the full screen
/// height with no persistent bottom bar.
private struct RootView: View {
    @ObservedObject var inbox: SyncInbox

    var body: some View {
        InboxView(inbox: inbox)
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
    ///
    /// APNS = relay-trusted "new card exists" signal. WebSocket delivery
    /// is best-effort (Cloudflare DO can silently half-close a socket
    /// without the iPhone noticing for up to 60 s, and broadcasts to a
    /// dead socket vanish). When the OS hands us a push for a card the
    /// user can't see yet, fetch the snapshot immediately so the card
    /// shows up regardless of WS health.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Relay sends two flavors of push:
        //   (1) New card available — title/body set, banner shown.
        //   (2) Card resolved — type="resolved" marker, empty
        //       alert. We suppress the banner so the inbox just
        //       silently re-syncs.
        // Both flavors trigger a reload regardless. APNS is the
        // wake-the-iPhone signal; the visual is decided here.
        let info = notification.request.content.userInfo
        if info["type"] as? String == "resolved" {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound, .list])
        }
        Task { @MainActor in
            await SyncInbox.shared.reload()
        }
    }

    /// Tap on a notification (lock screen, banner, or Notification
    /// Center). The relay-side fanout includes cardId/sessionId in the
    /// payload; we hand it to SyncInbox so InboxView can scroll to
    /// that card.
    ///
    /// Same APNS-trust rationale as willPresent: trigger a GET so the
    /// matching card is already in cards[] by the time the inbox
    /// renders. Without this, taps from the lock screen would land on
    /// an inbox whose only path to the new card is the WS upsert that
    /// has already been dropped.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        // Resolved pushes carry no banner, so didReceive will only
        // fire for them if the user pulls down Notification Center
        // and taps a stale entry. In that case there's no card to
        // focus — just reload and let the inbox land on whatever
        // is current.
        if info["type"] as? String == "resolved" {
            Task { @MainActor in
                await SyncInbox.shared.reload()
                completionHandler()
            }
            return
        }
        let cardId = info["cardId"] as? String
        let sessionId = info["sessionId"] as? String
        Task { @MainActor in
            SyncInbox.shared.requestFocus(cardId: cardId, sessionId: sessionId)
            await SyncInbox.shared.reload()
            completionHandler()
        }
    }
}

