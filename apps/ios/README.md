# Steer for iOS

iPhone client for Steer's CloudKit-synced action card inbox. The Mac app remains the only writer to local CLI sessions; this app is a read+reply surface.

## Status

Phase A spike. Code lives at `apps/ios/SteerIOS/` as plain Swift files. There is no Xcode project here yet — the recommended way to wire this up is:

1. Open Xcode → File → New → Project → iOS → App.
2. Product Name: `Steer`, Bundle Identifier: `ai.steer.ios`, Team: `LG7667PAS6`.
3. Interface: SwiftUI, Language: Swift, Storage: None, no Tests for now.
4. After save, drag the `Steer for iOS` source files (`SteerIOS/*.swift`) into the project.
5. Add the local SteerCore SwiftPM dependency: File → Add Package Dependencies → Add Local… → `packages/SteerCore`.
6. Capabilities: enable iCloud (CloudKit only). Container: `iCloud.ai.steer.mac`.
7. Build target: iOS 17+.

This intentionally avoids a checked-in `.xcodeproj` until the spike is past Phase A and the project shape is stable. Once we know the rough source layout and asset list we'll generate a project via `xcodegen` like Backtick does.

## What's in the source files

- `SteerIOS/SteerIOSApp.swift` — `@main` entry, a single SwiftUI scene.
- `SteerIOS/InboxView.swift` — list of CardSnapshot rows fetched from CloudKit.
- `SteerIOS/CloudKitInbox.swift` — `@MainActor` ObservableObject that opens the private DB, runs a `CKQuerySubscription`, and decodes records into `[CardSnapshot]`.
- `SteerIOS/CardDetailView.swift` — single card detail with reply box and a status row showing whether the queued instruction was injected on the Mac side.

## What this spike does *not* yet do

- TestFlight provisioning — that comes after Phase A spike returns green.
- Push notifications — `CKQuerySubscription` is wired but APNs registration is deferred to Phase B.
- Demo mode — the App Store requirement; built later in Phase D.
- Offline cache — Core Data layer for the cached snapshot is Phase B.
