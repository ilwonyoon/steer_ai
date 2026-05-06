import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { databasePath } from "./paths.js";

const DEFAULT_ROOM_ID = "default";

export function createStore(filePath = databasePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const db = new DatabaseSync(filePath);

  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
    PRAGMA busy_timeout = 5000;
  `);
  db.exec(schemaSql);

  const statements = {
    insertDefaultRoom: db.prepare(`
      INSERT OR IGNORE INTO rooms (id, name, is_default, notification_policy, created_at, updated_at)
      VALUES (?, ?, 1, ?, ?, ?)
    `),
    upsertSession: db.prepare(`
      INSERT INTO sessions (
        id, provider, adapter_kind, command, args_json, cwd, pid, provider_thread_id,
        run_state, created_at, updated_at, current_room_id
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        provider = excluded.provider,
        adapter_kind = excluded.adapter_kind,
        command = excluded.command,
        args_json = excluded.args_json,
        cwd = excluded.cwd,
        pid = excluded.pid,
        provider_thread_id = excluded.provider_thread_id,
        run_state = excluded.run_state,
        updated_at = excluded.updated_at,
        current_room_id = excluded.current_room_id
    `),
    updateSessionState: db.prepare(`
      UPDATE sessions
      SET run_state = ?, exit_code = ?, ended_at = ?, updated_at = ?
      WHERE id = ?
    `),
    insertTranscriptEntry: db.prepare(`
      INSERT INTO transcript_entries (id, session_id, timestamp, stream, chunk)
      VALUES (?, ?, ?, ?, ?)
    `),
    insertMessage: db.prepare(`
      INSERT INTO messages (
        id, room_id, session_id, timestamp, direction, raw_content,
        display_content, priority, requires_action, needs_input, source
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?)
    `),
    insertInstruction: db.prepare(`
      INSERT INTO instructions (
        id, room_id, target_session_id, source_message_id, text,
        is_quick_reply, status, created_at
      )
      VALUES (?, ?, ?, NULL, ?, 0, ?, ?)
    `),
    updateInstructionStatus: db.prepare(`
      UPDATE instructions
      SET status = ?, injected_at = ?, failure_reason = ?
      WHERE id = ?
    `),
    insertMetricEvent: db.prepare(`
      INSERT INTO metric_events (id, session_id, room_id, type, timestamp, metadata_json)
      VALUES (?, ?, ?, ?, ?, ?)
    `)
  };

  const now = new Date().toISOString();
  statements.insertDefaultRoom.run(DEFAULT_ROOM_ID, "Unified Queue", "default", now, now);

  const recordMetric = ({ sessionId, type, metadata = {} }) => {
    statements.insertMetricEvent.run(
      randomUUID(),
      sessionId ?? null,
      DEFAULT_ROOM_ID,
      type,
      new Date().toISOString(),
      JSON.stringify(metadata)
    );
  };

  return {
    defaultRoomId: DEFAULT_ROOM_ID,
    close() {
      db.close();
    },
    upsertSession(session) {
      statements.upsertSession.run(
        session.id,
        session.provider,
        session.adapterKind,
        session.command,
        JSON.stringify(session.args ?? []),
        session.cwd,
        session.pid ?? null,
        session.providerThreadId ?? null,
        session.runState,
        session.createdAt,
        session.updatedAt,
        session.currentRoomId ?? DEFAULT_ROOM_ID
      );
      recordMetric({
        sessionId: session.id,
        type: "session_registered",
        metadata: { provider: session.provider, adapterKind: session.adapterKind }
      });
    },
    updateSessionState(sessionId, runState, exitCode = null) {
      const now = new Date().toISOString();
      const endedAt = runState === "ended" ? now : null;
      statements.updateSessionState.run(runState, exitCode, endedAt, now, sessionId);
      recordMetric({
        sessionId,
        type: "state_changed",
        metadata: { runState, exitCode }
      });
    },
    appendTranscript({ sessionId, stream, chunk }) {
      const timestamp = new Date().toISOString();
      statements.insertTranscriptEntry.run(randomUUID(), sessionId, timestamp, stream, chunk);

      const message = transcriptMessageForStream(stream, chunk);
      if (!message) return;

      statements.insertMessage.run(
        randomUUID(),
        DEFAULT_ROOM_ID,
        sessionId,
        timestamp,
        message.direction,
        chunk,
        chunk,
        "normal",
        message.source
      );
    },
    createInstruction({ id, sessionId, text }) {
      statements.insertInstruction.run(
        id,
        DEFAULT_ROOM_ID,
        sessionId,
        text,
        "pending",
        new Date().toISOString()
      );
      recordMetric({
        sessionId,
        type: "instruction_sent",
        metadata: { instructionId: id }
      });
    },
    updateInstructionStatus(id, status, failureReason = null) {
      statements.updateInstructionStatus.run(
        status,
        status === "injected" ? new Date().toISOString() : null,
        failureReason,
        id
      );
      recordMetric({
        sessionId: null,
        type: "instruction_status_changed",
        metadata: { instructionId: id, status, failureReason }
      });
    }
  };
}

function transcriptMessageForStream(stream, chunk) {
  if (!chunk?.trim()) return null;
  if (stream === "user") return { direction: "user_to_agent", source: "user" };
  if (stream === "system") return { direction: "system", source: "wrapper" };
  return { direction: "agent_to_user", source: "wrapper" };
}

const schemaSql = `
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
`;
