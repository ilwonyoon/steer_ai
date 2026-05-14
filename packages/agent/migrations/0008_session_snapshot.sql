-- G15 — session state snapshot.
--
-- The classifier needs four things to decide a card:
--   * the latest user line + timestamp,
--   * the latest trusted output line + timestamp.
--
-- Until now it sourced these from transcript_entries, which the
-- 5/10 per-session 100-row cap evicts under PTY status-bar
-- repaint flood. Result: after ~2 min of idle PTY traffic the
-- classifier sees neither the user line nor the trusted reply
-- and emits a "session just opened" stub card that overwrites
-- the real one.
--
-- This migration adds four columns directly on `sessions`. The
-- store updates them in the same write path as transcript_entries
-- so the snapshot survives any volume of PTY churn. The classifier
-- reads from these columns; transcript_entries remains the
-- PTY screen scrub source only.
--
-- Idempotent — guarded against rerun.

-- (1) timestamp of the latest user-stream chunk seen on this
--     session. ISO-8601 string. Mirrors transcript_entries.timestamp
--     so existing comparison logic ports cleanly.
ALTER TABLE sessions ADD COLUMN last_user_at TEXT;

-- (2) text of the latest user-stream chunk. The classifier only
--     needs presence + content; one-row-per-session is enough,
--     no need for history.
ALTER TABLE sessions ADD COLUMN last_user_text TEXT;

-- (3) timestamp of the latest trusted-stream chunk (report /
--     stdout / stderr). Stop hook / turn-completed / headless
--     report all converge here.
ALTER TABLE sessions ADD COLUMN last_trusted_at TEXT;

-- (4) text of the latest trusted-stream chunk. Same rationale.
ALTER TABLE sessions ADD COLUMN last_trusted_text TEXT;

-- One-time backfill: for any live session that still has user /
-- trusted rows in transcript_entries (some may, depending on PTY
-- traffic at migration time), copy the most recent ones into the
-- snapshot columns so we don't reset state on upgrade.
UPDATE sessions
SET last_user_text = (
  SELECT chunk FROM transcript_entries
  WHERE session_id = sessions.id AND stream = 'user'
  ORDER BY rowid DESC LIMIT 1
),
last_user_at = (
  SELECT timestamp FROM transcript_entries
  WHERE session_id = sessions.id AND stream = 'user'
  ORDER BY rowid DESC LIMIT 1
)
WHERE last_user_text IS NULL;

UPDATE sessions
SET last_trusted_text = (
  SELECT chunk FROM transcript_entries
  WHERE session_id = sessions.id
    AND stream IN ('report', 'stdout', 'stderr')
  ORDER BY rowid DESC LIMIT 1
),
last_trusted_at = (
  SELECT timestamp FROM transcript_entries
  WHERE session_id = sessions.id
    AND stream IN ('report', 'stdout', 'stderr')
  ORDER BY rowid DESC LIMIT 1
)
WHERE last_trusted_text IS NULL;
