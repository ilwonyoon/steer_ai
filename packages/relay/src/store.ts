import type {
  CardPayload,
  DeviceSnapshot,
  Env,
  InstructionRecord,
  SessionSnapshot,
  SyncEvent,
  SyncEventInput,
  SyncEventType,
  SyncSnapshot,
} from "./types.js";

/**
 * Caller hint for the dual-write event-log path (v3 PR 1).
 *
 * Existing routes (`PUT /v1/sync/cards/:id`, `POST /v1/sync/sessions`,
 * etc) keep writing their legacy table rows, AND additionally insert
 * a matching event-log row via `appendEvent`. Both writes go through
 * D1's batch API so they're atomic — either both land or neither
 * does. Once PR 4 deletes the legacy routes, only the event write
 * survives.
 *
 * `producerDeviceId` is the X-Steer-Device-Id header value the route
 * handler captured from the request; mandatory because event audits
 * need to know who emitted what.
 *
 * `clientUuid` is the producer-supplied idempotency key. For legacy
 * routes that don't yet send one (every current client), the route
 * handler synthesizes one from the natural unique key
 * (e.g. cardId, instructionId) so retries of the same logical write
 * dedupe correctly.
 */
export interface EventAuditFields {
  producerDeviceId: string;
  clientUuid?: string;
}

/**
 * D1 wrapper. Keeps SQL out of the route handlers.
 */
export class Store {
  constructor(private env: Env) {}

  async upsertUser(
    userId: string,
    email: string | undefined,
    displayName: string | undefined,
    appleAuthCode?: string | undefined
  ) {
    const now = Date.now();
    await this.env.DB.prepare(
      `INSERT INTO users (user_id, apple_email, display_name, apple_auth_code, created_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(user_id) DO UPDATE SET
         apple_email = COALESCE(excluded.apple_email, apple_email),
         display_name = COALESCE(excluded.display_name, display_name),
         apple_auth_code = COALESCE(excluded.apple_auth_code, apple_auth_code),
         last_seen_at = excluded.last_seen_at`
    )
      .bind(userId, email ?? null, displayName ?? null, appleAuthCode ?? null, now, now)
      .run();
  }

  async getAppleAuthCode(userId: string): Promise<string | null> {
    const row = await this.env.DB.prepare(
      `SELECT apple_auth_code FROM users WHERE user_id = ?`
    )
      .bind(userId)
      .first<{ apple_auth_code: string | null }>();
    return row?.apple_auth_code ?? null;
  }

  async deleteUserData(userId: string): Promise<void> {
    await this.env.DB.prepare(`DELETE FROM cards WHERE user_id = ?`).bind(userId).run();
    await this.env.DB.prepare(`DELETE FROM instructions WHERE user_id = ?`).bind(userId).run();
    await this.env.DB.prepare(`DELETE FROM sessions WHERE user_id = ?`).bind(userId).run();
    await this.env.DB.prepare(`DELETE FROM devices WHERE user_id = ?`).bind(userId).run();
    await this.env.DB.prepare(`DELETE FROM users WHERE user_id = ?`).bind(userId).run();
  }

