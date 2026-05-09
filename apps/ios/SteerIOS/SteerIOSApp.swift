import SwiftUI

@main
struct SteerIOSApp: App {
    @StateObject private var inbox = CloudKitInbox()

    var body: some Scene {
        WindowGroup {
            InboxView(inbox: inbox)
                .task { await inbox.start() }
        }
    }
}
