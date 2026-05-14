// Direct unit tests of Store.upsertCard's `changed` semantics — the
// piece the WS broadcast gate hinges on. Routes-level tests would
// hide this because we can't observe WS broadcasts in vitest's
// runner; calling the store directly keeps the assertion sharp.

import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { Store } from "../src/store.js";
import migration0001 from "../migrations/0001_initial.sql?raw";
import migration0002 from "../migrations/0002_apple_auth_code.sql?raw";
import migration0003 from "../migrations/0003_devices.sql?raw";
import migration0004 from "../migrations/0004_apns_token.sql?raw";
import migration0005 from "../migrations/0005_aps_environment.sql?raw";
import migration0006 from "../migrations/0006_events.sql?raw";
import migration0007 from "../migrations/0007_card_response_revision.sql?raw";

async function runMigrations() {
  const migrations = [migration0001, migration0002, migration0003, migration0004, migration0005, migration0006, migration0007];
  for (const sql of migrations) {
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
      } catch {
        // idempotency for ALTER TABLE ADD COLUMN on rerun
      }
    }
  }
}

async function bootstrapUser(userId: string) {
  await env.DB.prepare(
    `INSERT OR IGNORE INTO users (user_id, apple_email, display_name, created_at, last_seen_at)
     VALUES (?, ?, ?, ?, ?)`
  )
    .bind(userId, "test@example.com", "Test User", Date.now(), Date.now())
    .run();
}

beforeEach(async () => {
  await runMigrations();
  // events must come first — FK to users via user_id.
  await env.DB.prepare("DELETE FROM events").run();
  await env.DB.prepare("DELETE FROM cards").run();
  await env.DB.prepare("DELETE FROM users").run();
  await bootstrapUser("user-1");
});

function baseCard(overrides: Record<string, unknown> = {}) {
  return {
    cardId: "card-dedup-1",
    sessionId: "sess-1",
    category: "waiting",
    priority: "normal",
    title: "Claude paused",
    summary: "tail of agent output…",
    actionPrompt: null,
    payload: { terminalLines: ["line a", "line b"] },
    state: "active" as const,
    createdAt: 1000,
    updatedAt: 1000,
    ...overrides,
  };
}

describe("Store.upsertCard dedupe", () => {
  it("first insert returns inserted=true, changed=true", async () => {
    const store = new Store(env);
    const result = await store.upsertCard("user-1", baseCard());
    expect(result.inserted).toBe(true);
    expect(result.changed).toBe(true);
  });

  it("identical re-upsert returns inserted=false, changed=false", async () => {
    const store = new Store(env);
    const card = baseCard();
    await store.upsertCard("user-1", card);
    // Mac's reload tick bumps updated_at but keeps everything else
    // identical. Should not count as a change for broadcast purposes.
    const second = await store.upsertCard("user-1", { ...card, updatedAt: 2000 });
    expect(second.inserted).toBe(false);
    expect(second.changed).toBe(false);
  });

  it("changing title flips changed=true", async () => {
    const store = new Store(env);
    await store.upsertCard("user-1", baseCard());
    const result = await store.upsertCard(
      "user-1",
      baseCard({ title: "Claude REALLY paused", updatedAt: 2000 })
    );
    expect(result.changed).toBe(true);
    expect(result.inserted).toBe(false);
  });

  it("changing payload contents flips changed=true", async () => {
    const store = new Store(env);
    await store.upsertCard("user-1", baseCard());
    const result = await store.upsertCard(
      "user-1",
      baseCard({
        payload: { terminalLines: ["line a", "line b", "line c"] },
        updatedAt: 2000,
      })
    );
    expect(result.changed).toBe(true);
  });

  it("changing state from active to done flips changed=true", async () => {
    const store = new Store(env);
    await store.upsertCard("user-1", baseCard());
    const result = await store.upsertCard(
      "user-1",
      baseCard({ state: "done", updatedAt: 2000 })
    );
    expect(result.changed).toBe(true);
  });

  it("actionPrompt null vs '' is not treated as a change", async () => {
    // The Mac sends null when the field is absent; some test fixtures
    // send the empty string. Treat both as 'no prompt' so the
    // broadcast gate doesn't flap.
    const store = new Store(env);
    await store.upsertCard("user-1", baseCard({ actionPrompt: null }));
    const result = await store.upsertCard(
      "user-1",
      baseCard({ actionPrompt: null, updatedAt: 2000 })
    );
    expect(result.changed).toBe(false);
  });

  // becameActive is the gate APNS fanout uses. Without it, the
  // SteerAgent's "card-${sessionId}" id-reuse rule meant only the
  // first card of a session's lifetime ever pushed; every reply
  // after that produced a state-only flip (done → active) that
  // looked like a normal update and was silently filtered out.
  it("first insert with state=active sets becameActive=true", async () => {
    const store = new Store(env);
    const result = await store.upsertCard("user-1", baseCard());
    expect(result.becameActive).toBe(true);
  });

  it("state-stable update (active → active) keeps becameActive=false", async () => {
    const store = new Store(env);
    await store.upsertCard("user-1", baseCard());
    // Mac's reload tick: same content + bumped updated_at. Already
    // active, so no new push.
    const second = await store.upsertCard(
      "user-1",
      baseCard({ updatedAt: 2000 })
    );
    expect(second.becameActive).toBe(false);
  });

  it("active → done sets becameActive=false (resolution does not push)", async () => {
    const store = new Store(env);
    await store.upsertCard("user-1", baseCard());
    const result = await store.upsertCard(
      "user-1",
      baseCard({ state: "done", updatedAt: 2000 })
    );
    expect(result.becameActive).toBe(false);
  });

  it("done → active flips becameActive=true (the regression fix)", async () => {
    // The user's reported flow: first card alerts, user replies,
    // card resolves to done. Next stop on the SAME session
    // produces another active card with the same card_id —
    // pre-fix the gate said "not inserted" and ate the push.
    const store = new Store(env);
    await store.upsertCard("user-1", baseCard());
    await store.upsertCard("user-1", baseCard({ state: "done", updatedAt: 2000 }));
    const reactivated = await store.upsertCard(
      "user-1",
      baseCard({ state: "active", updatedAt: 3000 })
    );
    expect(reactivated.inserted).toBe(false);
    expect(reactivated.becameActive).toBe(true);
  });

  it("done → done keeps becameActive=false", async () => {
    const store = new Store(env);
    await store.upsertCard("user-1", baseCard({ state: "done" }));
    const result = await store.upsertCard(
      "user-1",
      baseCard({ state: "done", updatedAt: 2000 })
    );
    expect(result.becameActive).toBe(false);
  });
});
