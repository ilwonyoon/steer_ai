// PR 1 unit tests for the v3 event log + dual-write.
// See docs/SYNC_ARCHITECTURE_V3.md "Event taxonomy" and "PR 1" sections.
//
// Scope of this file:
//   1. Store.appendEvent monotonicity + idempotency
//   2. Store.eventsSince ordering + limit
//   3. Store.computeSnapshot cursor matches MAX(events.id)
//   4. Dual-write: every legacy mutation produces a matching event row
//   5. HTTP endpoints POST/GET /v1/sync/events + GET /v1/sync/snapshot
//      decode and return the same shapes the design doc promises.

import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { SignJWT } from "jose";
import { Store } from "../src/store.js";
// Use SELF/worker.request from cloudflare:test for in-process route
// invocation (same pattern as routes.test.ts).
import worker from "../src/index.js";
import migration0001 from "../migrations/0001_initial.sql?raw";
import migration0002 from "../migrations/0002_apple_auth_code.sql?raw";
import migration0003 from "../migrations/0003_devices.sql?raw";
import migration0004 from "../migrations/0004_apns_token.sql?raw";
import migration0005 from "../migrations/0005_aps_environment.sql?raw";
import migration0006 from "../migrations/0006_events.sql?raw";
import migration0007 from "../migrations/0007_card_response_revision.sql?raw";

// SESSION_JWT_SECRET is set by wrangler test config — we read it from
// env at sign time so we don't hard-code anything.

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

async function runMigrations() {
  for (const sql of [migration0001, migration0002, migration0003, migration0004, migration0005, migration0006, migration0007]) {
    const cleaned = sql
      .split("\n")
      .filter((l) => !l.trim().startsWith("--"))
      .join("\n");
    for (const stmt of cleaned.split(";").map((s) => s.trim()).filter(Boolean)) {
      try {
        await env.DB.prepare(stmt).run();
      } catch {
        // tolerate idempotent ALTERs across reruns
      }
    }
  }
}

async function bootstrapUser(userId: string) {
  await env.DB.prepare(
    `INSERT OR IGNORE INTO users (user_id, apple_email, display_name, created_at, last_seen_at)
     VALUES (?, ?, ?, ?, ?)`
  )
    .bind(userId, `${userId}@test`, userId, Date.now(), Date.now())
    .run();
}

async function makeJwt(userId: string): Promise<string> {
  // Mirror routes.test.ts: HS256 signed with the env-provided secret,
  // sub claim carries the user id, issuer matches what auth.ts
  // expects.
  const secret = new TextEncoder().encode(env.SESSION_JWT_SECRET as string);
  return await new SignJWT({ sub: userId, name: "Test User" })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuedAt()
    .setExpirationTime("1h")
    .setIssuer("ai.steer.relay")
    .sign(secret);
}

function authedHeaders(jwt: string, deviceId = "dev-test"): Record<string, string> {
  return {
    Authorization: `Bearer ${jwt}`,
    "Content-Type": "application/json",
    "X-Steer-Device-Id": deviceId,
  };
}

/**
 * Vitest pool-workers uses `worker.request(path, init, env)` not
 * `worker.fetch(Request, env)`. Wrap so each test stays readable.
 */
async function call(
  path: string,
  init: RequestInit,
  jwt: string,
  deviceId = "dev-test"
): Promise<Response> {
  return worker.request(
    path,
    {
      ...init,
      headers: {
        ...(init.headers ?? {}),
        ...authedHeaders(jwt, deviceId),
      },
    },
    env
  );
}

beforeEach(async () => {
  await runMigrations();
  for (const t of ["events", "cards", "instructions", "sessions", "devices", "users"]) {
    await env.DB.prepare(`DELETE FROM ${t}`).run();
  }
  await bootstrapUser("user-1");
});

