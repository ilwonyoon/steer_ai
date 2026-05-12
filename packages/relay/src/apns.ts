// APNS HTTP/2 push from Cloudflare Workers.
//
// We can't use a long-lived TLS connection here — Workers re-spawn
// per request — but Apple's HTTP/2 endpoint at api.push.apple.com
// also accepts one-shot HTTPS requests with the JWT in the
// authorization header. fetch() is good enough.
//
// JWT auth: per Apple, the bearer token is an ES256-signed JWT with
//   header: { alg: "ES256", kid: <APNS_KEY_ID> }
//   payload: { iss: <APPLE_TEAM_ID>, iat: <unix-seconds> }
// Tokens are valid up to 60 minutes; we cache one in module scope to
// avoid re-signing on every push (signing is the expensive part).
//
// Required env (via wrangler secret):
//   APNS_KEY_ID         10-char key id from the .p8 file
//   APNS_TEAM_ID        10-char team id (same as APPLE_TEAM_ID — we
//                       reuse it implicitly)
//   APNS_BUNDLE_ID      app's bundle id, e.g. ai.steer.ios
//   APNS_PRIVATE_KEY    PKCS#8 PEM body of the .p8 (multiline OK,
//                       wrangler secret put preserves newlines)
//   APNS_USE_SANDBOX    optional "1" to route through the sandbox
//                       endpoint api.sandbox.push.apple.com (used
//                       during development before TestFlight)

import type { Env } from "./types.js";

interface CachedToken {
  jwt: string;
  signedAtSec: number;
}

let cachedToken: CachedToken | null = null;

async function apnsBearer(env: Env): Promise<string | null> {
  const keyId = (env as any).APNS_KEY_ID as string | undefined;
  const teamId =
    ((env as any).APNS_TEAM_ID as string | undefined) ||
    ((env as any).APPLE_TEAM_ID as string | undefined);
  const privateKey = (env as any).APNS_PRIVATE_KEY as string | undefined;
  if (!keyId || !teamId || !privateKey) return null;

  const now = Math.floor(Date.now() / 1000);
  // Apple rejects tokens older than 60 minutes; rotate at 50.
  if (cachedToken && now - cachedToken.signedAtSec < 50 * 60) {
    return cachedToken.jwt;
  }

  const { SignJWT, importPKCS8 } = await import("jose");
  const key = await importPKCS8(privateKey, "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuedAt(now)
    .setIssuer(teamId)
    .sign(key);
  cachedToken = { jwt, signedAtSec: now };
  return jwt;
}

interface PushRequest {
  deviceToken: string;
  title: string;
  body: string;
  /// Optional opaque payload the iOS app can read on tap. We embed
  /// the cardId so the InboxView can deep-link to the relevant card.
  customPayload?: Record<string, unknown>;
  /// Provider identifier the iOS Notification Service Extension uses
  /// to look up a bundled provider icon (claude / codex-color) and
  /// attach it to the banner. Sending this also flips
  /// `mutable-content: 1` in the aps so APNS hands the payload to
  /// the NSE before delivery. Without an NSE on the receiving device
  /// the flag is silently ignored, so this change is safe to ship
  /// ahead of the NSE target.
  cardIcon?: string;
  /// Per-device APNS environment. "development" → sandbox endpoint;
  /// "production" → production endpoint; undefined → fall back to
  /// the env-wide APNS_USE_SANDBOX var so older device rows that
  /// pre-date this column still route to whatever the operator
  /// configured globally. Phase B2 of
  /// docs/SYNC_STABILITY_AND_COST_PLAN.md.
  apsEnvironment?: string;
}

export interface PushResult {
  ok: boolean;
  status: number;
  reason?: string;
}

/// Send a single APNS notification. Apple's HTTP/2 service is lenient
/// about per-request connections — the cost is wallclock latency
/// (~150ms in our region), which is fine since the iPhone client
/// also receives the WS card.upsert immediately.
export async function sendAPNSPush(env: Env, req: PushRequest): Promise<PushResult> {
  const bearer = await apnsBearer(env);
  if (!bearer) {
    return { ok: false, status: 0, reason: "APNS_KEY_ID/TEAM_ID/PRIVATE_KEY not configured" };
  }
  const bundleId =
    ((env as any).APNS_BUNDLE_ID as string | undefined) || "ai.steer.ios";
  // Per-device routing: if the device row told us its
  // aps-environment, honor it directly. Otherwise fall back to the
  // env-wide APNS_USE_SANDBOX flag for backward compatibility with
  // device rows that pre-date Phase B2.
  let useSandbox: boolean;
  if (req.apsEnvironment === "development") {
    useSandbox = true;
  } else if (req.apsEnvironment === "production") {
    useSandbox = false;
  } else {
    useSandbox = (env as any).APNS_USE_SANDBOX === "1";
  }
  const host = useSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const url = `https://${host}/3/device/${req.deviceToken}`;

  const aps: Record<string, unknown> = {
    alert: { title: req.title, body: req.body },
    sound: "default",
  };
  if (req.cardIcon) {
    // Tells APNS to hand the payload to the iOS NSE so it can swap in
    // the provider icon before display. Harmless when the NSE doesn't
    // exist — older clients just see the same banner without an icon.
    aps["mutable-content"] = 1;
  }
  const payload = {
    aps,
    ...(req.cardIcon ? { cardIcon: req.cardIcon } : {}),
    ...(req.customPayload ?? {}),
  };

  const res = await fetch(url, {
    method: "POST",
    headers: {
      authorization: `bearer ${bearer}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (res.ok) {
    return { ok: true, status: res.status };
  }
  // Apple returns a JSON error body on failure.
  let reason = "";
  try {
    const j = (await res.json()) as { reason?: string };
    reason = j.reason ?? "";
  } catch {
    // ignore
  }
  return { ok: false, status: res.status, reason };
}
