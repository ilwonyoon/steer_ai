import { Hono } from "hono";
import { cors } from "hono/cors";
import {
  extractAuthorizedUser,
  mintSessionJWT,
  revokeAppleAuthGrant,
  verifyAppleIdentityToken,
} from "./auth.js";
import { sendAPNSPush } from "./apns.js";
import { Store } from "./store.js";
import type {
  CardPayload,
  DeviceSnapshot,
  Env,
  InstructionRequest,
  SessionSnapshot,
  SessionUser,
  SyncEventInput,
  SyncEventType,
  WSMessage,
} from "./types.js";

/**
 * X-Steer-Device-Id header. Producer identity for the v3 event log
 * (dual-write — see docs/SYNC_ARCHITECTURE_V3.md). Mac and iOS
 * already send this header for WebSocket auth; we just read it again
 * for HTTP routes that need to stamp events.
 *
 * Fallback to "unknown-<userId>" when the header is absent — currently
 * only happens on legacy clients that haven't been updated to send
 * the header on REST routes. Captures the user identity at least so
 * audits aren't blank.
 */
function producerDeviceId(c: import("hono").Context<{ Bindings: Env; Variables: Variables }>): string {
  const raw = c.req.header("X-Steer-Device-Id");
  if (raw && raw.length > 0) return raw;
  const userId = c.get("user").userId;
  return `unknown-${userId}`;
}

/**
 * Best-effort dual-write of a v3 event row beside a legacy mutation.
 *
 * PR 1 semantics: legacy mutation is the source of truth; event log
 * is observation-only. If the event write fails (D1 hiccup, schema
 * out of sync after a partial rollout), we log and continue. The
 * legacy row + WebSocket broadcast still landed, so user-visible
 * behavior is unaffected. This deliberately is NOT atomic with the
 * legacy write for now — PR 2 will tighten this up by routing
 * through D1's batch API once clients consume events directly.
 *
 * `clientUuid` is the producer-side idempotency key. For legacy
 * routes that don't carry one, we synthesize from the natural unique
 * key of the mutation (cardId, instructionId, sessionId, deviceId)
 * so a retried request dedupes correctly.
 */
async function appendEventDualWrite(
  store: Store,
  userId: string,
  type: SyncEventType,
  payload: Record<string, unknown>,
  producerDeviceId: string,
  clientUuid: string
): Promise<void> {
  try {
    await store.appendEvent(userId, {
      type,
      payload,
      producerDeviceId,
      clientUuid,
    });
  } catch (e) {
    console.warn(`[event-dualwrite] failed type=${type} user=${userId}: ${e}`);
  }
}

export { UserHub } from "./userHub.js";

interface Variables {
  user: SessionUser;
}

const app = new Hono<{ Bindings: Env; Variables: Variables }>();

app.use("*", cors());

app.get("/", (c) => c.json({ ok: true, name: "steer-relay", version: "0.1.0" }));

/**
 * POST /v1/auth/apple
 * Body: { identityToken: string, displayName?: string }
 * Returns: { sessionToken: string, user: SessionUser }
 *
 * Front door for Sign in with Apple. The Mac/iOS app already ran
 * ASAuthorizationAppleIDProvider and got an identityToken. We verify
 * it against Apple's JWKS, upsert the user row, and mint our own
 * 30-day session JWT.
 */
app.post("/v1/auth/apple", async (c) => {
  const body = await c.req.json<{
    identityToken?: string;
    displayName?: string;
    authorizationCode?: string;
    deviceId?: string;
  }>();
  if (!body.identityToken) {
    return c.json({ error: "missing identityToken" }, 400);
  }
  let identity;
  try {
    identity = await verifyAppleIdentityToken(body.identityToken, c.env);
  } catch (e) {
    return c.json({ error: "invalid Apple identity token", detail: String(e) }, 401);
  }
  const store = new Store(c.env);
  await store.upsertUser(
    identity.sub,
    identity.email,
    body.displayName,
    body.authorizationCode
  );
  const user: SessionUser = {
    userId: identity.sub,
    appleEmail: identity.email,
    displayName: body.displayName,
  };
  // Bind the JWT to the caller's device id when supplied. Older
  // clients (pre-device-binding rollout) omit it and get an
  // unbound token, which the auth middleware still accepts until
  // it expires.
  const sessionToken = await mintSessionJWT(user, c.env, body.deviceId);
  return c.json({ sessionToken, user });
});

