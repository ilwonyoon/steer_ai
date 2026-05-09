-- Steer relay V1 schema. Mirrors the shape SteerCore expects on the
-- Swift side so a card published from Mac decodes 1:1 on iPhone.

CREATE TABLE IF NOT EXISTS users (
  user_id TEXT PRIMARY KEY,        -- Apple identity-token `sub` claim
  apple_email TEXT,                -- may be Apple's relay address
  display_name TEXT,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS cards (
  card_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(user_id),
  session_id TEXT NOT NULL,
  category TEXT NOT NULL,
  priority TEXT NOT NULL,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  action_prompt TEXT,
  -- Opaque payload: terminal_lines, options, source_fingerprint,
  -- whatever else the Mac side wants to ferry. JSON string so we can
  -- evolve the shape without a migration every time.
  payload_json TEXT NOT NULL DEFAULT '{}',
  state TEXT NOT NULL DEFAULT 'active',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cards_user_state
  ON cards(user_id, state, updated_at);

CREATE TABLE IF NOT EXISTS instructions (
  instruction_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(user_id),
  target_session_id TEXT NOT NULL,
  text TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',  -- queued / injected / failed
  created_at INTEGER NOT NULL,
  injected_at INTEGER,
  failure_reason TEXT
);
CREATE INDEX IF NOT EXISTS idx_instructions_user_status
  ON instructions(user_id, status, created_at);

CREATE TABLE IF NOT EXISTS sessions (
  session_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(user_id),
  provider TEXT NOT NULL,
  project_name TEXT,
  branch_label TEXT,
  run_state TEXT NOT NULL,
  last_activity_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_user
  ON sessions(user_id, last_activity_at);
