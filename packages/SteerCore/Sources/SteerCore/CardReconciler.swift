import Foundation

/// Pure reconciliation logic for the Mac → relay card publish path.
///
/// SteerRootView previously inlined this as `diffCardsForPublish`.
/// Two failure modes drove the move to a library:
///
///   1. **Cold-start orphans.** The view's previous logic kept
///      `lastPublishedCardIds` as an in-memory `Set<String>` —
///      empty every time the agent + Mac app cold-started.
///      A card published yesterday that today's local SQLite no
///      longer reports would never appear in
///      `lastPublishedCardIds.subtracting(currentIds)`, so the
///      relay's DELETE never fired. iPhone kept showing the
///      orphan card forever.
///
///   2. **No test coverage.** The SwiftUI app target can't be
///      driven from a unit test (entry point crashes during
///      headless launch). Moving the logic into SteerCore gives
///      it deterministic XCTests and lets us prove the
///      cold-start case is fixed without dogfood iteration.
///
/// The reconciler is intentionally stateless: callers pass the
/// current snapshot (local + remote + already-published memory),
/// and the reconciler returns what to PUT and what to DELETE.
/// The state machine lives inside the view, which stores the
/// returned `Decision` as its new "last published" baseline.

public struct ReconcileDecision: Equatable {
    /// Card ids the relay should PUT (or PUT-update). The caller
    /// converts these back to full payloads before sending.
    public let publishIds: Set<String>

    /// Card ids the relay should DELETE. These are ids the relay
    /// currently has marked active (either via our prior publish
    /// snapshot or the cold-start `remoteActiveIds`) that our
    /// local store no longer reports as active.
    public let resolveIds: Set<String>

    /// The updated baseline the caller should keep until the next
    /// reconcile pass. Equivalent to "this is everything that
    /// should be active on the relay right now".
    public let nextPublishedIds: Set<String>

    public init(
        publishIds: Set<String>,
        resolveIds: Set<String>,
        nextPublishedIds: Set<String>
    ) {
        self.publishIds = publishIds
        self.resolveIds = resolveIds
        self.nextPublishedIds = nextPublishedIds
    }
}

public enum CardReconciler {
    /// Compute the diff between the latest local snapshot of
    /// active card ids and what the relay last received from this
    /// process.
    ///
    /// Cold-start callers should pre-seed `lastPublishedIds` with
    /// the relay's current active set (via `GET /v1/sync/cards`).
    /// That makes the first reconcile pass after launch see
    /// "orphan" rows the relay still believes are active but the
    /// local store no longer reports — those go into
    /// `resolveIds` and get DELETE'd.
    ///
    /// `changedIdsSinceLastPublish` carries the subset of
    /// `currentLocalIds` whose payload fingerprint (title,
    /// summary, terminal lines, etc.) differs from the last
    /// publish. Callers maintain that fingerprint set themselves;
    /// the reconciler only sees ids.
    public static func reconcile(
        currentLocalIds: Set<String>,
        lastPublishedIds: Set<String>,
        changedIdsSinceLastPublish: Set<String>
    ) -> ReconcileDecision {
        // PUT: any local id whose content changed since last
        // publish. This includes first-time publishes (no prior
        // fingerprint) and content updates.
        let publishIds = changedIdsSinceLastPublish.intersection(currentLocalIds)

        // DELETE: any id we believed was active server-side but
        // the local store no longer reports. After cold-start
        // seeding this catches every orphan from a previous Mac
        // process lifetime.
        let resolveIds = lastPublishedIds.subtracting(currentLocalIds)

        // New baseline = exactly what local sees as active now.
        // Anything we just deleted leaves the baseline; anything
        // new joins it. The view persists this as its updated
        // `lastPublishedCardIds`.
        let nextPublishedIds = currentLocalIds

        return ReconcileDecision(
            publishIds: publishIds,
            resolveIds: resolveIds,
            nextPublishedIds: nextPublishedIds
        )
    }
}
