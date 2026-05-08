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
                            minWidth: 320, idealWidth: 375, maxWidth: 720,
                            minHeight: 600, idealHeight: 812, maxHeight: 1400
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
        .windowResizability(.contentMinSize)
        .defaultSize(width: 375, height: 812)

        Settings {
            SteerSettingsView()
        }
    }
}
