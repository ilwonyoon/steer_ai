import { createRemoteJWKSet, jwtVerify, SignJWT } from "jose";
import type { Env, SessionUser } from "./types.js";

/**
 * Sign in with Apple verification. The Mac and iOS apps run
 * `ASAuthorizationAppleIDProvider`, get back an `identityToken` (a
 * JWT), and POST it to /v1/auth/apple. We verify it against Apple's
 * JWKS endpoint and mint our own short-lived session JWT for
 * subsequent calls.
 *
 * Apple's identity token claims (the ones we care about):
 *   iss = https://appleid.apple.com
 *   aud = our bundle id (ai.steer.mac or ai.steer.ios)
 *   sub = stable user id (this is what becomes our user_id)
 *   email = relay or real
 */

const cachedJwks = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

function jwksFor(env: Env) {
  const cached = cachedJwks.get(env.APPLE_JWKS_URL);
  if (cached) return cached;
  const fresh = createRemoteJWKSet(new URL(env.APPLE_JWKS_URL));
  cachedJwks.set(env.APPLE_JWKS_URL, fresh);
  return fresh;
}

export interface AppleIdentity {
  sub: string;       // stable user id
  email?: string;
  emailVerified?: boolean;
  isPrivateEmail?: boolean;
  audience: string;  // which bundle id signed in
}

export async function verifyAppleIdentityToken(
  token: string,
  env: Env
): Promise<AppleIdentity> {
  const audiences = env.APPLE_AUDIENCES.split(",").map(s => s.trim());
  const { payload } = await jwtVerify(token, jwksFor(env), {
    issuer: env.APPLE_ISSUER,
    audience: audiences,
  });
  if (!payload.sub) throw new Error("Apple identity token missing sub");
  return {
    sub: payload.sub,
    email: typeof payload.email === "string" ? payload.email : undefined,
    emailVerified: payload.email_verified === true || payload.email_verified === "true",
    isPrivateEmail: payload.is_private_email === true || payload.is_private_email === "true",
    audience: typeof payload.aud === "string" ? payload.aud : audiences[0],
  };
}

/**
 * Mint our own session JWT after Apple validation. Lives ~30 days;
 * clients drop it in the Authorization header for every subsequent
 * REST/WebSocket request. We hand-roll claims so we're not bound to
 * Apple's token TTL (which is 10 minutes — too short for our flow).
 *
 * deviceId is bound into the `did` claim so a stolen token cannot
 * be replayed from a different device — the request handler also
 * checks the `X-Steer-Device-Id` header for equality.
 */
export async function mintSessionJWT(
  user: SessionUser,
  env: Env,
  deviceId?: string
): Promise<string> {
  const secret = new TextEncoder().encode(env.SESSION_JWT_SECRET);
  const now = Math.floor(Date.now() / 1000);
  const exp = now + 60 * 60 * 24 * 30; // 30 days
  const claims: Record<string, unknown> = {
    sub: user.userId,
    email: user.appleEmail,
    name: user.displayName,
  };
  if (deviceId) claims.did = deviceId;
  return await new SignJWT(claims)
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuedAt(now)
    .setExpirationTime(exp)
    .setIssuer("ai.steer.relay")
    .sign(secret);
}

export async function verifySessionJWT(token: string, env: Env): Promise<SessionUser & { deviceId?: string }> {
  const secret = new TextEncoder().encode(env.SESSION_JWT_SECRET);
  const { payload } = await jwtVerify(token, secret, {
    issuer: "ai.steer.relay",
  });
  if (!payload.sub) throw new Error("session token missing sub");
  return {
    userId: payload.sub,
    appleEmail: typeof payload.email === "string" ? payload.email : undefined,
    displayName: typeof payload.name === "string" ? payload.name : undefined,
    deviceId: typeof payload.did === "string" ? payload.did : undefined,
  };
}

/**
 * Revoke a user's Apple sign-in grant. Calls Apple's
 * https://appleid.apple.com/auth/revoke endpoint with our service's
 * client_id + a freshly-signed JWT client_secret + the user's most
 * recent authorization_code. Required by App Store guideline 5.1.1
 * for Sign in with Apple — when the user deletes their account the
 * server must tell Apple to drop the grant on Apple's side, not just
 * delete the local row.
 *
 * Returns true on success, false on any failure. Failure is logged
 * but doesn't block local deletion: relay-side data is removed
 * either way, so the worst case is that Apple retains the dormant
 * grant. The user can also revoke manually from iOS Settings.
 *
 * Required env (set via wrangler secret):
 *   APPLE_TEAM_ID            — 10-char Apple Developer team id
 *   APPLE_CLIENT_ID          — Services ID or app bundle id
 *   APPLE_KEY_ID             — 10-char key id for the AuthKey .p8
 *   APPLE_PRIVATE_KEY        — PKCS#8 PEM body of the AuthKey .p8
 *
 * If any are missing the function logs and returns false (so dev
 * environments without Apple credentials still let deletion proceed).
 */
export async function revokeAppleAuthGrant(
  authorizationCode: string,
  env: Env
): Promise<boolean> {
  const teamId = (env as any).APPLE_TEAM_ID as string | undefined;
  const clientId = (env as any).APPLE_CLIENT_ID as string | undefined;
  const keyId = (env as any).APPLE_KEY_ID as string | undefined;
  const privateKey = (env as any).APPLE_PRIVATE_KEY as string | undefined;
  if (!teamId || !clientId || !keyId || !privateKey) {
    console.warn("[apple-revoke] missing APPLE_* secrets; skipping revoke");
    return false;
  }
  try {
    const { SignJWT, importPKCS8 } = await import("jose");
    const key = await importPKCS8(privateKey, "ES256");
    const now = Math.floor(Date.now() / 1000);
    const clientSecret = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: keyId })
      .setIssuedAt(now)
      .setExpirationTime(now + 60 * 5)
      .setAudience("https://appleid.apple.com")
      .setIssuer(teamId)
      .setSubject(clientId)
      .sign(key);

    const body = new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      token: authorizationCode,
      token_type_hint: "authorization_code",
    });
    const res = await fetch("https://appleid.apple.com/auth/revoke", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    if (!res.ok) {
      console.warn(`[apple-revoke] Apple returned ${res.status}: ${await res.text()}`);
      return false;
    }
    return true;
  } catch (e) {
    console.warn("[apple-revoke] failed:", e);
    return false;
  }
}

/**
 * Hono middleware: pull Authorization: Bearer <jwt>, verify, attach
 * the user to context.
 *
 * If the JWT carries a `did` (device id) claim, the request must
 * also include the matching `X-Steer-Device-Id` header. Old tokens
 * without a `did` claim continue to work for the 30-day rollout
 * window — once those expire, every minted token carries `did` and
 * the header check is hard.
 */
export async function extractAuthorizedUser(
  authHeader: string | null,
  deviceIdHeader: string | null,
  env: Env
): Promise<SessionUser | null> {
  if (!authHeader) return null;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  try {
    const user = await verifySessionJWT(match[1], env);
    if (user.deviceId && user.deviceId !== deviceIdHeader) {
      return null;
    }
    return {
      userId: user.userId,
      appleEmail: user.appleEmail,
      displayName: user.displayName,
    };
  } catch {
    return null;
  }
}
