import Foundation

/// Pure reconciliation logic for Mac → relay live-session-chip
/// publish path. Sibling to `CardReconciler` (same shape, different
/// payload).
///
/// The bug this exists to fix: SteerRootView's previous
/// `diffChipsForPublish` only deduped on *content change* and a 30s
/// heartbeat. When a session transitioned to `ended` /
/// `disconnected` locally, `loadLiveSessions` stopped returning it
/// (its query filters to `running/waiting/blocked`), and the chip
/// was silently dropped from the local map without any publish.
/// The relay kept the previous "running" snapshot intact until its
/// 90 s `last_activity_at` cutoff. iPhone's chip showed phantom
/// running sessions for that full 90 s window.
///
/// Fix: when a session id leaves the local "live" set, emit an
/// explicit publish with `runState="ended"` so the relay marks the
/// row dead immediately. Relay's `listLiveSessions` (which filters
/// `IN ('running', 'waiting', 'blocked')`) excludes it on the next
/// iPhone poll — chip clears within the iPhone's poll cadence (~5 s).

/// Reconciler input: just enough to compute the diff. We use
/// (sessionId, fingerprint) so the caller can let the reconciler
/// own the heartbeat-staleness logic too.
public struct ChipSnapshot: Equatable {
    public let sessionId: String
    /// Stable content fingerprint (runState | project | provider |
    /// whatever else affects how the chip renders on iPhone). The
    /// reconciler treats unequal fingerprints as "needs republish".
    public let fingerprint: String

    public init(sessionId: String, fingerprint: String) {
        self.sessionId = sessionId
        self.fingerprint = fingerprint
    }
}

public struct ChipReconcileDecision: Equatable {
    /// Chips whose content changed (new or fingerprint mismatch) and
    /// must be PUT to the relay.
    public let publishIds: Set<String>

    /// Chips whose content is unchanged but the last publish was
    /// long enough ago that the relay's 90 s `last_activity_at`
    /// cutoff would drop them. Re-publish to keep alive.
    public let heartbeatIds: Set<String>

    /// Chips that disappeared from the local live set since the
    /// last reconcile. Caller publishes these with
    /// `runState="ended"` (or similar terminal state) so the relay
    /// drops them immediately.
    public let resolveIds: Set<String>

    /// New baseline the caller stores until the next reconcile pass.
    public let nextPublished: [String: ChipPublishMemory]

    public init(
        publishIds: Set<String>,
        heartbeatIds: Set<String>,
        resolveIds: Set<String>,
        nextPublished: [String: ChipPublishMemory]
    ) {
        self.publishIds = publishIds
        self.heartbeatIds = heartbeatIds
        self.resolveIds = resolveIds
        self.nextPublished = nextPublished
    }
}

/// Snapshot of a single chip's last successful publish.
/// Persisted in the caller; the reconciler reads it but doesn't
/// mutate any caller state.
public struct ChipPublishMemory: Equatable {
    public let fingerprint: String
    /// Unix epoch (seconds) of the last publish. Used to detect
    /// when a content-unchanged chip needs a heartbeat republish.
    public let publishedAtEpoch: TimeInterval

    public init(fingerprint: String, publishedAtEpoch: TimeInterval) {
        self.fingerprint = fingerprint
        self.publishedAtEpoch = publishedAtEpoch
    }
}

public enum ChipReconciler {
    /// Heartbeat interval. Relay drops live-session rows whose
    /// `last_activity_at` is older than 90 s, so we republish every
    /// 30 s. 3x safety margin handles the iPhone's 5 s poll
    /// cadence too.
    public static let heartbeatIntervalSeconds: TimeInterval = 30

    /// Compute the diff between the freshly-loaded local live set
    /// and the last-published snapshot.
    ///
    /// Cold-start callers should pre-seed `lastPublished` with the
    /// relay's current live set (via `GET /v1/sync/sessions`). That
    /// makes the first reconcile pass after launch see orphan rows
    /// the relay still believes are running but the local store no
    /// longer reports — those go into `resolveIds` and get
    /// terminal-state publishes.
    public static func reconcile(
        currentLocal: [ChipSnapshot],
        lastPublished: [String: ChipPublishMemory],
        now: TimeInterval
    ) -> ChipReconcileDecision {
        var publishIds = Set<String>()
        var heartbeatIds = Set<String>()
        var nextPublished = lastPublished

        let currentIds = Set(currentLocal.map(\.sessionId))

        for chip in currentLocal {
            let prev = lastPublished[chip.sessionId]
            if prev?.fingerprint != chip.fingerprint {
                publishIds.insert(chip.sessionId)
                nextPublished[chip.sessionId] = ChipPublishMemory(
                    fingerprint: chip.fingerprint,
                    publishedAtEpoch: now
                )
                continue
            }
            // Same content — heartbeat if stale.
            let lastAt = prev?.publishedAtEpoch ?? 0
            if now - lastAt > heartbeatIntervalSeconds {
                heartbeatIds.insert(chip.sessionId)
                nextPublished[chip.sessionId] = ChipPublishMemory(
                    fingerprint: chip.fingerprint,
                    publishedAtEpoch: now
                )
            }
        }

        // Anything in lastPublished that isn't in the local set
        // needs an explicit terminal-state publish so the relay
        // drops it immediately.
        let resolveIds = Set(lastPublished.keys).subtracting(currentIds)
        for id in resolveIds {
            nextPublished.removeValue(forKey: id)
        }

        return ChipReconcileDecision(
            publishIds: publishIds,
            heartbeatIds: heartbeatIds,
            resolveIds: resolveIds,
            nextPublished: nextPublished
        )
    }
}
