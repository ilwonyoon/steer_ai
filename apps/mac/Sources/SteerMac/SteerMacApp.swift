import SwiftUI
import AppKit

@main
struct SteerMacApp: App {
    @NSApplicationDelegateAdaptor(SteerAppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            SteerRootView()
                .frame(width: 375, height: 812)
                .fixedSize()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 375, height: 812)

        Settings {
            SteerSettingsView()
        }
    }
}
