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

// ────────────────────────────────────────────────────────────────────────
// Sync v3 event log
//
// See docs/SYNC_ARCHITECTURE_V3.md "Event taxonomy". PR 1 introduces
// the table + dual-write; clients don't consume these yet. Type
// vocabulary is enforced here so route handlers can pattern-match.
// ────────────────────────────────────────────────────────────────────────

export type SyncEventType =
  | "session.upsert"
  | "session.remove"
  | "card.upsert"
  | "card.resolved"
  | "instruction.queued"
  | "instruction.injected"
  | "device.heartbeat";

/** Stored event row, returned by GET /v1/sync/events. */
export interface SyncEvent {
  id: number;
  type: SyncEventType;
  payload: Record<string, unknown>;
  createdAt: number;
  producerDeviceId: string;
  clientUuid?: string;
}

/** Body shape for POST /v1/sync/events. */
export interface SyncEventInput {
  type: SyncEventType;
  payload: Record<string, unknown>;
  producerDeviceId: string;
  /**
   * Idempotency key. If a previous POST with the same
   * (producerDeviceId, clientUuid) succeeded, this call returns the
   * original event id and inserts nothing. Optional — events the
   * relay synthesizes itself can omit it (none today).
   */
  clientUuid?: string;
}

/**
 * GET /v1/sync/snapshot response. Lets a freshly-launched or
 * long-backgrounded client rebase its state without replaying from
 * id=0. `cursor` is `MAX(events.id)` *at the moment the snapshot
 * was computed*; everything above it the client picks up via
 * subsequent /v1/sync/events?since=cursor calls.
 */
export interface SyncSnapshot {
  cursor: number;
  activeCards: CardPayload[];
  liveSessions: SessionSnapshot[];
  queuedInstructions: InstructionRecord[];
}
