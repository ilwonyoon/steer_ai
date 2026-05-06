import SwiftUI

@main
struct SteerMacApp: App {
    var body: some Scene {
        WindowGroup {
            SteerRootView()
                .frame(width: 375, height: 812)
                .fixedSize()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 375, height: 812)
    }
}
