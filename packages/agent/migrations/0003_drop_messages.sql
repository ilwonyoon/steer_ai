-- SQLite's official table-recreation procedure requires FK checks
-- off while we move rows between intermediate tables and rename
-- them into place. SQLite re-enables them automatically at the
-- end of the script if they were ON before. Without this the
-- migration fails partway with "FOREIGN KEY constraint failed"
-- because the deferred checks fire on the intermediate state.
PRAGMA foreign_keys = OFF;

-- S2 — drop the unused `messages` table.
--
-- `messages` was the original "everything the assistant ever said"
-- log: appendTranscript inserted one row per output chunk. Nothing
-- in production reads it — the classifier reads transcript_entries,
-- the Mac UI reads action_cards + sessions, the iPhone reads cards
-- via the relay. The table was the single largest contributor to
-- the 1.8GB DB users hit in dogfood (≈99% of total rows).
--
-- Three sibling tables (`terminal_excerpts`, `action_cards`,
-- `instructions`) hold a `source_message_id TEXT REFERENCES
-- messages(id)` that's been written but never read. SQLite's
-- ALTER TABLE DROP COLUMN can't drop a column that participates
-- in a foreign key, so each table is recreated with the FK gone.
-- The recreate pattern preserves data + indexes + the column
-- order CodingKeys depend on.
--
-- Order matters: drop FK-bearing columns first, THEN drop the
-- parent table. Reverse order would trip the FK pragma.

-- terminal_excerpts: recreate without source_message_id.
CREATE TABLE terminal_excerpts__new (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  start_offset INTEGER,
  end_offset INTEGER,
  raw_text TEXT NOT NULL,
  display_lines_json TEXT NOT NULL,
  highlighted_line_indexes_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY(session_id) REFERENCES sessions(id)
);
INSERT INTO terminal_excerpts__new (
  id, session_id, start_offset, end_offset,
  raw_text, display_lines_json, highlighted_line_indexes_json, created_at
)
SELECT
  id, session_id, start_offset, end_offset,
  raw_text, display_lines_json, highlighted_line_indexes_json, created_at
FROM terminal_excerpts;
DROP TABLE terminal_excerpts;
ALTER TABLE terminal_excerpts__new RENAME TO terminal_excerpts;

-- action_cards: recreate without source_message_id.
CREATE TABLE action_cards__new (
  id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  terminal_excerpt_id TEXT,
  category TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'normal',
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  action_prompt TEXT,
  options_json TEXT,
  state TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  snoozed_until TEXT,
  FOREIGN KEY(room_id) REFERENCES rooms(id),
  FOREIGN KEY(session_id) REFERENCES sessions(id),
  FOREIGN KEY(terminal_excerpt_id) REFERENCES terminal_excerpts(id)
);
INSERT INTO action_cards__new (
  id, room_id, session_id, terminal_excerpt_id,
  category, priority, title, summary, action_prompt, options_json,
  state, created_at, updated_at, snoozed_until
)
SELECT
  id, room_id, session_id, terminal_excerpt_id,
  category, priority, title, summary, action_prompt, options_json,
  state, created_at, updated_at, snoozed_until
FROM action_cards;
DROP TABLE action_cards;
ALTER TABLE action_cards__new RENAME TO action_cards;

-- instructions: recreate without source_message_id.
CREATE TABLE instructions__new (
  id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL,
  target_session_id TEXT NOT NULL,
  text TEXT NOT NULL,
  is_quick_reply INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  injected_at TEXT,
  failure_reason TEXT,
  FOREIGN KEY(room_id) REFERENCES rooms(id),
  FOREIGN KEY(target_session_id) REFERENCES sessions(id)
);
INSERT INTO instructions__new (
  id, room_id, target_session_id, text,
  is_quick_reply, status, created_at, injected_at, failure_reason
)
SELECT
  id, room_id, target_session_id, text,
  is_quick_reply, status, created_at, injected_at, failure_reason
FROM instructions;
DROP TABLE instructions;
ALTER TABLE instructions__new RENAME TO instructions;

-- Now safe to drop the parent table.
DROP TABLE messages;

-- Re-enable. createStore sets this on every connection too, but
-- being explicit here documents the contract.
PRAGMA foreign_keys = ON;