  /// Upsert a card.
  ///
  /// Returns `inserted` (true when this card_id is new for the user)
  /// and `changed` (true when the row is new OR any meaningful column
  /// differs from what we previously stored). Callers gate on
  /// `inserted` for APNS (one push per new card) and on `changed`
  /// for the WebSocket broadcast (no-op upserts must not fan out).
  ///
  /// "Meaningful" here = everything except `updated_at`. Mac
  /// re-publishes on its reload tick, bumping updated_at every time
  /// without touching anything else. If we let that flow through to
  /// the WS broadcast, every iPhone sees a stream of identical
  /// upserts every 2s — which is what made the carousel jitter.
  async upsertCard(
    userId: string,
    card: CardPayload
  ): Promise<{ inserted: boolean; changed: boolean }> {
    const existing = await this.env.DB.prepare(
      `SELECT session_id, category, priority, title, summary,
              action_prompt, payload_json, state
       FROM cards WHERE card_id = ? AND user_id = ? LIMIT 1`
    )
      .bind(card.cardId, userId)
      .first<{
        session_id: string;
        category: string;
        priority: string;
        title: string;
        summary: string;
        action_prompt: string | null;
        payload_json: string;
        state: string;
      }>();
    const inserted = existing == null;
    const incomingPayload = JSON.stringify(card.payload ?? {});
    const changed =
      inserted ||
      existing.session_id !== card.sessionId ||
      existing.category !== card.category ||
      existing.priority !== card.priority ||
      existing.title !== card.title ||
      existing.summary !== card.summary ||
      (existing.action_prompt ?? null) !== (card.actionPrompt ?? null) ||
      existing.payload_json !== incomingPayload ||
      existing.state !== card.state;

    await this.env.DB.prepare(
      `INSERT INTO cards (
         card_id, user_id, session_id, category, priority, title, summary,
         action_prompt, payload_json, state, created_at, updated_at
       )
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(card_id) DO UPDATE SET
         category = excluded.category,
         priority = excluded.priority,
         title = excluded.title,
         summary = excluded.summary,
         action_prompt = excluded.action_prompt,
         payload_json = excluded.payload_json,
         state = excluded.state,
         updated_at = excluded.updated_at`
    )
      .bind(
        card.cardId,
        userId,
        card.sessionId,
        card.category,
        card.priority,
        card.title,
        card.summary,
        card.actionPrompt ?? null,
        incomingPayload,
        card.state,
        card.createdAt,
        card.updatedAt
      )
      .run();
    return { inserted, changed };
  }

  async listActiveCards(userId: string, sinceUpdatedAt = 0): Promise<CardPayload[]> {
    const rs = await this.env.DB.prepare(
      `SELECT card_id, session_id, category, priority, title, summary,
              action_prompt, payload_json, state, created_at, updated_at
       FROM cards
       WHERE user_id = ? AND state = 'active' AND updated_at > ?
       ORDER BY updated_at ASC
       LIMIT 200`
    )
      .bind(userId, sinceUpdatedAt)
      .all();

    return rs.results.map((row) => ({
      cardId: row.card_id as string,
      sessionId: row.session_id as string,
      category: row.category as string,
      priority: row.priority as string,
      title: row.title as string,
      summary: row.summary as string,
      actionPrompt: (row.action_prompt as string) || undefined,
      payload: row.payload_json ? JSON.parse(row.payload_json as string) : {},
      state: row.state as "active" | "done",
      createdAt: row.created_at as number,
      updatedAt: row.updated_at as number,
    }));
  }

  async resolveCard(userId: string, cardId: string): Promise<void> {
    await this.env.DB.prepare(
      `UPDATE cards SET state = 'done', updated_at = ?
       WHERE user_id = ? AND card_id = ?`
    )
      .bind(Date.now(), userId, cardId)
      .run();
  }

  /// Returns true if the given user has at least one card or session
  /// row with this session_id. Used as the ownership check before
  /// accepting an instruction targeted at a session.
  async userOwnsSession(userId: string, sessionId: string): Promise<boolean> {
    const card = await this.env.DB.prepare(
      `SELECT 1 FROM cards WHERE user_id = ? AND session_id = ? LIMIT 1`
    )
      .bind(userId, sessionId)
      .first();
    if (card) return true;
    const session = await this.env.DB.prepare(
      `SELECT 1 FROM sessions WHERE user_id = ? AND session_id = ? LIMIT 1`
    )
      .bind(userId, sessionId)
      .first();
    return session != null;
  }

  async enqueueInstruction(
    userId: string,
    instructionId: string,
    targetSessionId: string,
    text: string
  ): Promise<InstructionRecord> {
    const now = Date.now();
    await this.env.DB.prepare(
      `INSERT INTO instructions (
         instruction_id, user_id, target_session_id, text, status, created_at
       )
       VALUES (?, ?, ?, ?, 'queued', ?)`
    )
      .bind(instructionId, userId, targetSessionId, text, now)
      .run();
    return {
      instructionId,
      targetSessionId,
      text,
      status: "queued",
      createdAt: now,
    };
  }

