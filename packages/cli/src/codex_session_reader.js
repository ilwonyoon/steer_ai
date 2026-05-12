import fs from "node:fs";
import path from "node:path";
import os from "node:os";

// Default to ~/.codex/sessions; overridable for tests (and the
// occasional debug-against-fixture session) via env.
const CODEX_SESSIONS_DIR =
  process.env.STEER_CODEX_SESSIONS_DIR ??
  path.join(os.homedir(), ".codex", "sessions");
const POLL_INTERVAL_MS = 250;
const DISCOVERY_TIMEOUT_MS = 15_000;
const DEBUG_LOG = process.env.STEER_READER_DEBUG_LOG;

function debug(...args) {
  if (!DEBUG_LOG) return;
  try {
    fs.appendFileSync(
      DEBUG_LOG,
      `[${new Date().toISOString()}] ${args.map((a) => typeof a === "string" ? a : JSON.stringify(a)).join(" ")}\n`
    );
  } catch {}
}

export function startCodexSessionReader({ spawnedAt, onAgentMessage, onError }) {
  debug("startCodexSessionReader", { spawnedAt: spawnedAt.toISOString(), pid: process.pid });
  let cancelled = false;
  let watchedFile = null;
  let readOffset = 0;
  let buffer = "";
  let pollTimer = null;
  const seenAgentMessages = new Set();

  const stop = () => {
    cancelled = true;
    if (pollTimer) {
      clearTimeout(pollTimer);
      pollTimer = null;
    }
  };

  const scheduleNextPoll = (delay = POLL_INTERVAL_MS) => {
    if (cancelled) return;
    pollTimer = setTimeout(tick, delay);
    pollTimer.unref?.();
  };

  // Whether we've already surfaced the "log not found yet"
  // warning. We still keep polling past the discovery timeout
  // because codex sometimes defers jsonl creation past 15s
  // (slow disk, codex startup-time, the user reattaching to a
  // wrapper that just finished its CLI boot). The fix for the
  // 2026-05-12 dogfood regression: the previous code did
  // `return;` here, killing the reader permanently — when the
  // jsonl finally landed there was nothing left to read it.
  let discoveryWarningEmitted = false;

  const tick = async () => {
    if (cancelled) return;
    try {
      if (!watchedFile) {
        const candidate = await findNewestSessionFile(spawnedAt);
        if (candidate) {
          watchedFile = candidate;
          debug("watchedFile set", { file: watchedFile, spawnedAt: spawnedAt.toISOString() });
        } else if (
          !discoveryWarningEmitted &&
          Date.now() - spawnedAt.getTime() > DISCOVERY_TIMEOUT_MS
        ) {
          debug("discovery timeout (continuing to poll)", { spawnedAt: spawnedAt.toISOString() });
          discoveryWarningEmitted = true;
          onError?.(
            new Error(
              "codex session log not found within 15s — continuing to poll"
            )
          );
        }
      }

      if (watchedFile) {
        await readTail(watchedFile);
      }
    } catch (error) {
      debug("tick error", { message: error.message });
      onError?.(error);
    }

    scheduleNextPoll();
  };

  async function readTail(filePath) {
    const stat = await fs.promises.stat(filePath).catch(() => null);
    if (!stat || stat.size <= readOffset) return;

    const stream = fs.createReadStream(filePath, {
      start: readOffset,
      end: stat.size - 1
    });

    for await (const chunk of stream) {
      buffer += chunk.toString("utf8");
    }
    readOffset = stat.size;

    let newlineIndex;
    while ((newlineIndex = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newlineIndex);
      buffer = buffer.slice(newlineIndex + 1);
      handleLine(line);
    }
  }

  function handleLine(line) {
    const trimmed = line.trim();
    if (!trimmed) return;

    let event;
    try {
      event = JSON.parse(trimmed);
    } catch {
      return;
    }

    const message = extractFinalAgentMessage(event);
    if (!message) {
      debug("line ignored", { type: event?.type, payloadType: event?.payload?.type, phase: event?.payload?.phase });
      return;
    }

    const fingerprint = `${event.timestamp ?? ""}:${message.length}`;
    if (seenAgentMessages.has(fingerprint)) return;
    seenAgentMessages.add(fingerprint);

    debug("emit message", { length: message.length, fingerprint });
    onAgentMessage?.(message);
  }

  scheduleNextPoll(0);
  return { stop };
}

export function extractFinalAgentMessage(event) {
  if (!event || typeof event !== "object") return null;
  if (event.type !== "event_msg") return null;
  const payload = event.payload;
  if (!payload || typeof payload !== "object") return null;
  if (payload.type !== "agent_message") return null;
  if (payload.phase !== "final_answer") return null;
  const message = payload.message;
  if (typeof message !== "string") return null;
  const trimmed = message.trim();
  return trimmed.length > 0 ? trimmed : null;
}

const SPAWN_WINDOW_MS = 30_000;

async function findNewestSessionFile(spawnedAt) {
  if (!fs.existsSync(CODEX_SESSIONS_DIR)) return null;

  const spawnedMs = spawnedAt.getTime();
  let bestFile = null;
  let bestStartedDelta = Number.POSITIVE_INFINITY;

  const visit = async (dir) => {
    let entries;
    try {
      entries = await fs.promises.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await visit(full);
        continue;
      }
      if (!entry.isFile()) continue;
      if (!entry.name.endsWith(".jsonl")) continue;

      const startedAt = parseRolloutStartedAt(entry.name);
      if (startedAt === null) continue;

      const delta = startedAt - spawnedMs;
      if (delta < -2_000) continue;
      if (delta > SPAWN_WINDOW_MS) continue;
      if (Math.abs(delta) >= Math.abs(bestStartedDelta)) continue;

      bestStartedDelta = delta;
      bestFile = full;
    }
  };

  await visit(CODEX_SESSIONS_DIR);
  return bestFile;
}

export function parseRolloutStartedAt(filename) {
  const match = filename.match(/^rollout-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})/);
  if (!match) return null;
  const [, year, month, day, hour, minute, second] = match;
  const date = new Date(
    Number(year),
    Number(month) - 1,
    Number(day),
    Number(hour),
    Number(minute),
    Number(second)
  );
  const time = date.getTime();
  return Number.isFinite(time) ? time : null;
}