/**
 * Auth middleware for everything below.
 */
async function authMiddleware(c: any, next: any) {
  const auth = c.req.header("Authorization");
  const deviceId = c.req.header("X-Steer-Device-Id");
  const user = await extractAuthorizedUser(auth ?? null, deviceId ?? null, c.env);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  c.set("user", user);
  await next();
}

app.use("/v1/me", authMiddleware);
app.use("/v1/sync/*", authMiddleware);
app.use("/v1/stream", authMiddleware);

app.get("/v1/me", (c) => c.json({ user: c.get("user") }));

/**
 * DELETE /v1/me
 * Account deletion entry point for App Store compliance. Two phases:
 *   1. Revoke the user's Sign in with Apple grant on Apple's side
 *      (token revocation per guideline 5.1.1). Best-effort; if it
 *      fails we log and continue.
 *   2. Remove the relay account row and all user-owned sync data
 *      from D1.
 */
app.delete("/v1/me", async (c) => {
  const userId = c.get("user").userId;
  const store = new Store(c.env);
  const authCode = await store.getAppleAuthCode(userId);
  let appleRevoked = false;
  if (authCode) {
    appleRevoked = await revokeAppleAuthGrant(authCode, c.env);
  }
  await store.deleteUserData(userId);
  return c.json({ ok: true, appleRevoked });
});

/**
 * GET /v1/sync/cards?since=<ms>
 * Returns active cards updated after the cursor. iPhone polls or
 * uses the WebSocket stream below.
 */
app.get("/v1/sync/cards", async (c) => {
  const store = new Store(c.env);
  const since = Number(c.req.query("since") ?? "0") || 0;
  const cards = await store.listActiveCards(c.get("user").userId, since);
  return c.json({ cards });
});

/**
 * PUT /v1/sync/cards/:cardId
 * Mac publishes a card. We persist it and broadcast to the user's
 * UserHub so any connected WebSocket client (iPhone) sees it.
 */
app.put("/v1/sync/cards/:cardId", async (c) => {
  const cardId = c.req.param("cardId");
  const body = await c.req.json<CardPayload>();
  if (body.cardId !== cardId) {
    return c.json({ error: "cardId mismatch" }, 400);
  }
  const userId = c.get("user").userId;
  const store = new Store(c.env);
  const { inserted, changed } = await store.upsertCard(userId, body);

  // v3 dual-write — emit a card.upsert event for every meaningful
  // change. PR 1 only writes; no consumer yet. We dedupe on
  // (producerDeviceId, "card.upsert:<cardId>:<updatedAt>") so a
  // retried PUT for the SAME logical version is idempotent, while
  // a PUT for the same cardId with a newer updatedAt is a new
  // event. Skipping the write when `changed === false` matches the
  // legacy "no broadcast on no-op publish" rule and keeps the event
  // log clean.
  if (changed) {
    await appendEventDualWrite(
      store,
      userId,
      "card.upsert",
      body as unknown as Record<string, unknown>,
      producerDeviceId(c),
      `card.upsert:${body.cardId}:${body.updatedAt}`
    );
  }

  // Only fan out the WS broadcast when something actually changed.
  // Mac re-publishes every active card on its 2s reload tick; the
  // store dedupe above turns those no-op publishes into a silent
  // touch of updated_at, so iPhones don't see a stream of identical
  // upserts (which is what makes the carousel jitter). Defense in
  // depth — Mac also dedupes client-side, but a single source of
  // truth at the relay protects against future drift.
  if (changed) {
    await broadcast(c.env, userId, { type: "card.upsert", card: body });
  }

  // Fan out APNS push only on FIRST insert of a given cardId. Mac
  // re-publishes every active card every reload tick (~2s); without
  // this guard each tick would re-pump a notification and the user's
  // lock screen fills up in seconds. WebSocket broadcast above is
  // separately the live-state path and stays per-tick.
  if (
    inserted &&
    body.state === "active" &&
    ["blocker", "decision", "question", "waiting"].includes(body.category)
  ) {
    // c.executionCtx throws under the in-process test runtime; in
    // production it returns a real ExecutionContext. Use a try/catch
    // so the fanout still fires either way (just without
    // waitUntil's grace window in tests).
    const promise = fanoutPush(c.env, userId, body).catch(() => {});
    try {
      c.executionCtx.waitUntil(promise);
    } catch {
      // ignore — promise still runs to completion in the test loop
    }
  }
  return c.json({ ok: true });
});

