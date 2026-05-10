// JWT device binding contract:
//
// - A token minted WITHOUT a `did` claim continues to work no matter
//   what `X-Steer-Device-Id` header arrives (or none at all). This
//   preserves backward compatibility during the rollout window —
//   existing clients with unbound tokens don't get logged out.
// - A token minted WITH a `did` claim must arrive with the matching
//   `X-Steer-Device-Id` header. Anything else (missing header, wrong
//   header, empty header) is rejected with 401.
//
// The threat model: an attacker who steals a JWT from one device
// can't replay it from another device without also knowing the
// per-device id we baked into the claim.

import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { SignJWT } from "jose";
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

async function mintToken(userId: string, deviceId?: string): Promise<string> {
  const secret = new TextEncoder().encode(env.SESSION_JWT_SECRET as string);
  const claims: Record<string, unknown> = { sub: userId };
  if (deviceId) claims.did = deviceId;
  return await new SignJWT(claims)
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

describe("JWT device binding", () => {
  it("[backward-compat] token without did claim is accepted regardless of header", async () => {
    const userId = "u-legacy";
    await bootstrapUser(userId);
    const token = await mintToken(userId);  // no deviceId

    // No header: accepted.
    let res = await worker.request("/v1/me", {
      headers: { Authorization: `Bearer ${token}` },
    }, env);
    expect(res.status).toBe(200);

    // Random header: still accepted because the token isn't bound.
    res = await worker.request("/v1/me", {
      headers: {
        Authorization: `Bearer ${token}`,
        "X-Steer-Device-Id": "some-random-device",
      },
    }, env);
    expect(res.status).toBe(200);
  });

  it("[bound] matching X-Steer-Device-Id is accepted", async () => {
    const userId = "u-bound-ok";
    await bootstrapUser(userId);
    const deviceId = "iphone-15-pro-abc123";
    const token = await mintToken(userId, deviceId);

    const res = await worker.request("/v1/me", {
      headers: {
        Authorization: `Bearer ${token}`,
        "X-Steer-Device-Id": deviceId,
      },
    }, env);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { user: { userId: string } };
    expect(body.user.userId).toBe(userId);
  });

  it("[bound] missing X-Steer-Device-Id is rejected", async () => {
    const userId = "u-bound-missing";
    await bootstrapUser(userId);
    const token = await mintToken(userId, "iphone-15-pro-xyz");

    const res = await worker.request("/v1/me", {
      headers: { Authorization: `Bearer ${token}` },
    }, env);
    expect(res.status).toBe(401);
  });

  it("[bound] mismatched X-Steer-Device-Id is rejected (token replay from another device)", async () => {
    const userId = "u-bound-mismatch";
    await bootstrapUser(userId);
    const token = await mintToken(userId, "iphone-original");

    const res = await worker.request("/v1/me", {
      headers: {
        Authorization: `Bearer ${token}`,
        "X-Steer-Device-Id": "attacker-iphone",
      },
    }, env);
    expect(res.status).toBe(401);
  });
});
