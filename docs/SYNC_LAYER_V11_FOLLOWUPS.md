# Sync Layer — v1.1+ Follow-Ups

Items moved out of `docs/SYNC_LAYER_DESIGN_2026-05-13.md` §9 by the
2026-05-13 open-questions triage. The scorecard
(`docs/SYNC_LAYER_METRICS_SCORECARD_2026-05-13.md` §A.10) classified
these as v1.1+ work — they do not block PR-1 through PR-6, but they
need to be tracked so they don't disappear.

Each section's prose is preserved verbatim from the design doc as of
HEAD `b737db8` / `launch-candidate-2026-05-13`. If a section here
needs to be reopened (e.g. F-7 lands on the roadmap and §9.5 has to
become a real PR), the section is moved back to the design doc's §9
or promoted into a new architecture doc — not edited in place here.

What stays in `docs/SYNC_LAYER_DESIGN_2026-05-13.md` §9 (must be
addressed before launch or during PR-1..PR-6):

- §9.1 iPad multi-window state (PR-6 dogfood).
- §9.2 Apple Sign In re-auth race (covered by existing reconnect tests).
- §9.3 iOS background → foreground APNS deep-link race (golden-set check 7).

---

## 1. v3 event log adoption

(Original §9.4)

`docs/SYNC_ARCHITECTURE_V3.md` describes the relay's eventual
event-log model. This design intentionally does not couple to it.
When v3's `POST /v1/sync/events` is consumer-ready, the iOS reducer
can reduce *over events* directly (each event has a server-assigned
monotonic id, which obsoletes the client-side eventSeq for cross-
device ordering).

Defer: §1.2's `Event` enum is shaped to allow a future migration
to server events without a second reducer rewrite.

## 2. The Mac WS handler's "I should do something with `card.upsert`"

(Original §9.5)

`SyncClient.handleWSText` (L597-610) currently only posts a
NotificationCenter event. With the agent owning the SQLite DB,
Mac doesn't *consume* its own broadcast — the reload loop sees the
change in SQLite. But: if a future feature lets the iPhone
publish a card (audit F-7), the Mac would need a real handler.

Defer: out of scope until F-7 is on the roadmap.

## 3. Wrapper-side instruction acknowledgement

(Original §9.6)

When `steer send` injects an instruction, the agent's `ack` handler
calls `resolveActionCardsForSession` only on `injected` (not
`failed`). The reducer doesn't see acks — iOS only sees
`POST /v1/sync/instructions` HTTP status. A wrapper-side failure
manifests as a card that doesn't resolve; the user is forced into
the 10-min timeout path.

Defer: an iOS-visible "your reply failed at the Mac wrapper" signal
would require the relay to forward `instruction.status` events to
iOS (today they stay server-side). Separate PR.

## 4. Test-clock injection across the whole app

(Original §9.7)

The reducer takes `now: Date` injected. The host (`SyncInbox`,
`SteerRootView`) reads `Date()` at call sites. A full
test-clock abstraction would need a `Clock` protocol threaded
through every layer. Deferred — for now, the reducer is testable
because it's pure; the host's timer wakes are robust against
inaccuracy (30 s tolerance on `.awaitingResponseTimeout` detection).

## 5. Wire-shape evolution: `eventSeq` on the server

(Original §9.8)

§2.B uses a client-only `snapshotStartedAtSeq` to dedupe stale
GETs against fresh user writes. A future server-side event id
(per §9.4 / now §1 of this doc) would obsolete this. Until then,
the client-only solution is sufficient.
