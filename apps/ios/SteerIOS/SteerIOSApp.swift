import SwiftUI

@main
struct SteerIOSApp: App {
    @StateObject private var inbox = { SyncInbox.shared }()

    var body: some Scene {
        WindowGroup {
            InboxView(inbox: inbox)
                .task {
                    if !SyncInbox.fixtureModeEnabled {
                        await inbox.refreshMe()
                    }
                }
        }
    }
}