  async listQueuedInstructions(userId: string): Promise<InstructionRecord[]> {
    const rs = await this.env.DB.prepare(
      `SELECT instruction_id, target_session_id, text, status, created_at,
              injected_at, failure_reason
       FROM instructions
       WHERE user_id = ? AND status = 'queued'
       ORDER BY created_at ASC
       LIMIT 100`
    )
      .bind(userId)
      .all();
    return rs.results.map((row) => ({
      instructionId: row.instruction_id as string,
      targetSessionId: row.target_session_id as string,
      text: row.text as string,
      status: row.status as "queued" | "injected" | "failed",
      createdAt: row.created_at as number,
      injectedAt: (row.injected_at as number) || undefined,
      failureReason: (row.failure_reason as string) || undefined,
    }));
  }

  async markInstructionStatus(
    userId: string,
    instructionId: string,
    status: "injected" | "failed",
    failureReason?: string
  ): Promise<void> {
    if (status === "injected") {
      await this.env.DB.prepare(
        `UPDATE instructions SET status = 'injected', injected_at = ?
         WHERE user_id = ? AND instruction_id = ?`
      )
        .bind(Date.now(), userId, instructionId)
        .run();
    } else {
      await this.env.DB.prepare(
        `UPDATE instructions SET status = 'failed', failure_reason = ?
         WHERE user_id = ? AND instruction_id = ?`
      )
        .bind(failureReason ?? "unknown", userId, instructionId)
        .run();
    }
  }

  async upsertDevice(userId: string, snap: DeviceSnapshot): Promise<void> {
    await this.env.DB.prepare(
      `INSERT INTO devices (
         device_id, user_id, platform, display_name, device_class,
         app_version, sync_enabled, last_seen_at, apns_token,
         aps_environment
       )
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(user_id, device_id) DO UPDATE SET
         platform = excluded.platform,
         display_name = COALESCE(excluded.display_name, display_name),
         device_class = COALESCE(excluded.device_class, device_class),
         app_version = COALESCE(excluded.app_version, app_version),
         sync_enabled = excluded.sync_enabled,
         last_seen_at = excluded.last_seen_at,
         apns_token = COALESCE(excluded.apns_token, apns_token),
         aps_environment = COALESCE(excluded.aps_environment, aps_environment)`
    )
      .bind(
        snap.deviceId,
        userId,
        snap.platform,
        snap.displayName ?? null,
        snap.deviceClass ?? null,
        snap.appVersion ?? null,
        snap.syncEnabled ? 1 : 0,
        snap.lastSeenAt,
        snap.apnsToken ?? null,
        snap.apsEnvironment ?? null
      )
      .run();
  }

  /// Drop a device row by user + apnsToken. Called when APNS returns
  /// 410 Unregistered — Apple's signal that the token is dead (app
  /// uninstalled, restored from backup, etc). Leaving the row in
  /// place means every future fanout still spends a JWT slot on it
  /// (and racks up TooManyProviderTokenUpdates 429s when there are
  /// many dead rows).
  /// Drop a device row by user + deviceId. Called from the iOS
  /// signOut path (DELETE /v1/sync/devices/:deviceId) so the user
  /// stops receiving pushes the moment they sign out.
  async deleteDeviceById(userId: string, deviceId: string): Promise<void> {
    await this.env.DB.prepare(
      `DELETE FROM devices WHERE user_id = ? AND device_id = ?`
    )
      .bind(userId, deviceId)
      .run();
  }

  async deleteDeviceByApnsToken(userId: string, apnsToken: string): Promise<void> {
    await this.env.DB.prepare(
      `DELETE FROM devices WHERE user_id = ? AND apns_token = ?`
    )
      .bind(userId, apnsToken)
      .run();
  }

  /// Drop device rows where the row hasn't been heartbeated in N ms.
  /// Used during fanout to garbage-collect tokens the app stopped
  /// publishing (uninstalled, signed out, app killed for days).
  /// Returns the number of rows removed.
  async pruneStaleDevices(userId: string, maxAgeMs: number): Promise<number> {
    const cutoff = Date.now() - maxAgeMs;
    const r = await this.env.DB.prepare(
      `DELETE FROM devices WHERE user_id = ? AND last_seen_at < ?`
    )
      .bind(userId, cutoff)
      .run();
    return r.meta.changes ?? 0;
  }

