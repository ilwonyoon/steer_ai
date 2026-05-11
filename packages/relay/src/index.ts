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
  WSMessage,
} from "./types.js";

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
  const store = new Store(c.env);
  await store.resolveCard(c.get("user").userId, cardId);
  await broadcast(c.env, c.get("user").userId, { type: "card.resolved", cardId });
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
  await broadcast(c.env, c.get("user").userId, {
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
  const store = new Store(c.env);
  await store.markInstructionStatus(
    c.get("user").userId,
    id,
    body.status,
    body.failureReason
  );
  await broadcast(c.env, c.get("user").userId, {
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
  const store = new Store(c.env);
  await store.upsertSession(c.get("user").userId, body);
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
 * POST /v1/sync/devices
 * Device heartbeat. Mac calls every ~60s while iPhone Sync is on,
 * iPhone calls on launch + foreground. Body is a DeviceSnapshot.
 */
app.post("/v1/sync/devices", async (c) => {
  const body = await c.req.json<DeviceSnapshot>();
  if (!body.deviceId || !body.platform) {
    return c.json({ error: "missing deviceId or platform" }, 400);
  }
  const store = new Store(c.env);
  await store.upsertDevice(c.get("user").userId, {
    ...body,
    lastSeenAt: body.lastSeenAt || Date.now(),
  });
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
