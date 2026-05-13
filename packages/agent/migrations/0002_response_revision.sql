-- Monotonic per-session counter Mac bumps every time the terminal
-- produces a fresh response after a user reply. iPhone uses it as
-- the unambiguous "new response" signal — its SessionEntryStore
-- transitions `.awaitingResponse → .awaitingUser` only when the
-- incoming card carries a revision strictly greater than what was
-- stamped on the reply. Timestamps drift, content hashing is
-- fragile; a monotonic int is neither.
--
-- Bump rule (enforced in refreshActionCard):
--   1. createInstruction stamps awaiting_response_since = now()
--   2. refreshActionCard checks for any trusted transcript entry
--      with rowid timestamp > awaiting_response_since
--   3. If yes: increment last_response_revision, clear
--      awaiting_response_since to NULL
--
-- Default 0 so existing rows survive the migration.

ALTER TABLE sessions ADD COLUMN last_response_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sessions ADD COLUMN awaiting_response_since TEXT;
