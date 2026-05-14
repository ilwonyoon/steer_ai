-- Phase 4 — make session prune cheap.
--
-- We're about to start running periodic DELETEs against sessions
-- in terminal states (ended/disconnected) older than the prune
-- horizon. Without an index on `run_state`, the predicate full-
-- scans sessions every prune tick. The prune is cheap in absolute
-- terms (dozens of rows in steady state), but indexing the column
-- documents the access pattern and keeps things O(log n) if a
-- power user accumulates thousands of ended sessions between
-- prune ticks.

CREATE INDEX IF NOT EXISTS idx_sessions_run_state_ended
  ON sessions(run_state, ended_at)
  WHERE run_state IN ('ended', 'disconnected');
