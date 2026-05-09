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
 */
export async function mintSessionJWT(user: SessionUser, env: Env): Promise<string> {
  const secret = new TextEncoder().encode(env.SESSION_JWT_SECRET);
  const now = Math.floor(Date.now() / 1000);
  const exp = now + 60 * 60 * 24 * 30; // 30 days
  return await new SignJWT({
    sub: user.userId,
    email: user.appleEmail,
    name: user.displayName,
  })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuedAt(now)
    .setExpirationTime(exp)
    .setIssuer("ai.steer.relay")
    .sign(secret);
}

export async function verifySessionJWT(token: string, env: Env): Promise<SessionUser> {
  const secret = new TextEncoder().encode(env.SESSION_JWT_SECRET);
  const { payload } = await jwtVerify(token, secret, {
    issuer: "ai.steer.relay",
  });
  if (!payload.sub) throw new Error("session token missing sub");
  return {
    userId: payload.sub,
    appleEmail: typeof payload.email === "string" ? payload.email : undefined,
    displayName: typeof payload.name === "string" ? payload.name : undefined,
  };
}

/**
 * Hono middleware: pull Authorization: Bearer <jwt>, verify, attach
 * the user to context.
 */
export async function extractAuthorizedUser(
  authHeader: string | null,
  env: Env
): Promise<SessionUser | null> {
  if (!authHeader) return null;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  try {
    return await verifySessionJWT(match[1], env);
  } catch {
    return null;
  }
}