async function fanoutPush(env: Env, userId: string, card: CardPayload): Promise<void> {
  try {
    const store = new Store(env);
    // Devices that haven't heartbeated in 24h get garbage-collected
    // before we read the list. Uninstalled apps stop heartbeating
    // immediately, so this catches dead rows long before APNS
    // returns 410 for them — and stops them from contributing to
    // TooManyProviderTokenUpdates 429s on every fanout.
    const pruned = await store.pruneStaleDevices(userId, 24 * 60 * 60 * 1000);
    if (pruned > 0) {
      console.log(`[apns] pruned ${pruned} stale device rows for user=${userId}`);
    }
    const devices = await store.listDevices(userId);
    const targets = devices.filter(
      (d) => d.platform === "ios" && d.apnsToken && d.syncEnabled
    );
    console.log(
      `[apns] fanout card=${card.cardId} user=${userId} total_devices=${devices.length} targets=${targets.length}`
    );
    if (targets.length === 0) return;
    const title = card.title || "Steer";
    const bodyText = card.summary || card.actionPrompt || "";
    // Map the card's provider (set by SteerCardMapping on Mac) to the
    // asset name the iOS NSE will look up in its bundle. We deliberately
    // skip unknown providers so an older Mac with a new provider name
    // doesn't ship a broken cardIcon hint. Falls through to "no icon"
    // and the system shows the default app glyph.
    const provider =
      typeof card.payload?.provider === "string"
        ? card.payload.provider.toLowerCase()
        : undefined;
    const cardIcon =
      provider === "claude" ? "claude" :
      provider === "codex"  ? "codex-color" :
      undefined;
    const results = await Promise.all(
      targets.map(async (d) => {
        try {
          const r = await sendAPNSPush(env, {
            deviceToken: d.apnsToken!,
            title,
            body: bodyText,
            cardIcon,
            apsEnvironment: d.apsEnvironment,
            customPayload: { cardId: card.cardId, sessionId: card.sessionId },
          });
          console.log(
            `[apns] sent device=${d.deviceId.slice(0, 8)} ok=${r.ok} status=${r.status}${r.reason ? ` reason=${r.reason}` : ""}`
          );
          // 410 Unregistered: Apple confirms the token is dead.
          // Drop the row so future fanouts don't waste a JWT slot on
          // it. We match by apnsToken (not deviceId) because the
          // same physical device can have multiple device_id rows
          // if it was reinstalled with a new device_id but the same
          // token survived (or vice versa).
          if (r.status === 410) {
            await store.deleteDeviceByApnsToken(userId, d.apnsToken!);
            console.log(`[apns] dropped dead token device=${d.deviceId.slice(0, 8)}`);
          }
          return r;
        } catch (e) {
          console.warn(`[apns] push failed for ${d.deviceId}: ${e}`);
          return null;
        }
      })
    );
    void results;
  } catch (e) {
    console.warn(`[apns] fanout error: ${e}`);
  }
}

/**
 * DELETE /v1/sync/cards/:cardId
 * Resolve (mark done). Triggers a card.resolved fanout.
 */