describe("Store.appendEvent", () => {
  it("returns monotonically increasing ids", async () => {
    const store = new Store(env);
    const e1 = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: { cardId: "c1" },
      producerDeviceId: "mac-1",
      clientUuid: "k1",
    });
    const e2 = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: { cardId: "c2" },
      producerDeviceId: "mac-1",
      clientUuid: "k2",
    });
    expect(e2.id).toBeGreaterThan(e1.id);
  });

  it("dedupes on (producerDeviceId, clientUuid)", async () => {
    const store = new Store(env);
    const first = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: { cardId: "c1", n: 1 },
      producerDeviceId: "mac-1",
      clientUuid: "key-A",
    });
    const second = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: { cardId: "c1", n: 2 }, // different payload — still dedupes
      producerDeviceId: "mac-1",
      clientUuid: "key-A",
    });
    expect(second.id).toBe(first.id);
    // Payload of the returned event is the ORIGINAL — we never overwrote.
    expect(second.payload).toEqual({ cardId: "c1", n: 1 });
    // Row count is 1, not 2.
    const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM events`).first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("different producerDeviceId with same clientUuid does NOT dedupe", async () => {
    const store = new Store(env);
    const a = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: {},
      producerDeviceId: "mac-A",
      clientUuid: "shared",
    });
    const b = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: {},
      producerDeviceId: "mac-B",
      clientUuid: "shared",
    });
    expect(b.id).not.toBe(a.id);
  });

  it("null clientUuid never dedupes", async () => {
    const store = new Store(env);
    const a = await store.appendEvent("user-1", {
      type: "device.heartbeat",
      payload: {},
      producerDeviceId: "mac-1",
    });
    const b = await store.appendEvent("user-1", {
      type: "device.heartbeat",
      payload: {},
      producerDeviceId: "mac-1",
    });
    expect(b.id).toBeGreaterThan(a.id);
  });
});

describe("Store.eventsSince", () => {
  it("returns rows in ascending id order, exclusive of cursor", async () => {
    const store = new Store(env);
    const ids: number[] = [];
    for (let i = 0; i < 5; i++) {
      const e = await store.appendEvent("user-1", {
        type: "card.upsert",
        payload: { i },
        producerDeviceId: "mac-1",
        clientUuid: `k${i}`,
      });
      ids.push(e.id);
    }
    const fromMid = await store.eventsSince("user-1", ids[2]);
    expect(fromMid.map((e) => e.id)).toEqual(ids.slice(3));
  });

  it("respects limit (1..500)", async () => {
    const store = new Store(env);
    for (let i = 0; i < 10; i++) {
      await store.appendEvent("user-1", {
        type: "card.upsert",
        payload: { i },
        producerDeviceId: "mac-1",
        clientUuid: `k${i}`,
      });
    }
    const limited = await store.eventsSince("user-1", 0, 3);
    expect(limited).toHaveLength(3);
  });

  it("scopes by user_id", async () => {
    const store = new Store(env);
    await bootstrapUser("user-2");
    await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: { who: "1" },
      producerDeviceId: "mac-1",
      clientUuid: "k1",
    });
    await store.appendEvent("user-2", {
      type: "card.upsert",
      payload: { who: "2" },
      producerDeviceId: "mac-2",
      clientUuid: "k2",
    });
    const u1 = await store.eventsSince("user-1", 0);
    const u2 = await store.eventsSince("user-2", 0);
    expect(u1).toHaveLength(1);
    expect(u2).toHaveLength(1);
    expect(u1[0].payload).toEqual({ who: "1" });
    expect(u2[0].payload).toEqual({ who: "2" });
  });
});

describe("Store.computeSnapshot", () => {
  it("returns cursor = MAX(events.id) at query time", async () => {
    const store = new Store(env);
    const e1 = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: {},
      producerDeviceId: "mac-1",
      clientUuid: "k1",
    });
    const e2 = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: {},
      producerDeviceId: "mac-1",
      clientUuid: "k2",
    });
    const snap = await store.computeSnapshot("user-1");
    expect(snap.cursor).toBe(e2.id);
    expect(snap.cursor).toBeGreaterThan(e1.id);
  });

  it("returns cursor=0 for a brand-new user with no events", async () => {
    const store = new Store(env);
    await bootstrapUser("user-fresh");
    const snap = await store.computeSnapshot("user-fresh");
    expect(snap.cursor).toBe(0);
    expect(snap.activeCards).toEqual([]);
    expect(snap.liveSessions).toEqual([]);
    expect(snap.queuedInstructions).toEqual([]);
  });
});

describe("dual-write: legacy mutations produce event rows", () => {
  it("PUT /v1/sync/cards/:id inserts a card.upsert event", async () => {
    const jwt = await makeJwt("user-1");
    const card = {
      cardId: "c-dw-1",
      sessionId: "s-1",
      category: "question",
      priority: "normal",
      title: "test",
      summary: "test",
      payload: {},
      state: "active",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const res = await call(
      "/v1/sync/cards/c-dw-1",
      { method: "PUT", body: JSON.stringify(card) },
      jwt,
      "mac-dw-1"
    );
    expect(res.status).toBe(200);

    const events = await new Store(env).eventsSince("user-1", 0);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("card.upsert");
    expect(events[0].producerDeviceId).toBe("mac-dw-1");
    expect((events[0].payload as { cardId: string }).cardId).toBe("c-dw-1");
  });

  it("DELETE /v1/sync/cards/:id inserts a card.resolved event", async () => {
    const jwt = await makeJwt("user-1");
    // Seed an active card directly.
    await new Store(env).upsertCard("user-1", {
      cardId: "c-dw-2",
      sessionId: "s",
      category: "question",
      priority: "normal",
      title: "t",
      summary: "s",
      payload: {},
      state: "active",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });

    const res = await call("/v1/sync/cards/c-dw-2", { method: "DELETE" }, jwt);
    expect(res.status).toBe(200);

    const events = await new Store(env).eventsSince("user-1", 0);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("card.resolved");
    expect((events[0].payload as { cardId: string }).cardId).toBe("c-dw-2");
  });

  it("POST /v1/sync/sessions is a deprecated no-op (no event written)", async () => {
    const jwt = await makeJwt("user-1");
    const res = await call(
      "/v1/sync/sessions",
      {
        method: "POST",
        body: JSON.stringify({
          sessionId: "s-1",
          provider: "claude",
          runState: "running",
          lastActivityAt: Date.now(),
        }),
      },
      jwt
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean; deprecated?: boolean };
    expect(body.ok).toBe(true);
    expect(body.deprecated).toBe(true);

    // Critical: no session.upsert event landed. Older Mac binaries
    // that still publish here must not pile up dead session rows on
    // the event log.
    const events = await new Store(env).eventsSince("user-1", 0);
    expect(events).toHaveLength(0);
  });

  it("retrying the SAME PUT /v1/sync/cards/:id (same updatedAt) dedupes", async () => {
    const jwt = await makeJwt("user-1");
    const ts = Date.now();
    const card = {
      cardId: "c-dedup",
      sessionId: "s",
      category: "question",
      priority: "normal",
      title: "t",
      summary: "s",
      payload: {},
      state: "active",
      createdAt: ts,
      updatedAt: ts,
    };
    const req = () =>
      call(
        "/v1/sync/cards/c-dedup",
        { method: "PUT", body: JSON.stringify(card) },
        jwt,
        "mac-dedup"
      );
    await req();
    await req();
    const events = await new Store(env).eventsSince("user-1", 0);
    // Both legacy upserts ran (idempotent at the cards table); the
    // event row is deduped on (producer_device_id, client_uuid).
    expect(events.filter((e) => e.type === "card.upsert")).toHaveLength(1);
  });

  it("PUT with a NEWER updatedAt produces a new card.upsert event", async () => {
    const jwt = await makeJwt("user-1");
    const cardBase = {
      cardId: "c-evolving",
      sessionId: "s",
      category: "question",
      priority: "normal",
      title: "t1",
      summary: "s",
      payload: {},
      state: "active" as const,
      createdAt: 1000,
    };
    await call(
      "/v1/sync/cards/c-evolving",
      { method: "PUT", body: JSON.stringify({ ...cardBase, title: "t1", updatedAt: 1000 }) },
      jwt,
      "mac-A"
    );
    await call(
      "/v1/sync/cards/c-evolving",
      { method: "PUT", body: JSON.stringify({ ...cardBase, title: "t2", updatedAt: 2000 }) },
      jwt,
      "mac-A"
    );
    const events = await new Store(env).eventsSince("user-1", 0);
    expect(events.filter((e) => e.type === "card.upsert")).toHaveLength(2);
  });
});

describe("HTTP endpoints", () => {
  it("POST /v1/sync/events validates type", async () => {
    const jwt = await makeJwt("user-1");
    const res = await call(
      "/v1/sync/events",
      {
        method: "POST",
        body: JSON.stringify({ type: "bogus.type", payload: {} }),
      },
      jwt
    );
    expect(res.status).toBe(400);
  });

  it("POST /v1/sync/events accepts a valid type", async () => {
    const jwt = await makeJwt("user-1");
    const res = await call(
      "/v1/sync/events",
      {
        method: "POST",
        body: JSON.stringify({
          type: "instruction.queued",
          payload: { instructionId: "i-1", text: "hi" },
          producerDeviceId: "ios-1",
          clientUuid: "iu-1",
        }),
      },
      jwt,
      "ios-1"
    );
    expect(res.status).toBe(200);
    const json = (await res.json()) as { event: { id: number; type: string } };
    expect(json.event.type).toBe("instruction.queued");
    expect(json.event.id).toBeGreaterThan(0);
  });

  it("GET /v1/sync/events?since=N filters correctly", async () => {
    const jwt = await makeJwt("user-1");
    const store = new Store(env);
    const e1 = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: {},
      producerDeviceId: "mac-1",
      clientUuid: "k1",
    });
    const e2 = await store.appendEvent("user-1", {
      type: "card.upsert",
      payload: {},
      producerDeviceId: "mac-1",
      clientUuid: "k2",
    });
    const res = await call(`/v1/sync/events?since=${e1.id}`, { method: "GET" }, jwt);
    expect(res.status).toBe(200);
    const json = (await res.json()) as { events: { id: number }[] };
    expect(json.events).toHaveLength(1);
    expect(json.events[0].id).toBe(e2.id);
  });

  it("GET /v1/sync/events rejects negative since", async () => {
    const jwt = await makeJwt("user-1");
    const res = await call("/v1/sync/events?since=-1", { method: "GET" }, jwt);
    expect(res.status).toBe(400);
  });

  it("GET /v1/sync/snapshot returns cursor + state arrays", async () => {
    const jwt = await makeJwt("user-1");
    // Create one card via the legacy path; dual-write should bump
    // the event cursor.
    const card = {
      cardId: "c-snap",
      sessionId: "s",
      category: "question",
      priority: "normal",
      title: "t",
      summary: "s",
      payload: {},
      state: "active",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    await call(
      "/v1/sync/cards/c-snap",
      { method: "PUT", body: JSON.stringify(card) },
      jwt
    );

    const res = await call("/v1/sync/snapshot", { method: "GET" }, jwt);
    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      cursor: number;
      activeCards: { cardId: string }[];
      liveSessions: unknown[];
      queuedInstructions: unknown[];
    };
    expect(json.cursor).toBeGreaterThan(0);
    expect(json.activeCards.map((c) => c.cardId)).toContain("c-snap");
  });
});
