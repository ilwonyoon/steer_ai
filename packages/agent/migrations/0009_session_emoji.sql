-- Project emoji — Stage 1.
--
-- Stage 1 ships a deterministic emoji derived from the session cwd
-- (see packages/agent/src/project_emoji.js). Card payloads will
-- carry that default so iPhone / Mac both render the same glyph for
-- every session in a given project folder.
--
-- This column reserves the slot for Stage 2's per-session override.
-- Until Stage 2 ships, every row stays NULL and the classifier
-- falls back to the deterministic mapping. Once Stage 2 lands, a
-- non-NULL value wins so the user's pick survives reloads.
--
-- Storing the override on `sessions` (not a new `projects` table)
-- matches the user's call: changing one session's emoji should not
-- propagate to other sessions in the same folder.

ALTER TABLE sessions ADD COLUMN emoji TEXT;