app.delete("/v1/sync/cards/:cardId", async (c) => {
  const cardId = c.req.param("cardId");
  const userId = c.get("user").userId;
  const store = new Store(c.env);
  await store.resolveCard(userId, cardId);
  // v3 dual-write: card.resolved event. Idempotency key is just the
  // cardId — resolving the same card twice is a no-op, so the event
  // log only captures the first resolve.
  await appendEventDualWrite(
    store,
    userId,
    "card.resolved",
    { cardId },
    producerDeviceId(c),
    `card.resolved:${cardId}`
  );
  await broadcast(c.env, userId, { type: "card.resolved", cardId });
  return c.json({ ok: true });
});

/**
 * POST /v1/sync/instructions
 * iPhone enqueues a reply. The Mac picks it up via /v1/sync/
 * instructions/queued or via the WebSocket fanout below.
 */
app.post("/v1/sync/instructions", async (c) => {
  const body = await c.req.json<InstructionRequest>();
  const store = new Store(c.env);
  const userId = c.get("user").userId;
  // Security: only let the user enqueue instructions for sessions
  // they actually own (a session is owned if it has a card or a
  // session row under their user_id). Without this check anyone with
  // a valid JWT could push instructions into another user's Mac
  // session by guessing a session_id.
  const ownsSession = await store.userOwnsSession(userId, body.targetSessionId);
  if (!ownsSession) {
    return c.json({ error: "session not found for this user" }, 403);
  }
  const record = await store.enqueueInstruction(
    userId,
    body.instructionId,
    body.targetSessionId,
    body.text
  );
  // v3 dual-write: instruction.queued event. Idempotency key is
  // the instructionId itself — POSTing the same instructionId twice
  // (network retry) returns the same event id and inserts nothing.
  await appendEventDualWrite(
    store,
    userId,
    "instruction.queued",
    record as unknown as Record<string, unknown>,
    producerDeviceId(c),
    `instruction.queued:${record.instructionId}`
  );
  await broadcast(c.env, userId, {
    type: "instruction.queued",
    instruction: record,
  });
  return c.json({ ok: true, instruction: record });
});

app.get("/v1/sync/instructions/queued", async (c) => {
  const store = new Store(c.env);
  const instructions = await store.listQueuedInstructions(c.get("user").userId);
  return c.json({ instructions });
});

/**
 * POST /v1/sync/instructions/:id/status
 * Mac reports back what happened to a queued instruction.
 */
app.post("/v1/sync/instructions/:id/status", async (c) => {
  const id = c.req.param("id");
  const body = await c.req.json<{ status: "injected" | "failed"; failureReason?: string }>();
  const userId = c.get("user").userId;
  const store = new Store(c.env);
  await store.markInstructionStatus(
    userId,
    id,
    body.status,
    body.failureReason
  );
  // v3 dual-write: instruction.injected event. Payload carries the
  // final status so consumers don't need a separate "failed" type.
  // Idempotency key combines instructionId + status so a duplicate
  // POST of the same status is a no-op, while a transition
  // (e.g. injected → failed later) does record both events.
  await appendEventDualWrite(
    store,
    userId,
    "instruction.injected",
    {
      instructionId: id,
      status: body.status,
      failureReason: body.failureReason,
    },
    producerDeviceId(c),
    `instruction.injected:${id}:${body.status}`
  );
  await broadcast(c.env, userId, {
    type: "instruction.status",
    instructionId: id,
    status: body.status,
    failureReason: body.failureReason,
  });
  return c.json({ ok: true });
});

/**
 * POST /v1/sync/sessions
 * Mac heartbeats live session metadata so iPhone can label cards
 * with which project/branch they came from.
 */
app.post("/v1/sync/sessions", async (c) => {
  const body = await c.req.json<SessionSnapshot>();
  const userId = c.get("user").userId;
  const store = new Store(c.env);
  await store.upsertSession(userId, body);
  // v3 dual-write: session.upsert event. Idempotency key is
  // (sessionId, runState, lastActivityAt) — any of those three
  // changing produces a new event, repeating the exact same state
  // is a no-op. Without the lastActivityAt component, the Mac's
  // periodic chip republish (same sessionId+runState every reload
  // tick when nothing changed) would still create a new event row
  // every tick.
  await appendEventDualWrite(
    store,
    userId,
    "session.upsert",
    body as unknown as Record<string, unknown>,
    producerDeviceId(c),
    `session.upsert:${body.sessionId}:${body.runState}:${body.lastActivityAt}`
  );
  return c.json({ ok: true });
});

