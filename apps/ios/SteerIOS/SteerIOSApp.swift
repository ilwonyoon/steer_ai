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
/// Apple's push service, and forward the device token to SyncInbox so
/// the relay can fan out push notifications to this device when a
/// card lands.
final class SteerAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // We don't request authorization here — the InboxView surfaces
        // a "Enable notifications" CTA the user can opt into, and we
        // call requestAuthorization there. But we DO call
        // registerForRemoteNotifications immediately so iOS will hand
        // us the device token if the user already granted permission
        // in a previous session.
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
        Task { @MainActor in
            await SyncInbox.shared.updateAPNSToken(hex)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // No-op: SyncInbox keeps the previous token if any. We don't
        // surface this — Apple sometimes fails registration during
        // captive portal / no network, and a later registerForRemote
        // call recovers.
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
