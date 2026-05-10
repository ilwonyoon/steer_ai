import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { SignJWT } from "jose";
import worker from "../src/index.js";
import migration0001 from "../migrations/0001_initial.sql?raw";
import migration0002 from "../migrations/0002_apple_auth_code.sql?raw";
import migration0003 from "../migrations/0003_devices.sql?raw";
import migration0004 from "../migrations/0004_apns_token.sql?raw";

async function runMigrations() {
  // Workers runtime has no fs; we vite-import the SQL files as raw
  // strings instead. New migrations: import + add to this array.
  const migrations = [migration0001, migration0002, migration0003, migration0004];
  for (const sql of migrations) {
    // Strip line comments first so they don't break statement
    // splitting, then split on `;` and run each statement.
    const cleaned = sql
      .split("\n")
      .filter((line) => !line.trim().startsWith("--"))
      .join("\n");
    const statements = cleaned
      .split(";")
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
    for (const stmt of statements) {
      try {
        await env.DB.prepare(stmt).run();
      } catch (e) {
        // beforeEach reruns all migrations on each test; SQLite ALTER
        // TABLE ADD COLUMN can't be made idempotent, so swallow the
        // duplicate-column error for replayed migrations.
        const msg = String(e);
        if (msg.includes("duplicate column")) continue;
        throw e;
      }
    }
  }
}

declare module "cloudflare:test" {
  interface ProvidedEnv extends Record<string, unknown> {
    DB: D1Database;
    USER_HUB: DurableObjectNamespace;
    SESSION_JWT_SECRET: string;
    APPLE_JWKS_URL: string;
    APPLE_AUDIENCES: string;
    APPLE_ISSUER: string;
  }
}

async function freshSessionToken(userId = "user-test-1") {
  const secret = new TextEncoder().encode(env.SESSION_JWT_SECRET as string);
  return await new SignJWT({ sub: userId, name: "Test User" })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuedAt()
    .setExpirationTime("1h")
    .setIssuer("ai.steer.relay")
    .sign(secret);
}

async function bootstrapUser(userId: string) {
  await env.DB.prepare(
    `INSERT OR IGNORE INTO users (user_id, apple_email, display_name, created_at, last_seen_at)
     VALUES (?, ?, ?, ?, ?)`
  )
    .bind(userId, "test@example.com", "Test User", Date.now(), Date.now())
    .run();
}