/**
 * GET /v1/sync/sessions
 * iPhone reads this to render the live-session badge (e.g. "1
 * running") next to the Mac chip. Only running / waiting / blocked
 * sessions from the last 5 minutes are returned.
 */
app.get("/v1/sync/sessions", async (c) => {
  const store = new Store(c.env);
  const sessions = await store.listLiveSessions(c.get("user").userId);
  return c.json({ sessions });
});

/**
 * GET /v1/sync/presence
 * Combined { devices, sessions } so iOS DevicePresenceObserver
 * doesn't have to make two requests every poll. Phase A1 of
 * docs/SYNC_STABILITY_AND_COST_PLAN.md. Keeps the legacy single
 * endpoints around so older iOS builds still work.
 */
app.get("/v1/sync/presence", async (c) => {
  const store = new Store(c.env);
  const userId = c.get("user").userId;
  const [devices, sessions] = await Promise.all([
    store.listDevices(userId),
    store.listLiveSessions(userId),
  ]);
  return c.json({ devices, sessions });
});

/**
 * POST /v1/sync/devices
 * Device heartbeat. Mac calls every ~60s while iPhone Sync is on,
 * iPhone calls on launch + foreground. Body is a DeviceSnapshot.
 */
app.post("/v1/sync/devices", async (c) => {
  const body = await c.req.json<DeviceSnapshot>();
  if (!body.deviceId || !body.platform) {
    return c.json({ error: "missing deviceId or platform" }, 400);
  }
  const userId = c.get("user").userId;
  const store = new Store(c.env);
  const lastSeenAt = body.lastSeenAt || Date.now();
  await store.upsertDevice(userId, {
    ...body,
    lastSeenAt,
  });
  // v3 dual-write: device.heartbeat event. iOS uses this in v3 to
  // derive the Mac connection chip without a separate
  // GET /v1/sync/presence poll. Idempotency keys off
  // (deviceId, lastSeenAt) so the every-5-min heartbeat doesn't
  // dedupe against itself but a retried POST of the same heartbeat
  // does.
  await appendEventDualWrite(
    store,
    userId,
    "device.heartbeat",
    {
      deviceId: body.deviceId,
      platform: body.platform,
      lastSeenAt,
    },
    producerDeviceId(c),
    `device.heartbeat:${body.deviceId}:${lastSeenAt}`
  );
  return c.json({ ok: true });
});

/**
 * GET /v1/sync/devices
 * iPhone reads this to render the Mac connection chip and "Mac Sync
 * Status" sheet. Returns the user's full device list, sorted newest
 * lastSeenAt first.
 */
app.get("/v1/sync/devices", async (c) => {
  const store = new Store(c.env);
  const devices = await store.listDevices(c.get("user").userId);
  return c.json({ devices });
});

/**
 * DELETE /v1/sync/devices/:deviceId
 * Drop a single device row. Called by the iOS app from signOut()
 * so the user's current device stops receiving APNS pushes the
 * moment they sign out (and stops accumulating on the relay across
 * sign-in/sign-out cycles). Phase B3 of
 * docs/SYNC_STABILITY_AND_COST_PLAN.md.
 */
app.delete("/v1/sync/devices/:deviceId", async (c) => {
  const deviceId = c.req.param("deviceId");
  const store = new Store(c.env);
  await store.deleteDeviceById(c.get("user").userId, deviceId);
  return c.json({ ok: true });
});

// ──────────────────────────────────────────────────────────────────────
// v3 event log endpoints (PR 1).
//
// Read endpoints are wired up but no client consumes them yet — Mac
// and iOS will switch over in PR 2 and PR 3. The POST endpoint is
// the producer side: PR 2 lets Mac write events directly instead of
// the legacy PUT /cards / POST /sessions / etc routes. For now,
// dual-write (above) emits the same events from the legacy paths.
// ──────────────────────────────────────────────────────────────────────