  async listDevices(userId: string): Promise<DeviceSnapshot[]> {
    const rs = await this.env.DB.prepare(
      `SELECT device_id, platform, display_name, device_class,
              app_version, sync_enabled, last_seen_at, apns_token,
              aps_environment
       FROM devices
       WHERE user_id = ?
       ORDER BY last_seen_at DESC
       LIMIT 50`
    )
      .bind(userId)
      .all();
    return rs.results.map((row) => ({
      deviceId: row.device_id as string,
      platform: row.platform as string,
      displayName: (row.display_name as string) || undefined,
      deviceClass: (row.device_class as string) || undefined,
      appVersion: (row.app_version as string) || undefined,
      syncEnabled: (row.sync_enabled as number) === 1,
      lastSeenAt: row.last_seen_at as number,
      apnsToken: (row.apns_token as string) || undefined,
      apsEnvironment: (row.aps_environment as string) || undefined,
    }));
  }

  async upsertSession(userId: string, snap: SessionSnapshot): Promise<void> {
    await this.env.DB.prepare(
      `INSERT INTO sessions (
         session_id, user_id, provider, project_name, branch_label,
         run_state, last_activity_at
       )
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(session_id) DO UPDATE SET
         provider = excluded.provider,
         project_name = excluded.project_name,
         branch_label = excluded.branch_label,
         run_state = excluded.run_state,
         last_activity_at = excluded.last_activity_at`
    )
      .bind(
        snap.sessionId,
        userId,
        snap.provider,
        snap.projectName ?? null,
        snap.branchLabel ?? null,
        snap.runState,
        snap.lastActivityAt
      )
      .run();
  }

  /// Live (running/waiting/blocked) sessions the Mac last reported.
  /// iPhone reads this to render the "N running" badge next to the
  /// Mac connection chip. Stale sessions older than 90 seconds are
  /// excluded because the Mac dedupes publishes when nothing has
  /// changed (so an actively running session still re-publishes on
  /// every state change, but a Steer.app quit / process kill /
  /// network drop stops bumping last_activity_at). 90s = 3 missed
  /// 30-second heartbeat windows; matches Mac's reload tick cadence.
  /// Previously 5 minutes, but that left stale "1 running" chips
  /// visible for far too long after a session quietly died.
  async listLiveSessions(userId: string): Promise<SessionSnapshot[]> {
    const minLastActivity = Date.now() - 90 * 1000;
    const rs = await this.env.DB.prepare(
      `SELECT session_id, provider, project_name, branch_label,
              run_state, last_activity_at
       FROM sessions
       WHERE user_id = ?
         AND last_activity_at > ?
         AND run_state IN ('running', 'waiting', 'blocked')
       ORDER BY last_activity_at DESC
       LIMIT 50`
    )
      .bind(userId, minLastActivity)
      .all();
    return rs.results.map((row) => ({
      sessionId: row.session_id as string,
      provider: row.provider as string,
      projectName: (row.project_name as string) || undefined,
      branchLabel: (row.branch_label as string) || undefined,
      runState: row.run_state as string,
      lastActivityAt: row.last_activity_at as number,
    }));
  }

  // ──────────────────────────────────────────────────────────────────
  // Sync v3 event log (PR 1 — dual-write + read endpoints).
  //
  // Append-only, monotonically-indexed. The producer is anyone who
  // calls `appendEvent` (route handlers during dual-write, the
  // forthcoming POST /v1/sync/events endpoint, future server-side
  // emitters). Consumers replay via `eventsSince(cursor)` or
  // `computeSnapshot()`.
  //
  // Idempotency: a unique partial index on
  // (producer_device_id, client_uuid) — see migration 0006 — means
  // a duplicate POST with the same key is a no-op and returns the
  // original id. We detect this by looking up first, before insert,
  // so we can return the existing row without relying on an INSERT
  // OR IGNORE that would silently swallow real conflicts.
  // ──────────────────────────────────────────────────────────────────

