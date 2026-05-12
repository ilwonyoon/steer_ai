-- 0006_events: append-only event log for sync v3.
--
-- This is the foundation of `docs/SYNC_ARCHITECTURE_V3.md`. Every
-- state change between Mac and iPhone (card upserts, card resolves,
-- session run-state transitions, instruction queueing, instruction
-- injection confirmations, device heartbeats) becomes one row here.
-- Consumers replay rows since their cursor to derive current state.
--
-- PR 1 introduces this table alongside the existing
-- cards/sessions/instructions/devices tables. Both writes happen
-- inside the same D1 batch (atomic). Clients don't read this table
-- yet — PR 1 is dual-write only, observation-only on the read side.
--
-- See docs/SYNC_ARCHITECTURE_V3.md "Event taxonomy" for the
-- type vocabulary and payload shapes.

CREATE TABLE IF NOT EXISTS events (
  -- Monotonically increasing per-row id. Cursor for catch-up.
  -- AUTOINCREMENT is required so deleting a row doesn't let SQLite
  -- recycle its id and break the "everything > cursor is new"
  -- contract.
  id INTEGER PRIMARY KEY AUTOINCREMENT,

  -- Owning user. Always set; all queries are user-scoped.
  user_id TEXT NOT NULL REFERENCES users(user_id),

  -- One of:
  --   session.upsert | session.remove
  --   card.upsert    | card.resolved
  --   instruction.queued | instruction.injected
  --   device.heartbeat
  -- Stored as a free-form string; enum is enforced at the application
  -- layer to keep migrations simple as we add new types.
  type TEXT NOT NULL,

  -- Type-specific payload as JSON. Shape per type documented in the
  -- design doc. Empty object `{}` is legal (e.g. presence ticks).
  payload_json TEXT NOT NULL DEFAULT '{}',

  -- Server-assigned wall-clock at insert. Clients trust this for
  -- ordering display; we don't honor client-supplied timestamps.
  created_at INTEGER NOT NULL,

  -- Which device produced the event. Used for:
  --   1. Idempotency dedupe (combined with client_uuid below).
  --   2. Filtering out a producer's own events on its catch-up
  --      replay so it doesn't apply changes it just published.
  --   3. Audit. Surfaced in admin tools later.
  producer_device_id TEXT NOT NULL,

  -- Client-side UUID for idempotent retry. If the producer POSTs the
  -- same event twice (network drop between request and response,
  -- crash mid-POST, manual retry), the second POST returns the
  -- original id and inserts nothing new.
  --
  -- Nullable for events the relay synthesizes itself (none today,
  -- placeholder for future server-side events like server-driven
  -- card aging).
  client_uuid TEXT
);

-- Catch-up query: events for user U since cursor N, ordered.
-- Covers `GET /v1/sync/events?since=N&limit=500`.
CREATE INDEX IF NOT EXISTS idx_events_user_id ON events(user_id, id);

-- Idempotency dedupe lookup: (producer_device_id, client_uuid)
-- → existing event id. Partial uniqueness via index, since
-- client_uuid is nullable.
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_idempotency
  ON events(producer_device_id, client_uuid)
  WHERE client_uuid IS NOT NULL;