/**
 * POST /v1/sync/events
 *
 * Direct producer entry point for v3. Body is a `SyncEventInput`.
 * Returns the persisted `SyncEvent` (with server-assigned id +
 * createdAt). Idempotent on `(producerDeviceId, clientUuid)`.
 *
 * For now this is exercised only by tests. PR 2 routes Mac writes
 * here; PR 3 routes iPhone reply writes here.
 */
app.post("/v1/sync/events", async (c) => {
  const body = await c.req.json<Partial<SyncEventInput>>();
  if (!body.type) {
    return c.json({ error: "missing type" }, 400);
  }
  const allowedTypes: SyncEventType[] = [
    "session.upsert",
    "session.remove",
    "card.upsert",
    "card.resolved",
    "instruction.queued",
    "instruction.injected",
    "device.heartbeat",
  ];
  if (!allowedTypes.includes(body.type as SyncEventType)) {
    return c.json({ error: `unknown event type: ${body.type}` }, 400);
  }
  const userId = c.get("user").userId;
  const store = new Store(c.env);
  const event = await store.appendEvent(userId, {
    type: body.type as SyncEventType,
    payload: body.payload ?? {},
    producerDeviceId: body.producerDeviceId ?? producerDeviceId(c),
    clientUuid: body.clientUuid,
  });
  return c.json({ event });
});

/**
 * GET /v1/sync/events?since=<cursor>&limit=<n>
 *
 * Catch-up replay. Returns events for the authenticated user with
 * id > `since`, ascending, capped at `limit` (1..500, default 500).
 * Empty array means the consumer is caught up.
 */
app.get("/v1/sync/events", async (c) => {
  const since = Number.parseInt(c.req.query("since") ?? "0", 10);
  const limit = Number.parseInt(c.req.query("limit") ?? "500", 10);
  if (!Number.isFinite(since) || since < 0) {
    return c.json({ error: "since must be a non-negative integer" }, 400);
  }
  const store = new Store(c.env);
  const events = await store.eventsSince(c.get("user").userId, since, limit);
  return c.json({ events });
});

/**
 * GET /v1/sync/snapshot
 *
 * One-shot starting point for cold launches + post-reconnect rebase.
 * Returns the current cursor (`MAX(events.id)`) plus the derived
 * state of cards / live sessions / queued instructions. Consumer
 * applies the snapshot then resumes from `?since=cursor` on the
 * events endpoint.
 *
 * Snapshot vs cursor race: if an event lands between the cursor
 * read and the data fetch, that event will appear BOTH in the
 * snapshot AND in the consumer's next /events fetch. That's fine —
 * consumers apply by event id and idempotently re-apply the same
 * id is a no-op.
 */
app.get("/v1/sync/snapshot", async (c) => {
  const store = new Store(c.env);
  const snapshot = await store.computeSnapshot(c.get("user").userId);
  return c.json(snapshot);
});

/**
 * GET /v1/stream
 * WebSocket entry point. Routed straight to the user's UserHub DO.
 *
 * Authorization: Bearer <session-jwt> via header — we already
 * resolved the user above.
 */
app.get("/v1/stream", async (c) => {
  const userId = c.get("user").userId;
  const id = c.env.USER_HUB.idFromName(userId);
  const stub = c.env.USER_HUB.get(id);
  return stub.fetch(new URL("/connect", c.req.url).toString(), {
    headers: c.req.raw.headers,
  });
});

async function broadcast(env: Env, userId: string, message: WSMessage) {
  try {
    const id = env.USER_HUB.idFromName(userId);
    const stub = env.USER_HUB.get(id);
    await stub.fetch("https://internal/broadcast", {
      method: "POST",
      body: JSON.stringify(message),
      headers: { "Content-Type": "application/json" },
    });
  } catch {
    // Broadcast failure is non-fatal; the persisted row is the
    // source of truth and clients reconcile on reconnect.
  }
}

export default app;
