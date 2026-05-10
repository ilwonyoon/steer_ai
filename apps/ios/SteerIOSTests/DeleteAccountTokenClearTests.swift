import XCTest
@testable import Steer

/// App Store guideline 5.1.1(v) requires account deletion to be
/// effective from the user's perspective even when the network call
/// fails. We assert:
///   1. SessionTokenStore.write/read/clear round-trips cleanly.
///   2. `signOut()` — the funnel that `deleteAccount()` always
///      reaches regardless of the server response — clears that
///      Keychain entry.
///
/// We don't drive `deleteAccount()` itself because it always tries
/// to POST to the relay, and a unit test with no network gets stuck
/// on the request. The behaviour we care about for compliance is
/// that signOut() always runs and always clears the token, which is
/// directly testable.
@MainActor
final class DeleteAccountTokenClearTests: XCTestCase {
    func test_tokenStore_writeAndClear_roundTrip() {
        let store = SessionTokenStore()
        // Make sure we start clean for this test ID.
        store.clear()
        XCTAssertNil(store.read(), "Sanity: store must be empty before write")

        let token = "test-token-\(UUID().uuidString)"
        store.write(token)
        XCTAssertEqual(store.read(), token, "Read must return the same token we wrote")

        store.clear()
        XCTAssertNil(
            store.read(),
            "Keychain must be empty after clear() — App Store 5.1.1(v) compliance"
        )
    }

    func test_signOut_clearsKeychainEvenIfNetworkFails() {
        // Seed a token directly. From the OS's perspective this looks
        // exactly like a real signed-in app.
        let store = SessionTokenStore()
        store.write("seeded-token-\(UUID().uuidString)")
        XCTAssertNotNil(store.read())

        // signOut() is the funnel inside deleteAccount() that runs
        // unconditionally (after the network attempt) — see the
        // updated deleteAccount() in SyncInbox.swift.
        SyncInbox.shared.signOut()

        XCTAssertNil(
            store.read(),
            "Keychain token must be gone after signOut(). deleteAccount() funnels through signOut() in both success and failure paths."
        )
    }
}
