import SwiftUI
import AppKit

@main
struct SteerMacApp: App {
    @NSApplicationDelegateAdaptor(SteerAppDelegate.self) private var appDelegate
    @State private var hasCompletedOnboarding = OnboardingController.hasCompleted

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Disable per-window state restoration so a new launch always
        // materializes the WindowGroup, instead of inheriting "all
        // windows were closed last time -> show nothing" state.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if hasCompletedOnboarding {
                    SteerRootView()
                        .frame(
                            minWidth: 375, idealWidth: 375, maxWidth: 375,
                            minHeight: 600, idealHeight: 600, maxHeight: 1800
                        )
                } else {
                    OnboardingView {
                        hasCompletedOnboarding = true
                    }
                    .frame(width: 540, height: 560)
                    .fixedSize()
                }
            }
            .modifier(OpenMainWindowReceiver())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 375, height: 600)

        Settings {
            SteerSettingsView()
        }
    }
}

/// Bridge from AppDelegate (which has no SwiftUI environment) to
/// SwiftUI's OpenWindowAction. We post a notification from AppDelegate;
/// this view modifier listens and calls openWindow(id:), which is the
/// only reliable way to instantiate a SwiftUI WindowGroup from outside
/// SwiftUI. Background launches (Open at Login / `open -g`) otherwise
/// finish with zero windows because AppKit never auto-creates one for
/// a backgrounded process.
struct OpenMainWindowReceiver: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .steerOpenMainWindow)) { _ in
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}

extension Notification.Name {
    static let steerOpenMainWindow = Notification.Name("ai.steer.mac.openMainWindow")
}
