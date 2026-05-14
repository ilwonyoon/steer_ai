-- G15.relay — wire the responseRevision signal end-to-end.
--
-- Mac wrapper already bumps a monotonic int on each new answer
-- (sessions.last_response_revision) and ships it on every card
-- upsert. iPhone uses it to atomically decide
-- `.awaitingResponse → .awaitingUser` (chip ↔ card transition).
--
-- Until now the relay D1 schema didn't carry the column, so the
-- field was silently stripped on the wire. iPhone always saw
-- `responseRevision = nil` and couldn't promote, leaving the
-- chip pinned at "N running" even after the real answer arrived.
--
-- Default 0 keeps existing rows valid; new upserts overwrite it.

ALTER TABLE cards ADD COLUMN response_revision INTEGER NOT NULL DEFAULT 0;