/// Seed a card so the user "owns" the given session_id. The
/// /v1/sync/instructions ownership check (added with the security
/// audit P0 fix) requires this — otherwise instructions are 403.
async function bootstrapCardForSession(userId: string, sessionId: string) {
  const now = Date.now();
  await env.DB.prepare(
    `INSERT OR IGNORE INTO cards (
       card_id, user_id, session_id, category, priority,
       title, summary, payload_json, state,
       created_at, updated_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(
      `card-for-${sessionId}`, userId, sessionId,
      "question", "normal", "T", ".", "{}", "active", now, now
    )
    .run();
}

beforeEach(async () => {
  await runMigrations();
  await env.DB.prepare("DELETE FROM cards").run();
  await env.DB.prepare("DELETE FROM instructions").run();
  await env.DB.prepare("DELETE FROM sessions").run();
  await env.DB.prepare("DELETE FROM devices").run();
  await env.DB.prepare("DELETE FROM users").run();
});

describe("auth", () => {
  it("rejects requests without Authorization", async () => {
    const res = await worker.request("/v1/me", {}, env);
    expect(res.status).toBe(401);
  });

  it("rejects bogus session tokens", async () => {
    const res = await worker.request(
      "/v1/me",
      { headers: { Authorization: "Bearer not-a-jwt" } },
      env
    );
    expect(res.status).toBe(401);
  });

  it("accepts a freshly minted session token", async () => {
    await bootstrapUser("user-test-1");
    const token = await freshSessionToken();
    const res = await worker.request(
      "/v1/me",
      { headers: { Authorization: `Bearer ${token}` } },
      env
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect((body as any).user.userId).toBe("user-test-1");
  });

  it("deletes the signed-in user's relay account data", async () => {
    await bootstrapUser("user-delete");
    await bootstrapUser("user-keep");
    const token = await freshSessionToken("user-delete");
    const now = Date.now();
    await env.DB.prepare(
      `INSERT INTO cards (
        card_id, user_id, session_id, category, priority, title, summary,
        payload_json, state, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
      .bind("card-delete", "user-delete", "session-delete", "question", "normal", "Q", "?", "{}", "active", now, now)
      .run();
    await env.DB.prepare(
      `INSERT INTO instructions (
        instruction_id, user_id, target_session_id, text, status, created_at
      ) VALUES (?, ?, ?, ?, 'queued', ?)`
    )
      .bind("instruction-delete", "user-delete", "session-delete", "go", now)
      .run();
    await env.DB.prepare(
      `INSERT INTO sessions (
        session_id, user_id, provider, project_name, run_state, last_activity_at
      ) VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind("session-delete", "user-delete", "codex", "repo/app", "waiting", now)
      .run();
    await env.DB.prepare(
      `INSERT INTO cards (
        card_id, user_id, session_id, category, priority, title, summary,
        payload_json, state, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
      .bind("card-keep", "user-keep", "session-keep", "question", "normal", "Q", "?", "{}", "active", now, now)
      .run();

    const res = await worker.request(
      "/v1/me",
      { method: "DELETE", headers: { Authorization: `Bearer ${token}` } },
      env
    );
    expect(res.status).toBe(200);

    const deletedUser = await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE user_id = ?")
      .bind("user-delete")
      .first<{ n: number }>();
    const deletedCards = await env.DB.prepare("SELECT COUNT(*) AS n FROM cards WHERE user_id = ?")
      .bind("user-delete")
      .first<{ n: number }>();
    const deletedInstructions = await env.DB.prepare("SELECT COUNT(*) AS n FROM instructions WHERE user_id = ?")
      .bind("user-delete")
      .first<{ n: number }>();
    const deletedSessions = await env.DB.prepare("SELECT COUNT(*) AS n FROM sessions WHERE user_id = ?")
      .bind("user-delete")
      .first<{ n: number }>();
    const keptCards = await env.DB.prepare("SELECT COUNT(*) AS n FROM cards WHERE user_id = ?")
      .bind("user-keep")
      .first<{ n: number }>();

    expect(deletedUser?.n).toBe(0);
    expect(deletedCards?.n).toBe(0);
    expect(deletedInstructions?.n).toBe(0);
    expect(deletedSessions?.n).toBe(0);
    expect(keptCards?.n).toBe(1);
  });
});

describe("cards", () => {
  it("publishes a card and lists it back", async () => {
    await bootstrapUser("user-cards");
    const token = await freshSessionToken("user-cards");
    const card = {
      cardId: "card-1",
      sessionId: "session-1",
      category: "blocker",
      priority: "urgent",
      title: "Claude needs unblock",
      summary: "permission denied",
      payload: { terminalLines: ["error: permission denied"] },
      state: "active" as const,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const put = await worker.request(
      "/v1/sync/cards/card-1",
      {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(card),
      },
      env
    );
    expect(put.status).toBe(200);

    const list = await worker.request(
      "/v1/sync/cards",
      { headers: { Authorization: `Bearer ${token}` } },
      env
    );
    const body = (await list.json()) as { cards: any[] };
    expect(body.cards).toHaveLength(1);
    expect(body.cards[0].cardId).toBe("card-1");
    expect(body.cards[0].payload.terminalLines).toEqual(["error: permission denied"]);
  });

  it("isolates cards per user", async () => {
    await bootstrapUser("user-a");
    await bootstrapUser("user-b");
    const tokenA = await freshSessionToken("user-a");
    const tokenB = await freshSessionToken("user-b");
    const card = {
      cardId: "card-a",
      sessionId: "session-a",
      category: "waiting",
      priority: "normal",
      title: "A's session",
      summary: "...",
      state: "active" as const,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    await worker.request(
      "/v1/sync/cards/card-a",
      {
        method: "PUT",
        headers: { Authorization: `Bearer ${tokenA}`, "Content-Type": "application/json" },
        body: JSON.stringify(card),
      },
      env
    );

    const listB = await worker.request(
      "/v1/sync/cards",
      { headers: { Authorization: `Bearer ${tokenB}` } },
      env
    );
    const body = (await listB.json()) as { cards: any[] };
    expect(body.cards).toHaveLength(0);
  });

  it("resolves a card", async () => {
    await bootstrapUser("user-resolve");
    const token = await freshSessionToken("user-resolve");
    const card = {
      cardId: "card-resolve",
      sessionId: "session-1",
      category: "question",
      priority: "normal",
      title: "Q",
      summary: "?",
      state: "active" as const,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    await worker.request(
      "/v1/sync/cards/card-resolve",
      {
        method: "PUT",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify(card),
      },
      env
    );
    await worker.request(
      "/v1/sync/cards/card-resolve",
      { method: "DELETE", headers: { Authorization: `Bearer ${token}` } },
      env
    );
    const list = await worker.request(
      "/v1/sync/cards",
      { headers: { Authorization: `Bearer ${token}` } },
      env
    );
    const body = (await list.json()) as { cards: any[] };
    expect(body.cards).toHaveLength(0);
  });
});

describe("devices", () => {
  it("upserts a device heartbeat and lists it back", async () => {
    await bootstrapUser("user-dev");
    const token = await freshSessionToken("user-dev");
    const heartbeat = {
      deviceId: "mac-abc",
      platform: "mac",
      displayName: "Ilwon's MacBook Air",
      deviceClass: "MacBook Air",
      appVersion: "0.0.4",
      syncEnabled: true,
      lastSeenAt: Date.now(),
    };
    const post = await worker.request(
      "/v1/sync/devices",
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify(heartbeat),
      },
      env
    );
    expect(post.status).toBe(200);

    const list = await worker.request(
      "/v1/sync/devices",
      { headers: { Authorization: `Bearer ${token}` } },
      env
    );
    const body = (await list.json()) as { devices: any[] };
    expect(body.devices).toHaveLength(1);
    expect(body.devices[0].displayName).toBe("Ilwon's MacBook Air");
    expect(body.devices[0].syncEnabled).toBe(true);
  });

  it("isolates device list per user", async () => {
    await bootstrapUser("user-dev-a");
    await bootstrapUser("user-dev-b");
    const tokenA = await freshSessionToken("user-dev-a");
    const tokenB = await freshSessionToken("user-dev-b");
    await worker.request(
      "/v1/sync/devices",
      {
        method: "POST",
        headers: { Authorization: `Bearer ${tokenA}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          deviceId: "mac-a",
          platform: "mac",
          displayName: "A's Mac",
          syncEnabled: true,
          lastSeenAt: Date.now(),
        }),
      },
      env
    );
    const listB = await worker.request(
      "/v1/sync/devices",
      { headers: { Authorization: `Bearer ${tokenB}` } },
      env
    );
    const body = (await listB.json()) as { devices: any[] };
    expect(body.devices).toHaveLength(0);
  });
});

describe("instructions", () => {
  it("queues an instruction and returns it from queued list", async () => {
    await bootstrapUser("user-inst");
    await bootstrapCardForSession("user-inst", "session-1");
    const token = await freshSessionToken("user-inst");
    const post = await worker.request(
      "/v1/sync/instructions",
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          instructionId: "instr-1",
          targetSessionId: "session-1",
          text: "go ahead",
        }),
      },
      env
    );
    expect(post.status).toBe(200);

    const list = await worker.request(
      "/v1/sync/instructions/queued",
      { headers: { Authorization: `Bearer ${token}` } },
      env
    );
    const body = (await list.json()) as { instructions: any[] };
    expect(body.instructions).toHaveLength(1);
    expect(body.instructions[0].text).toBe("go ahead");
  });

  it("marks an instruction injected and removes it from queued", async () => {
    await bootstrapUser("user-mark");
    await bootstrapCardForSession("user-mark", "session-1");
    const token = await freshSessionToken("user-mark");
    await worker.request(
      "/v1/sync/instructions",
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          instructionId: "instr-mark",
          targetSessionId: "session-1",
          text: "do it",
        }),
      },
      env
    );
    await worker.request(
      "/v1/sync/instructions/instr-mark/status",
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ status: "injected" }),
      },
      env
    );
    const list = await worker.request(
      "/v1/sync/instructions/queued",
      { headers: { Authorization: `Bearer ${token}` } },
      env
    );
    const body = (await list.json()) as { instructions: any[] };
    expect(body.instructions).toHaveLength(0);
  });
});
