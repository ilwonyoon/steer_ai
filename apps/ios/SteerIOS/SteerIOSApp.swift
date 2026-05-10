import SwiftUI

@main
struct SteerIOSApp: App {
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

/// Bottom tab nav. iOS 26+ renders the bar with the system Liquid
/// Glass material automatically, and child scrollables (the inbox
/// card-stack content) auto-inset for the bar — no manual padding.
private struct RootTabView: View {
    @ObservedObject var inbox: SyncInbox

    var body: some View {
        TabView {
            InboxView(inbox: inbox)
                .tabItem {
                    Image(systemName: "rectangle.stack.fill")
                }
            SettingsView(inbox: inbox)
                .tabItem {
                    Image(systemName: "gearshape")
                }
        }
    }
}
