import type { CardPayload, Env, InstructionRecord, SessionSnapshot } from "./types.js";

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
    await this.env.DB.prepare(`DELETE FROM users WHERE user_id = ?`).bind(userId).run();
  }

  async upsertCard(userId: string, card: CardPayload): Promise<void> {
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
        JSON.stringify(card.payload ?? {}),
        card.state,
        card.createdAt,
        card.updatedAt
      )
      .run();
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
}
