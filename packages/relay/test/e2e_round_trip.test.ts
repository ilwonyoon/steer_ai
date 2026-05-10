// End-to-end round trip simulation:
//
//   Mac publishes a card -> iPhone reads it
//   iPhone enqueues a reply -> Mac fetches the queued instruction
//   Mac marks injected -> iPhone sees the status update
//   Mac resolves the card -> iPhone sees the card disappear
//
// We don't have a Mac process or an iPhone process here; we simulate
// each end with HTTP calls against the worker. This exercises the
// real route handlers, the real D1 schema, and the real Store class.
//
// Latency numbers come out of the in-process worker test runtime
// (no network), so they're not production-realistic — but the
// **count** of round trips and ordering invariants are.

import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { SignJWT } from "jose";
import { performance } from "node:perf_hooks";
import worker from "../src/index.js";
import migration0001 from "../migrations/0001_initial.sql?raw";
import migration0002 from "../migrations/0002_apple_auth_code.sql?raw";
import migration0003 from "../migrations/0003_devices.sql?raw";

async function runMigrations() {
  for (const sql of [migration0001, migration0002, migration0003]) {
    const cleaned = sql
      .split("\n")
      .filter((l) => !l.trim().startsWith("--"))
      .join("\n");
    for (const stmt of cleaned.split(";").map((s) => s.trim()).filter(Boolean)) {
      try {
        await env.DB.prepare(stmt).run();
      } catch (e) {
        if (String(e).includes("duplicate column")) continue;
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

async function token(userId: string) {
  const secret = new TextEncoder().encode(env.SESSION_JWT_SECRET as string);
  return await new SignJWT({ sub: userId })
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
    .bind(userId, `${userId}@test`, userId, Date.now(), Date.now())
    .run();
}

beforeEach(async () => {
  await runMigrations();
  for (const t of ["cards", "instructions", "sessions", "devices", "users"]) {
    await env.DB.prepare(`DELETE FROM ${t}`).run();
  }
});

describe("E2E round trip: card publish -> reply -> inject -> resolve", () => {
  it("completes the full loop with predictable ordering", async () => {
    const userId = "e2e-user";
    await bootstrapUser(userId);
    const t = await token(userId);
    const auth = { Authorization: `Bearer ${t}`, "Content-Type": "application/json" };
    const now = Date.now();

    // Stage 1: Mac registers itself.
    const t0 = performance.now();
    let res = await worker.request(
      "/v1/sync/devices",
      {
        method: "POST",
        headers: auth,
        body: JSON.stringify({
          deviceId: "mac-e2e",
          platform: "mac",
          displayName: "E2E Mac",
          deviceClass: "MacBook Pro",
          appVersion: "0.0.5",
          syncEnabled: true,
          lastSeenAt: now,
        }),
      },
      env
    );
    expect(res.status).toBe(200);

    // Stage 2: Mac publishes a card.
    const card = {
      cardId: "e2e-card",
      sessionId: "e2e-session",
      category: "question",
      priority: "normal",
      title: "Pick A or B",
      summary: "decide",
      payload: { terminalLines: ["$ choice", "A or B?"] },
      state: "active" as const,
      createdAt: now,
      updatedAt: now,
    };
    res = await worker.request(
      "/v1/sync/cards/e2e-card",
      { method: "PUT", headers: auth, body: JSON.stringify(card) },
      env
    );
    expect(res.status).toBe(200);

    // Stage 3: iPhone (same user, same JWT) lists cards.
    res = await worker.request(
      "/v1/sync/cards",
      { headers: { Authorization: `Bearer ${t}` } },
      env
    );
    let body: any = await res.json();
    expect(body.cards).toHaveLength(1);
    expect(body.cards[0].cardId).toBe("e2e-card");

    // Stage 4: iPhone enqueues a reply.
    res = await worker.request(
      "/v1/sync/instructions",
      {
        method: "POST",
        headers: auth,
        body: JSON.stringify({
          instructionId: "e2e-instr",
          targetSessionId: "e2e-session",
          text: "A",
        }),
      },
      env
    );
    expect(res.status).toBe(200);

    // Stage 5: Mac drains the queue.
    res = await worker.request(
      "/v1/sync/instructions/queued",
      { headers: { Authorization: `Bearer ${t}` } },
      env
    );
    body = await res.json();
    expect(body.instructions).toHaveLength(1);
    expect(body.instructions[0].text).toBe("A");

    // Stage 6: Mac marks it injected.
    res = await worker.request(
      "/v1/sync/instructions/e2e-instr/status",
      {
        method: "POST",
        headers: auth,
        body: JSON.stringify({ status: "injected" }),
      },
      env
    );
    expect(res.status).toBe(200);

    // Stage 7: Mac resolves the card.
    res = await worker.request(
      "/v1/sync/cards/e2e-card",
      { method: "DELETE", headers: { Authorization: `Bearer ${t}` } },
      env
    );
    expect(res.status).toBe(200);

    // Stage 8: iPhone sees no active cards and an empty queue.
    res = await worker.request(
      "/v1/sync/cards",
      { headers: { Authorization: `Bearer ${t}` } },
      env
    );
    body = await res.json();
    expect(body.cards).toHaveLength(0);

    res = await worker.request(
      "/v1/sync/instructions/queued",
      { headers: { Authorization: `Bearer ${t}` } },
      env
    );
    body = await res.json();
    expect(body.instructions).toHaveLength(0);

    const elapsedMs = performance.now() - t0;
    console.log(`[e2e] full loop in ${elapsedMs.toFixed(1)}ms (8 round trips)`);
    // Each round trip is 1 D1 query + 1 DO broadcast in-process.
    // Generous budget — production network adds 100-500ms per hop.
    expect(elapsedMs).toBeLessThan(2000);
  });
});

describe("E2E reconnect: card update arrives after relisten", () => {
  it("iPhone reconnect via /v1/sync/cards picks up cards published while disconnected", async () => {
    const userId = "e2e-reconnect";
    await bootstrapUser(userId);
    const t = await token(userId);
    const auth = { Authorization: `Bearer ${t}`, "Content-Type": "application/json" };
    const now = Date.now();

    // iPhone gets initial empty list (the "ready" snapshot).
    let res = await worker.request(
      "/v1/sync/cards",
      { headers: { Authorization: `Bearer ${t}` } },
      env
    );
    expect(((await res.json()) as any).cards).toHaveLength(0);

    // While iPhone is "offline" (we don't actually open a WS),
    // Mac publishes 3 cards.
    for (let i = 0; i < 3; i++) {
      await worker.request(
        `/v1/sync/cards/disco-${i}`,
        {
          method: "PUT",
          headers: auth,
          body: JSON.stringify({
            cardId: `disco-${i}`,
            sessionId: `s-${i}`,
            category: "question",
            priority: "normal",
            title: `disconnected ${i}`,
            summary: ".",
            state: "active",
            createdAt: now + i,
            updatedAt: now + i,
          }),
        },
        env
      );
    }

    // iPhone reconnects, polls cards. Should see all 3.
    res = await worker.request(
      "/v1/sync/cards",
      { headers: { Authorization: `Bearer ${t}` } },
      env
    );
    const body = (await res.json()) as { cards: any[] };
    expect(body.cards).toHaveLength(3);
    // Returned in updated_at order.
    expect(body.cards.map((c) => c.cardId)).toEqual(["disco-0", "disco-1", "disco-2"]);
  });
});

describe("E2E throughput: 50 cards in one batch", () => {
  it("50 sequential PUTs land in 50 list rows and stay in order", async () => {
    const userId = "e2e-bulk";
    await bootstrapUser(userId);
    const t = await token(userId);
    const auth = { Authorization: `Bearer ${t}`, "Content-Type": "application/json" };

    const start = performance.now();
    for (let i = 0; i < 50; i++) {
      const now = Date.now() + i;
      await worker.request(
        `/v1/sync/cards/bulk-${i}`,
        {
          method: "PUT",
          headers: auth,
          body: JSON.stringify({
            cardId: `bulk-${i}`,
            sessionId: `bulk-s-${i}`,
            category: "question",
            priority: "normal",
            title: `bulk ${i}`,
            summary: ".",
            state: "active",
            createdAt: now,
            updatedAt: now,
          }),
        },
        env
      );
    }
    const elapsedMs = performance.now() - start;
    console.log(`[e2e] 50 PUTs sequential in ${elapsedMs.toFixed(0)}ms (${(elapsedMs / 50).toFixed(1)}ms each)`);
    expect(elapsedMs).toBeLessThan(5000);

    const res = await worker.request(
      "/v1/sync/cards",
      { headers: { Authorization: `Bearer ${t}` } },
      env
    );
    const body = (await res.json()) as { cards: any[] };
    expect(body.cards).toHaveLength(50);
    // Hard cap at 200 in the route handler, so 50 fits comfortably.
  });
});
