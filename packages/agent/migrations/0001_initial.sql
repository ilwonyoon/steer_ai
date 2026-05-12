-- 0001_initial: baseline schema for SteerAgent.
--
-- This is the exact schema that was previously inlined as the
-- `schemaSql` constant inside `packages/agent/src/store.js`. The
-- only behavioral change in PR S0 is that schema now flows through
-- the migration runner instead of being applied unconditionally
-- on every startup.
--
-- For existing user databases (anything from before PR S0 ships),
-- the runner backstamps schema_version = 1 without re-running this
-- file — every CREATE here is IF NOT EXISTS, so it would be a no-op
-- anyway, but skipping it explicitly avoids touching the file at all
-- on a 1.8 GB DB.
--
-- All future schema changes (drop messages table in S2, add prune
-- sentinel rows in S3, columns for retention status in S5) get their
-- own numbered file in this directory.

CREATE TABLE IF NOT EXISTS rooms (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  is_default INTEGER NOT NULL DEFAULT 0,
  notification_policy TEXT NOT NULL DEFAULT 'default',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  adapter_kind TEXT,
  command TEXT,
  args_json TEXT NOT NULL DEFAULT '[]',
  cwd TEXT,
  pid INTEGER,
  provider_thread_id TEXT,
  run_state TEXT NOT NULL,
  exit_code INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  ended_at TEXT,
  current_room_id TEXT NOT NULL DEFAULT 'default',
  FOREIGN KEY(current_room_id) REFERENCES rooms(id)
);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL,
  session_id TEXT,
  timestamp TEXT NOT NULL,
  direction TEXT NOT NULL,
  raw_content TEXT NOT NULL,
  display_content TEXT,
  summary TEXT,
  category TEXT,
  priority TEXT NOT NULL DEFAULT 'normal',
  requires_action INTEGER NOT NULL DEFAULT 0,
  needs_input INTEGER NOT NULL DEFAULT 0,
  options_json TEXT,
  suggested_instructions_json TEXT,
  reply_to_message_id TEXT,
  answered_at TEXT,
  source TEXT NOT NULL,
  FOREIGN KEY(room_id) REFERENCES rooms(id),
  FOREIGN KEY(session_id) REFERENCES sessions(id)
);

CREATE TABLE IF NOT EXISTS instructions (
  id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL,
  target_session_id TEXT NOT NULL,
  source_message_id TEXT,
  text TEXT NOT NULL,
  is_quick_reply INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  injected_at TEXT,
  failure_reason TEXT,
  FOREIGN KEY(room_id) REFERENCES rooms(id),
  FOREIGN KEY(target_session_id) REFERENCES sessions(id),
  FOREIGN KEY(source_message_id) REFERENCES messages(id)
);

CREATE TABLE IF NOT EXISTS terminal_excerpts (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  source_message_id TEXT,
  start_offset INTEGER,
  end_offset INTEGER,
  raw_text TEXT NOT NULL,
  display_lines_json TEXT NOT NULL,
  highlighted_line_indexes_json TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY(session_id) REFERENCES sessions(id),
  FOREIGN KEY(source_message_id) REFERENCES messages(id)
);

CREATE TABLE IF NOT EXISTS action_cards (
  id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL,
  source_message_id TEXT,
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
  FOREIGN KEY(source_message_id) REFERENCES messages(id),
  FOREIGN KEY(session_id) REFERENCES sessions(id),
  FOREIGN KEY(terminal_excerpt_id) REFERENCES terminal_excerpts(id)
);

CREATE TABLE IF NOT EXISTS transcript_entries (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  timestamp TEXT NOT NULL,
  stream TEXT NOT NULL,
  chunk TEXT NOT NULL,
  FOREIGN KEY(session_id) REFERENCES sessions(id)
);

CREATE TABLE IF NOT EXISTS metric_events (
  id TEXT PRIMARY KEY,
  session_id TEXT,
  room_id TEXT NOT NULL,
  type TEXT NOT NULL,
  timestamp TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY(session_id) REFERENCES sessions(id),
  FOREIGN KEY(room_id) REFERENCES rooms(id)
);

CREATE INDEX IF NOT EXISTS idx_sessions_state ON sessions(run_state, updated_at);
CREATE INDEX IF NOT EXISTS idx_messages_session_time ON messages(session_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_instructions_session_status ON instructions(target_session_id, status);
CREATE INDEX IF NOT EXISTS idx_transcript_entries_session_time ON transcript_entries(session_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_metric_events_session_time ON metric_events(session_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_action_cards_state_priority ON action_cards(state, priority, updated_at);
