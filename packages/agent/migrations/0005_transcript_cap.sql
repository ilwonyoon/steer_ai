-- Phase 2 — transcript_entries is a capped working buffer, not a log.
--
-- The classifier never reads more than `LIMIT 24` trusted + `LIMIT 8`
-- user + `LIMIT 24` pty rows per session. Anything older is dead
-- weight: nothing in production reads it, ever. Plus, once a
-- session ends/disconnects, its entire transcript becomes
-- irrelevant — the card is the final state.
--
-- This migration enforces both invariants at the database layer:
--
--   1. Per-session cap of 100 rows (classifier max ~56, 2x margin
--      to be safe against bursts). An AFTER INSERT trigger deletes
--      the oldest rows for the session if it exceeds the cap.
--
--   2. When a session transitions to run_state in ('ended',
--      'disconnected'), every transcript row for that session is
--      deleted. The card has already been resolved or marked
--      disconnected; nobody needs the transcript anymore.
--
-- Plus a one-time cleanup at the end: drop transcripts for
-- already-ended sessions, then trim active sessions to the cap.
-- This is where the 1.8GB dogfood DB actually loses weight.

-- Index that makes the cap trigger's "find oldest N rows" cheap.
-- session_id is the partition key; rowid is implicitly the
-- ordering inside each session (oldest = smallest rowid).
-- Adding rowid to the index expression is rejected by SQLite
-- (rowid isn't a normal column), so we just index session_id —
-- the row-id-based ORDER BY in the trigger uses the table's
-- internal rowid order within the session_id bucket.
CREATE INDEX IF NOT EXISTS idx_transcript_session
  ON transcript_entries(session_id);

-- (1) per-session cap on INSERT.
CREATE TRIGGER trg_transcript_cap_after_insert
AFTER INSERT ON transcript_entries
BEGIN
  DELETE FROM transcript_entries
  WHERE session_id = NEW.session_id
    AND rowid IN (
      SELECT rowid FROM transcript_entries
      WHERE session_id = NEW.session_id
      ORDER BY rowid DESC
      LIMIT -1 OFFSET 100
    );
END;

-- (2) session ended → drop its transcript.
CREATE TRIGGER trg_transcript_drop_on_session_end
AFTER UPDATE OF run_state ON sessions
WHEN NEW.run_state IN ('ended', 'disconnected')
  AND OLD.run_state NOT IN ('ended', 'disconnected')
BEGIN
  DELETE FROM transcript_entries WHERE session_id = NEW.id;
END;

-- One-time cleanup. Two passes:
--   (a) Drop transcripts for sessions that are already ended /
--       disconnected. These are the bulk on the live dogfood DB.
--   (b) Trim every remaining session to the per-session cap (some
--       active sessions accumulated tens of thousands of pty rows
--       under the pre-S2 schema).
DELETE FROM transcript_entries
WHERE session_id IN (
  SELECT id FROM sessions WHERE run_state IN ('ended', 'disconnected')
);

DELETE FROM transcript_entries
WHERE rowid IN (
  SELECT r FROM (
    SELECT
      rowid AS r,
      ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY rowid DESC) AS rn
    FROM transcript_entries
  )
  WHERE rn > 100
);
