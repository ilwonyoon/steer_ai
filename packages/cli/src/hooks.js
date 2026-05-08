import fs from "node:fs";
import path from "node:path";

const CLAUDE_HOOK_COMMANDS = {
  Stop: "steer hook claude Stop",
  Notification: "steer hook claude Notification",
  StopFailure: "steer hook claude StopFailure",
  SessionEnd: "steer hook claude SessionEnd"
};

export function normalizeHookPayload(provider, eventName, payload = {}, env = process.env) {
  const normalizedProvider = provider || "custom";
  const hookEventName = eventName || payload.hook_event_name || payload.event || "unknown";
  const sessionId = env.STEER_SESSION_ID || payload.steer_session_id || payload.steerSessionId || null;

  return {
    provider: normalizedProvider,
    eventName: hookEventName,
    sessionId,
    providerSessionId: payload.session_id ?? payload.sessionId ?? null,
    cwd: payload.cwd ?? env.PWD ?? process.cwd(),
    transcriptPath: payload.transcript_path ?? payload.transcriptPath ?? null,
    lastAssistantMessage: payload.last_assistant_message ?? payload.lastAssistantMessage ?? null,
    message: payload.message ?? payload.notification ?? payload.reason ?? null,
    rawPayload: payload
  };
}

export function parseHookInput(rawInput) {
  const trimmed = rawInput.trim();
  if (!trimmed) return {};
  return JSON.parse(trimmed);
}

export function isClaudeHookInstalled({ cwd = process.cwd() } = {}) {
  const settingsPath = path.join(cwd, ".claude", "settings.local.json");
  if (!fs.existsSync(settingsPath)) return false;
  try {
    const settings = readJsonObject(settingsPath);
    const hooks = settings.hooks ?? {};
    return Object.keys(CLAUDE_HOOK_COMMANDS).every((event) => {
      const entry = hooks[event];
      if (!entry) return false;
      const flat = JSON.stringify(entry);
      return flat.includes("steer hook claude");
    });
  } catch {
    return false;
  }
}

export function installClaudeHooks({ cwd = process.cwd() } = {}) {
  const claudeDir = path.join(cwd, ".claude");
  const settingsPath = path.join(claudeDir, "settings.local.json");
  fs.mkdirSync(claudeDir, { recursive: true });

  const settings = readJsonObject(settingsPath);
  settings.hooks = mergeClaudeHooks(settings.hooks ?? {});

  fs.writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);
  return settingsPath;
}

function readJsonObject(filePath) {
  if (!fs.existsSync(filePath)) return {};

  const raw = fs.readFileSync(filePath, "utf8").trim();
  if (!raw) return {};

  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`${filePath} must contain a JSON object`);
  }
  return parsed;
}

function mergeClaudeHooks(existingHooks) {
  const hooks = { ...existingHooks };

  for (const [eventName, command] of Object.entries(CLAUDE_HOOK_COMMANDS)) {
    hooks[eventName] = mergeHookCommand(hooks[eventName], eventName, command);
  }

  return hooks;
}

function mergeHookCommand(existingMatchers, eventName, command) {
  const matchers = Array.isArray(existingMatchers) ? [...existingMatchers] : [];
  const matcher = matchers[0] && typeof matchers[0] === "object" ? { ...matchers[0] } : {};
  matcher.hooks = Array.isArray(matcher.hooks) ? [...matcher.hooks] : [];

  if (eventName !== "Stop" && matcher.matcher === undefined) {
    matcher.matcher = "*";
  }

  const alreadyInstalled = matcher.hooks.some((hook) => hook?.type === "command" && hook?.command === command);
  if (!alreadyInstalled) {
    matcher.hooks.push({
      type: "command",
      command,
      timeout: 5
    });
  }

  if (matchers.length === 0) return [matcher];
  matchers[0] = matcher;
  return matchers;
}
