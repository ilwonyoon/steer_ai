import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { databasePath } from "./paths.js";
import { classifyTranscript } from "./classifier.js";
import { applyMigrations } from "./migrations.js";

const DEFAULT_ROOM_ID = "default";

export function createStore(filePath = databasePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const db = new DatabaseSync(filePath);

  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
    PRAGMA busy_timeout = 5000;
  `);
  // Schema flows through the migration runner now (PR S0). Existing
  // pre-S0 DBs are auto-backstamped to version=1 without re-running
  // 0001_initial — see packages/agent/src/migrations.js. The runner
  // is idempotent; running it on every startup is the intended path.
  applyMigrations(db);

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
    insertInstruction: db.prepare(`
      INSERT INTO instructions (
        id, room_id, target_session_id, text,
        is_quick_reply, status, created_at
      )
      VALUES (?, ?, ?, ?, 0, ?, ?)
    `),
    updateInstructionStatus: db.prepare(`
      UPDATE instructions
      SET status = ?, injected_at = ?, failure_reason = ?
      WHERE id = ?
    `),
    /// Mark a session as awaiting the terminal's response. Called
    /// at instruction-route time so refreshActionCard can detect
    /// "next trusted entry after this is the response."
    markSessionAwaitingResponse: db.prepare(`
      UPDATE sessions
      SET awaiting_response_since = ?
      WHERE id = ?
    `),
    /// Bump revision when refreshActionCard sees a trusted entry
    /// after awaiting_response_since. Atomic: increments AND clears
    /// the marker in one statement so a second concurrent refresh
    /// can't double-bump.
    ///
    /// G15 — source of truth is the session-snapshot column
    /// (last_trusted_at) rather than transcript_entries, so PTY
    /// flood can't suppress the bump by evicting the report row.
    bumpResponseRevisionIfReady: db.prepare(`
      UPDATE sessions
      SET last_response_revision = last_response_revision + 1,
          awaiting_response_since = NULL
      WHERE id = ?
        AND awaiting_response_since IS NOT NULL
        AND last_trusted_at IS NOT NULL
        AND last_trusted_at > awaiting_response_since
    `),
    /// G15 — session snapshot columns updated alongside
    /// transcript_entries inserts. Survives the per-session cap.
    updateSessionUserSnapshot: db.prepare(`
      UPDATE sessions
      SET last_user_text = ?, last_user_at = ?
      WHERE id = ?
    `),
    updateSessionTrustedSnapshot: db.prepare(`
      UPDATE sessions
      SET last_trusted_text = ?, last_trusted_at = ?
      WHERE id = ?
    `),
    selectSessionForRefresh: db.prepare(`
      SELECT id, provider, adapter_kind, command, cwd, run_state,
             last_user_at, last_user_text,
             last_trusted_at, last_trusted_text
      FROM sessions
      WHERE id = ?
    `),
    /// Read the current revision for publishing.
    selectResponseRevision: db.prepare(`
      SELECT last_response_revision FROM sessions WHERE id = ?
    `),
    selectSession: db.prepare(`
      SELECT id, provider, adapter_kind, command, cwd, run_state
      FROM sessions
      WHERE id = ?
    `),
    selectLiveSessions: db.prepare(`
      SELECT id, pid, run_state
      FROM sessions
      WHERE run_state IN ('running', 'waiting', 'blocked')
    `),
    selectRecentTrustedEntries: db.prepare(`
      SELECT stream, chunk, timestamp, rowid AS rid
      FROM transcript_entries
      WHERE session_id = ?
        AND stream IN ('report', 'stdout', 'stderr')
      ORDER BY rowid DESC
      LIMIT 24
    `),
    selectRecentUserEntries: db.prepare(`
      SELECT stream, chunk, timestamp, rowid AS rid
      FROM transcript_entries
      WHERE session_id = ?
        AND stream = 'user'
      ORDER BY rowid DESC
      LIMIT 8
    `),
    selectRecentPtyEntries: db.prepare(`
      SELECT stream, chunk, timestamp, rowid AS rid
      FROM transcript_entries
      WHERE session_id = ?
        AND stream = 'pty'
      ORDER BY rowid DESC
      LIMIT 24
    `),
    upsertTerminalExcerpt: db.prepare(`
      INSERT INTO terminal_excerpts (
        id, session_id, start_offset, end_offset,
        raw_text, display_lines_json, highlighted_line_indexes_json, created_at
      )
      VALUES (?, ?, NULL, NULL, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        raw_text = excluded.raw_text,
        display_lines_json = excluded.display_lines_json,
        highlighted_line_indexes_json = excluded.highlighted_line_indexes_json,
        created_at = excluded.created_at
    `),
    upsertActionCard: db.prepare(`
      INSERT INTO action_cards (
        id, room_id, session_id, terminal_excerpt_id,
        category, priority, title, summary, action_prompt, options_json,
        state, created_at, updated_at, snoozed_until
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
      ON CONFLICT(id) DO UPDATE SET
        terminal_excerpt_id = excluded.terminal_excerpt_id,
        category = excluded.category,
        priority = excluded.priority,
        title = excluded.title,
        summary = excluded.summary,
        action_prompt = excluded.action_prompt,
        options_json = excluded.options_json,
        state = excluded.state,
        updated_at = excluded.updated_at
    `),
    resolveActionCardsForSession: db.prepare(`
      UPDATE action_cards
      SET state = 'done', updated_at = ?
      WHERE session_id = ? AND state = 'active'
    `)
  };

  const now = new Date().toISOString();
  statements.insertDefaultRoom.run(DEFAULT_ROOM_ID, "Unified Queue", "default", now, now);

  const refreshTimers = new Map();
  const REFRESH_DEBOUNCE_MS = 200;

  function scheduleRefresh(sessionId) {
    const existing = refreshTimers.get(sessionId);
    if (existing) clearTimeout(existing);
    const timer = setTimeout(() => {
      refreshTimers.delete(sessionId);
      refreshActionCard(sessionId);
    }, REFRESH_DEBOUNCE_MS);
    timer.unref?.();
    refreshTimers.set(sessionId, timer);
  }

  function flushRefresh(sessionId) {
    const existing = refreshTimers.get(sessionId);
    if (existing) {
      clearTimeout(existing);
      refreshTimers.delete(sessionId);
    }
    refreshActionCard(sessionId);
  }

  return {
    defaultRoomId: DEFAULT_ROOM_ID,
    close() {
      for (const [sessionId, timer] of refreshTimers) {
        clearTimeout(timer);
        refreshActionCard(sessionId);
      }
      refreshTimers.clear();
      db.close();
    },
    listLiveSessions() {
      return statements.selectLiveSessions.all();
    },
    getSession(sessionId) {
      return statements.selectSession.get(sessionId) ?? null;
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
    },
    updateSessionState(sessionId, runState, exitCode = null) {
      const now = new Date().toISOString();
      const endedAt = runState === "ended" ? now : null;
      statements.updateSessionState.run(runState, exitCode, endedAt, now, sessionId);
      flushRefresh(sessionId);
    },
    appendTranscript({ sessionId, stream, chunk }) {
      // S2 — drop pty chunks whose post-ANSI-strip content is
      // whitespace-only. The classifier already filters these on
      // read; persisting them is pure overhead (the bulk of the
      // 1.8GB users hit). Other streams (stdout / stderr / report /
      // user / system) always pass through — they're already filtered
      // or trusted upstream.
      if (stream === "pty" && isWhitespaceOnlyPty(chunk)) {
        return;
      }

      const timestamp = new Date().toISOString();
      statements.insertTranscriptEntry.run(randomUUID(), sessionId, timestamp, stream, chunk);

      // G15 — mirror trusted / user chunks into the session
      // snapshot columns so the classifier never loses them to
      // the per-session transcript cap under PTY repaint flood.
      // PTY and system chunks are not authoritative; they only
      // feed the terminal-excerpt scrub fallback.
      if (stream === "user") {
        statements.updateSessionUserSnapshot.run(chunk, timestamp, sessionId);
      } else if (stream === "report" || stream === "stdout" || stream === "stderr") {
        statements.updateSessionTrustedSnapshot.run(chunk, timestamp, sessionId);
      }

      // S2 — the `messages` table is dropped (migration 0003). The
      // classifier, Mac UI, and iPhone all read from
      // action_cards + transcript_entries + sessions; messages was
      // never consulted.
      if (stream === "report" || stream === "user") {
        flushRefresh(sessionId);
      } else {
        scheduleRefresh(sessionId);
      }
    },
    createInstruction({ id, sessionId, text }) {
      const now = new Date().toISOString();
      statements.insertInstruction.run(
        id,
        DEFAULT_ROOM_ID,
        sessionId,
        text,
        "pending",
        now
      );
      // Stamp the session so the next trusted transcript entry
      // (report/stdout/stderr after `now`) triggers a
      // responseRevision bump in refreshActionCard. This is the
      // signal iPhone uses to atomically transition the chip from
      // `.awaitingResponse` to `.awaitingUser`.
      statements.markSessionAwaitingResponse.run(now, sessionId);
    },
    updateInstructionStatus(id, status, failureReason = null) {
      statements.updateInstructionStatus.run(
        status,
        status === "injected" ? new Date().toISOString() : null,
        failureReason,
        id
      );
    },
    resolveActionCardsForSession(sessionId) {
      statements.resolveActionCardsForSession.run(new Date().toISOString(), sessionId);
    },
    resolveStaleDisconnectedCards() {
      const now = new Date().toISOString();
      const stmt = db.prepare(`
        UPDATE action_cards
        SET state = 'done', updated_at = ?
        WHERE state = 'active'
          AND session_id IN (SELECT id FROM sessions WHERE run_state = 'disconnected')
      `);
      return stmt.run(now).changes ?? 0;
    },
    /// Drop sessions in terminal states whose final state timestamp
    /// is older than the supplied horizons. ended → 1h horizon
    /// (most users want recent transcripts around for a short
    /// debug window). disconnected → 24h horizon (allows a wake-
    /// from-sleep wrapper to reattach within a day).
    ///
    /// Returns the number of sessions actually pruned. Order
    /// matters: child rows in transcript_entries / terminal_excerpts
    /// / action_cards / instructions must go before the session
    /// row itself, otherwise SQLite's FK enforcement (which we
    /// keep ON for safety) raises constraint failed. The whole
    /// thing runs inside one transaction so a crash mid-prune
    /// can't leave orphan rows.
    pruneTerminalSessions({
      endedHorizonMs = 60 * 60 * 1000,           // 1 h
      disconnectedHorizonMs = 24 * 60 * 60 * 1000, // 24 h
    } = {}) {
      const nowMs = Date.now();
      const endedBefore = new Date(nowMs - endedHorizonMs).toISOString();
      const disconnectedBefore = new Date(nowMs - disconnectedHorizonMs).toISOString();

      const pickup = db.prepare(`
        SELECT id FROM sessions
        WHERE (run_state = 'ended' AND COALESCE(ended_at, updated_at) < ?)
           OR (run_state = 'disconnected' AND updated_at < ?)
      `);
      const ids = pickup.all(endedBefore, disconnectedBefore).map((r) => r.id);
      if (ids.length === 0) return 0;

      const placeholders = ids.map(() => "?").join(",");
      const params = ids;
      // node:sqlite has no `db.transaction(fn)` helper. Manual
      // BEGIN/COMMIT around the cascade gives atomicity — a mid-
      // cascade crash leaves everything intact.
      //
      // FK off during the cascade: even though we delete child
      // rows before parents, the Phase 1 triggers on action_cards
      // can move rows mid-statement and trip deferred FK checks.
      // Turning FK off for the transaction body is the standard
      // SQLite pattern; re-enabling at the end (createStore set
      // it ON at connect time) keeps every subsequent statement
      // back under enforcement.
      db.exec("PRAGMA foreign_keys = OFF; BEGIN;");
      try {
        db.prepare(
          `DELETE FROM transcript_entries WHERE session_id IN (${placeholders})`
        ).run(...params);
        db.prepare(
          `DELETE FROM terminal_excerpts WHERE session_id IN (${placeholders})`
        ).run(...params);
        db.prepare(
          `DELETE FROM action_cards WHERE session_id IN (${placeholders})`
        ).run(...params);
        db.prepare(
          `DELETE FROM instructions WHERE target_session_id IN (${placeholders})`
        ).run(...params);
        db.prepare(
          `DELETE FROM sessions WHERE id IN (${placeholders})`
        ).run(...params);
        db.exec("COMMIT; PRAGMA foreign_keys = ON;");
      } catch (e) {
        db.exec("ROLLBACK; PRAGMA foreign_keys = ON;");
        throw e;
      }
      return ids.length;
    },
    recordHookEvent(event) {
      const assistantMessage = normalizeHookText(event.lastAssistantMessage);
      if (assistantMessage) {
        this.appendTranscript({
          sessionId: event.sessionId,
          stream: "report",
          chunk: `${assistantMessage}\n`
        });
      }

      const hookMessage = normalizeHookText(event.message);
      if (hookMessage) {
        this.appendTranscript({
          sessionId: event.sessionId,
          stream: "system",
          chunk: `[${event.provider ?? "provider"} ${event.eventName}] ${hookMessage}\n`
        });
      }
    }
  };

  function refreshActionCard(sessionId) {
    // Bump responseRevision FIRST (before upsertActionCard) so the
    // card row carries the post-bump revision in the same write
    // transaction. iPhone sees one consistent upsert with the new
    // revision and atomically swaps stage.
    statements.bumpResponseRevisionIfReady.run(sessionId);

    const session = statements.selectSessionForRefresh.get(sessionId);
    if (!session) return;

    // G15 — the classifier's source of truth for "what was the
    // last user line, what was the last trusted output" is the
    // session-snapshot columns, not transcript_entries. The
    // 100-row cap evicts those rows under PTY flood; the snapshot
    // survives. We forge synthetic entries from the snapshot
    // columns so the classifier keeps its current interface.
    const synthetic = [];
    if (session.last_user_at && session.last_user_text) {
      synthetic.push({
        stream: "user",
        chunk: session.last_user_text,
        timestamp: session.last_user_at,
        rid: 0,
      });
    }
    if (session.last_trusted_at && session.last_trusted_text) {
      synthetic.push({
        stream: "report",
        chunk: session.last_trusted_text,
        timestamp: session.last_trusted_at,
        // rid ordering must reflect real arrival. A user line at
        // T1 followed by a trusted reply at T2 means rid_user <
        // rid_trusted. We compare timestamps to assign ordering.
        rid: session.last_user_at && session.last_user_at >= session.last_trusted_at ? -1 : 1,
      });
    }

    // PTY screen scrub is still allowed as a tertiary fallback —
    // mirrors pre-G15 behavior when no user/trusted is present.
    const pty = synthetic.length === 0
      ? statements.selectRecentPtyEntries.all(sessionId)
      : [];

    const entries = [...synthetic, ...pty].sort((a, b) => a.rid - b.rid);
    const { rawText, displayLines, card } = classifyTranscript({ session, entries });
    const now = new Date().toISOString();
    const excerptId = `excerpt-${sessionId}`;

    statements.upsertTerminalExcerpt.run(
      excerptId,
      sessionId,
      rawText,
      JSON.stringify(displayLines),
      JSON.stringify(card.highlightedLineIndexes),
      now
    );
    statements.upsertActionCard.run(
      `card-${sessionId}`,
      DEFAULT_ROOM_ID,
      sessionId,
      excerptId,
      card.category,
      card.priority,
      card.title,
      card.summary,
      card.actionPrompt,
      JSON.stringify(card.options),
      card.state,
      now,
      now
    );
  }
}

/// True if a pty chunk is just terminal repaint / cursor moves /
/// status-line whitespace once ANSI control sequences are stripped.
/// Those chunks are 95%+ of all pty traffic by row count and never
/// affect classifier output, so we drop them at write time.
///
/// The strip pattern covers:
///   - CSI escape sequences (cursor moves, color codes, mode sets)
///   - OSC sequences (terminal title updates, hyperlinks)
///   - SS3 single-shift sequences
///   - C1 control characters
///
/// After strip, if the chunk has any non-whitespace character we
/// keep it; otherwise we drop. Exported for unit-test access.
export function isWhitespaceOnlyPty(chunk) {
  if (typeof chunk !== "string" || chunk.length === 0) return true;
  // eslint-disable-next-line no-control-regex
  const stripped = chunk
    // CSI: ESC [ params? intermediate? final
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    // OSC: ESC ] ... (BEL | ESC \)
    .replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, "")
    // SS3 single-shift
    .replace(/\x1bO./g, "")
    // C1 control characters (incl. lone ESC, BEL, etc.)
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "");
  return stripped.trim().length === 0;
}

function normalizeHookText(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

// Schema lives in packages/agent/migrations/*.sql (PR S0). The
// `schemaSql` constant that used to be here was inlined as a single
// db.exec on every startup, which silently skipped any new column or
// ALTER on existing user DBs (CREATE TABLE IF NOT EXISTS is a no-op
// once the table exists). The numbered-migration runner handles all
// of that now — see src/migrations.js.
