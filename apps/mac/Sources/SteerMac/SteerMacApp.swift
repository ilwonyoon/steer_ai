import SwiftUI
import AppKit

@main
struct SteerMacApp: App {
    @NSApplicationDelegateAdaptor(SteerAppDelegate.self) private var appDelegate
    @State private var hasCompletedOnboarding = OnboardingController.hasCompleted

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
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
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 375, height: 600)

        Settings {
            SteerSettingsView()
        }
    }
}
