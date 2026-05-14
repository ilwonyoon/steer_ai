import XCTest
@testable import SteerCore

/// PR-6: 10-min `.awaitingResponse` decay (design doc §5).
///
/// The host (`SyncInbox.checkAwaitingResponseTimeouts`) drives the
/// wall-clock check; this file pins the *reducer* contract:
///
///   - `markUserReplied` stamps `awaitingResponseStampedAt = now`
///   - `markAwaitingResponseTimedOut` transitions
///     `.awaitingResponse → .failed("response timeout")` and clears
///     the stamp
///   - Promotion via `onCardUpsert(responseRevision > stamp)` clears
///     the stamp (the response landed, no decay needed)
///   - The transition is idempotent — calling it twice on the same
///     entry, or on an entry that already promoted to
///     `.awaitingUser`, is a no-op
final class AwaitingResponseTimeoutTests: XCTestCase {

    private func makeCard(
        sessionId: String,
        cardId: String,
        updatedAtMs: Int64 = 0,
        revision: Int? = nil
    ) -> CardPayload {
        CardPayload(
            cardId: cardId,
            sessionId: sessionId,
            category: "question",
            priority: "normal",
            title: "title-\(cardId)",
            summary: "summary",
            actionPrompt: nil,
            payload: nil,
            state: "active",
            createdAt: 0,
            updatedAt: updatedAtMs,
            responseRevision: revision
        )
    }

    // MARK: - markUserReplied stamps awaitingResponseStampedAt

    func test_markUserReplied_stampsNow() {
        let stamp = Date(timeIntervalSinceReferenceDate: 100_000)
        var entries: [SessionEntry] = [
            SessionEntry(
                sessionId: "S1",
                card: makeCard(sessionId: "S1", cardId: "A", revision: 3),
                stage: .awaitingUser
            )
        ]
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i1",
            now: stamp
        )
        XCTAssertEqual(entries[0].stage, .awaitingResponse)
        XCTAssertEqual(entries[0].awaitingResponseStampedAt, stamp)
    }

    func test_markUserReplied_secondReply_restampsClock() {
        // Retry path: the new Send press resets the timeout clock.
        let first = Date(timeIntervalSinceReferenceDate: 100_000)
        let second = Date(timeIntervalSinceReferenceDate: 100_500)
        var entries: [SessionEntry] = [
            SessionEntry(
                sessionId: "S1",
                card: makeCard(sessionId: "S1", cardId: "A", revision: 3),
                stage: .awaitingUser
            )
        ]
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i1",
            now: first
        )
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i2",
            now: second
        )
        XCTAssertEqual(entries[0].awaitingResponseStampedAt, second)
    }

    // MARK: - markAwaitingResponseTimedOut

    func test_timeout_failsEntry_andClearsStamp() {
        let stamp = Date(timeIntervalSinceReferenceDate: 100_000)
        var entries: [SessionEntry] = [
            SessionEntry(
                sessionId: "S1",
                card: makeCard(sessionId: "S1", cardId: "A", revision: 3),
                stage: .awaitingResponse,
                lastReplyText: "go",
                lastInstructionId: "i1",
                awaitingResponseStampedAt: stamp
            )
        ]
        entries = SessionEntryStore.markAwaitingResponseTimedOut(
            previous: entries, sessionId: "S1"
        )
        XCTAssertEqual(entries[0].stage, .failed("response timeout"))
        XCTAssertNil(entries[0].awaitingResponseStampedAt)
    }

    func test_timeout_idempotentOnAlreadyFailed() {
        // The watcher could fire twice if a tick lands while the
        // host is mid-mutation. Idempotency requirement.
        let entries: [SessionEntry] = [
            SessionEntry(
                sessionId: "S1",
                card: makeCard(sessionId: "S1", cardId: "A"),
                stage: .failed("response timeout"),
                lastReplyText: "go",
                lastInstructionId: "i1"
            )
        ]
        let after = SessionEntryStore.markAwaitingResponseTimedOut(
            previous: entries, sessionId: "S1"
        )
        XCTAssertEqual(after[0].stage, .failed("response timeout"))
    }

    func test_timeout_noopOnPromotedEntry() {
        // Race: response card arrived 200 ms before the watcher
        // fired. The entry is already .awaitingUser and must not be
        // pushed back to .failed.
        let entries: [SessionEntry] = [
            SessionEntry(
                sessionId: "S1",
                card: makeCard(sessionId: "S1", cardId: "A", revision: 4),
                stage: .awaitingUser
            )
        ]
        let after = SessionEntryStore.markAwaitingResponseTimedOut(
            previous: entries, sessionId: "S1"
        )
        XCTAssertEqual(after, entries)
    }

    func test_timeout_noopOnMissingSession() {
        // Edge: the watcher fires after the user already signed
        // out (signOut clears `sessions = []`). No crash, no
        // mutation.
        let entries: [SessionEntry] = []
        let after = SessionEntryStore.markAwaitingResponseTimedOut(
            previous: entries, sessionId: "S1"
        )
        XCTAssertEqual(after, entries)
    }

    // MARK: - Promotion clears the stamp

    func test_responseUpsert_clearsStamp_soWatcherFindsNothing() {
        // §2.D: response upsert arrives. Stamp must clear so the
        // next 30 s watcher tick doesn't decay a healthy entry.
        let stamp = Date(timeIntervalSinceReferenceDate: 100_000)
        var entries = SessionEntryStore.onCardUpsert(
            previous: [],
            card: makeCard(sessionId: "S1", cardId: "A", revision: 3)
        )
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i1",
            now: stamp
        )
        XCTAssertEqual(entries[0].awaitingResponseStampedAt, stamp)

        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 2000, revision: 4
            )
        )
        XCTAssertEqual(entries[0].stage, .awaitingUser)
        XCTAssertNil(
            entries[0].awaitingResponseStampedAt,
            "promotion must clear the timeout stamp"
        )
    }

    func test_preResponseReUpsert_keepsStamp() {
        // Mac's 2 s reload tick re-upserts the pre-reply card with
        // same revision. The stamp must survive so the 10-min clock
        // keeps counting from the original Send press, not from
        // the reload tick.
        let stamp = Date(timeIntervalSinceReferenceDate: 100_000)
        var entries = SessionEntryStore.onCardUpsert(
            previous: [],
            card: makeCard(sessionId: "S1", cardId: "A", revision: 3)
        )
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i1",
            now: stamp
        )
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 2000, revision: 3
            )
        )
        XCTAssertEqual(entries[0].stage, .awaitingResponse)
        XCTAssertEqual(
            entries[0].awaitingResponseStampedAt, stamp,
            "pre-reply re-upsert must not reset the timeout clock"
        )
    }
}