  /**
   * Insert one event. If `clientUuid` is provided and a matching row
   * already exists for `(producerDeviceId, clientUuid)`, returns the
   * existing event without inserting a second row.
   */
  async appendEvent(userId: string, input: SyncEventInput): Promise<SyncEvent> {
    if (input.clientUuid) {
      const existing = await this.env.DB.prepare(
        `SELECT id, type, payload_json, created_at, producer_device_id, client_uuid
         FROM events
         WHERE producer_device_id = ? AND client_uuid = ?
         LIMIT 1`
      )
        .bind(input.producerDeviceId, input.clientUuid)
        .first<{
          id: number;
          type: string;
          payload_json: string;
          created_at: number;
          producer_device_id: string;
          client_uuid: string;
        }>();
      if (existing) {
        return {
          id: existing.id,
          type: existing.type as SyncEventType,
          payload: existing.payload_json ? JSON.parse(existing.payload_json) : {},
          createdAt: existing.created_at,
          producerDeviceId: existing.producer_device_id,
          clientUuid: existing.client_uuid,
        };
      }
    }

    const now = Date.now();
    const payloadJson = JSON.stringify(input.payload ?? {});
    const result = await this.env.DB.prepare(
      `INSERT INTO events (user_id, type, payload_json, created_at,
                           producer_device_id, client_uuid)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind(
        userId,
        input.type,
        payloadJson,
        now,
        input.producerDeviceId,
        input.clientUuid ?? null
      )
      .run();
    // D1's INSERT result exposes the new rowid via meta.last_row_id.
    const id = Number(result.meta?.last_row_id);
    if (!Number.isFinite(id) || id <= 0) {
      throw new Error("appendEvent: D1 returned no last_row_id");
    }
    return {
      id,
      type: input.type,
      payload: input.payload ?? {},
      createdAt: now,
      producerDeviceId: input.producerDeviceId,
      clientUuid: input.clientUuid,
    };
  }

  /**
   * Catch-up query: events for this user with id > cursor, capped at
   * `limit` (default 500), in ascending id order. Empty array when
   * the consumer is caught up.
   */
  async eventsSince(userId: string, cursor: number, limit = 500): Promise<SyncEvent[]> {
    const safeLimit = Math.max(1, Math.min(500, Math.floor(limit)));
    const rs = await this.env.DB.prepare(
      `SELECT id, type, payload_json, created_at, producer_device_id, client_uuid
       FROM events
       WHERE user_id = ? AND id > ?
       ORDER BY id ASC
       LIMIT ?`
    )
      .bind(userId, cursor, safeLimit)
      .all();
    return rs.results.map((row) => ({
      id: row.id as number,
      type: row.type as SyncEventType,
      payload: row.payload_json ? JSON.parse(row.payload_json as string) : {},
      createdAt: row.created_at as number,
      producerDeviceId: row.producer_device_id as string,
      clientUuid: (row.client_uuid as string) || undefined,
    }));
  }

  /**
   * Current state snapshot + cursor for the consumer to anchor on.
   * Returned by GET /v1/sync/snapshot. The cursor is MAX(events.id)
   * *at query time*; any event written after the snapshot completes
   * will have id > cursor and is picked up via the next /events
   * fetch.
   */
  async computeSnapshot(userId: string): Promise<SyncSnapshot> {
    // Read MAX(id) up front. We tolerate the race where another
    // write lands between this query and the data fetches below —
    // those events will simply be returned both in the snapshot AND
    // in the next /events?since=cursor, which is idempotent because
    // the consumer applies by event id.
    const cursorRow = await this.env.DB.prepare(
      `SELECT COALESCE(MAX(id), 0) AS cursor FROM events WHERE user_id = ?`
    )
      .bind(userId)
      .first<{ cursor: number }>();
    const cursor = cursorRow?.cursor ?? 0;

    const [activeCards, liveSessions, queuedInstructions] = await Promise.all([
      this.listActiveCards(userId),
      this.listLiveSessions(userId),
      this.listQueuedInstructions(userId),
    ]);

    return { cursor, activeCards, liveSessions, queuedInstructions };
  }
}
