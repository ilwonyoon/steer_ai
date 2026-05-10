/**
 * Shared types between the worker and the Hono routes. The wire
 * shape is duplicated in Swift (SteerCore) — keep them in sync.
 */

export interface Env {
  DB: D1Database;
  USER_HUB: DurableObjectNamespace;
  APPLE_JWKS_URL: string;
  APPLE_AUDIENCES: string; // comma-separated
  APPLE_ISSUER: string;
  SESSION_JWT_SECRET: string; // wrangler secret
}

export interface SessionUser {
  userId: string;
  appleEmail?: string;
  displayName?: string;
}

export interface CardPayload {
  cardId: string;
  sessionId: string;
  category: string;
  priority: string;
  title: string;
  summary: string;
  actionPrompt?: string;
  payload?: Record<string, unknown>;
  state: "active" | "done";
  createdAt: number; // ms epoch
  updatedAt: number;
}

export interface InstructionRequest {
  instructionId: string;
  targetSessionId: string;
  text: string;
}

export interface InstructionRecord extends InstructionRequest {
  status: "queued" | "injected" | "failed";
  createdAt: number;
  injectedAt?: number;
  failureReason?: string;
}

export interface SessionSnapshot {
  sessionId: string;
  provider: string;
  projectName?: string;
  branchLabel?: string;
  runState: string;
  lastActivityAt: number;
}

export interface DeviceSnapshot {
  deviceId: string;
  platform: string;            // "mac" | "ios"
  displayName?: string;
  deviceClass?: string;
  appVersion?: string;
  syncEnabled: boolean;
  lastSeenAt: number;          // ms epoch
  apnsToken?: string;          // hex-encoded; only iOS sends this
}

export type WSMessage =
  | { type: "card.upsert"; card: CardPayload }
  | { type: "card.resolved"; cardId: string }
  | { type: "instruction.queued"; instruction: InstructionRecord }
  | { type: "instruction.status"; instructionId: string; status: string; failureReason?: string }
  | { type: "ping" }
  | { type: "pong" };
