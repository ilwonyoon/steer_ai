#!/usr/bin/env node
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import pty from "node-pty";
import { DatabaseSync } from "node:sqlite";
import { encodeMessage, createLineDecoder } from "../../agent/src/protocol.js";
import { socketPath, databasePath } from "../../agent/src/paths.js";
import { formatPtyInstructionInput } from "./pty_input.js";
import { extractPtyIdleReport } from "./pty_idle.js";
import { startCodexSessionReader } from "./codex_session_reader.js";
import { createAgentLink } from "./agent_link.js";
import { installClaudeHooks, isClaudeHookInstalled, normalizeHookPayload, parseHookInput } from "./hooks.js";
import { isCancelChunk } from "./cancel_keys.js";
import { formatInstructionWithAttachments } from "./attachments.js";

const [, , command, ...args] = process.argv;
const agentEntryPath = fileURLToPath(new URL("../../agent/src/agent.js", import.meta.url));

switch (command) {
  case "agent":
    await import("../../agent/src/agent.js");
    break;
  case "wrap":
    await wrapCommand(args);
    break;
  case "claude":
    await runClaudeAdapter(args);
    break;
  case "codex":
    await runCodexAdapter(args);
    break;
  case "send":
    await sendInstruction(args);
    break;
  case "hook":
    await reportHookEvent(args);
    break;
  case "install-claude-hooks":
    await installClaudeHooksCommand();
    break;
  case "sessions":
    await listSessions();
    break;
  case "stats":
    await printStats();
    break;
  default:
    printUsage();
    process.exit(command ? 1 : 0);
}

async function wrapCommand(args) {
  const separatorIndex = args.indexOf("--");
  const commandArgs = separatorIndex === -1 ? args : args.slice(separatorIndex + 1);
  const [childCommand, ...childArgs] = commandArgs;

  if (!childCommand) {
    throw new Error("usage: steer wrap -- <command> [...args]");
  }

  await wrapPtyProvider("custom", childCommand, childArgs);
}

async function wrapProvider(provider, childCommand, childArgs) {
  const sessionId = `${provider}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const agent = await connectToAgent();
  const child = spawn(childCommand, childArgs, {
    cwd: process.cwd(),
    env: {
      ...process.env,
      STEER_PROVIDER: provider,
      STEER_SESSION_ID: sessionId
    },
    stdio: ["pipe", "pipe", "pipe"]
  });

  agent.write(encodeMessage({
    type: "register",
    sessionId,
    provider,
    adapterKind: "stdio-pipe",
    command: childCommand,
    args: childArgs,
    cwd: process.cwd(),
    pid: child.pid
  }));

  process.stderr.write(`[steer] session ${sessionId}\n`);
  process.stderr.write(`[steer] send with: steer send ${sessionId} \"your instruction\"\n`);

  process.stdin.setRawMode?.(false);
  process.stdin.pipe(child.stdin, { end: false });

  child.stdout.on("data", (chunk) => {
    process.stdout.write(chunk);
    setImmediate(() => {
      agent.write(encodeMessage({ type: "output", sessionId, stream: "stdout", chunk: chunk.toString("utf8") }));
    });
  });

  child.stderr.on("data", (chunk) => {
    process.stderr.write(chunk);
    setImmediate(() => {
      agent.write(encodeMessage({ type: "output", sessionId, stream: "stderr", chunk: chunk.toString("utf8") }));
    });
  });

  agent.on("data", createLineDecoder((message) => {
    if (message.type !== "instruction") return;

    const payload = formatInstructionWithAttachments(message.text, message.attachments);
    child.stdin.write(`${payload}\n`);
    agent.write(encodeMessage({ type: "state", sessionId, runState: "running" }));
    agent.write(encodeMessage({
      type: "ack",
      sessionId,
      instructionId: message.instructionId,
      status: "injected"
    }));
  }));

  child.on("exit", (exitCode) => {
    agent.write(encodeMessage({ type: "state", sessionId, runState: "ended", exitCode }));
    agent.end();
    process.exit(exitCode ?? 0);
  });
}

async function wrapPtyProvider(provider, childCommand, childArgs) {
  const sessionId = `${provider}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const pendingInstructions = [];
  let ptyReady = provider === "custom";
  let instructionInFlight = false;
  let ptyBuffer = "";
  let idleReportTimer = null;
  let lastIdleReport = "";
  process.stderr.write(`[steer] ${provider} session ${sessionId}\n`);
  process.stderr.write(`[steer] send with: steer send ${sessionId} "your instruction"\n`);

  const spawnedAt = new Date();
  const ptyProcess = spawnInteractivePtyProcess(provider, sessionId, childCommand, childArgs);

  const registerMessage = {
    type: "register",
    sessionId,
    provider,
    adapterKind: "pty-bridge",
    command: childCommand,
    args: childArgs,
    cwd: process.cwd(),
    pid: ptyProcess.pid
  };

  const agent = createAgentLink({ agentEntryPath });
  await agent.start({
    register: registerMessage,
    onInstruction: (message) => {
      pendingInstructions.push(message);
      processInstructionQueue();
    }
  });

  let codexReader = null;
  if (provider === "codex") {
    codexReader = startCodexSessionReader({
      spawnedAt,
      onAgentMessage: (message) => {
        agent.write({ type: "output", sessionId, stream: "report", chunk: `${message}\n` });
        agent.write({ type: "state", sessionId, runState: "waiting" });
      },
      onError: (error) => {
        process.stderr.write(`[steer] codex session log reader: ${error.message}\n`);
      }
    });
  }

  const processInstructionQueue = () => {
    if (!ptyReady || instructionInFlight || pendingInstructions.length === 0) return;
    instructionInFlight = true;
    submitPtyInstruction(pendingInstructions.shift(), () => {
      instructionInFlight = false;
      processInstructionQueue();
    });
  };

  const markPtyReady = () => {
    if (ptyReady) return;
    ptyReady = true;
    processInstructionQueue();
  };

  const readinessTimeout = provider === "codex" ? 15000 : 2500;
  const readinessTimer = setTimeout(markPtyReady, readinessTimeout);
  readinessTimer.unref?.();

  process.stdin.setRawMode?.(true);
  process.stdin.resume();
  // The user typing into the wrapped terminal is *not* itself enough to
  // hide the card. We only flip run_state when the AI actually starts
  // producing semantic output (handled by codex_session_reader / the PTY
  // adapter when they emit `state=running`). A bare keystroke can be just
  // the user thinking out loud, and pre-emptively dismissing the card
  // costs them context they may still need to compose their reply.
  //
  // Esc / Ctrl-C *do* still flip back to waiting, so a user who started
  // typing in the terminal and changed their mind sees the card again.
  process.stdin.on("data", (chunk) => {
    ptyProcess.write(chunk);
    if (isCancelChunk(chunk)) {
      agent.write({ type: "state", sessionId, runState: "waiting" });
    }
  });
  process.stdin.on("end", () => {
    ptyProcess.write("\x04");
  });

  const restoreInput = () => {
    process.stdin.setRawMode?.(false);
    process.stdin.pause();
  };

  ptyProcess.onData((data) => {
    process.stdout.write(data);
    setImmediate(() => {
      ptyBuffer = (ptyBuffer + data).slice(-120_000);
      agent.write({ type: "output", sessionId, stream: "pty", chunk: data });
      observePtyReadiness(provider, data, markPtyReady);
      schedulePtyIdleReport(provider);
    });
  });

  const syncPtySize = () => {
    ptyProcess.resize(process.stdout.columns || 80, process.stdout.rows || 24);
  };
  syncPtySize();
  process.stdout.on("resize", syncPtySize);

  ptyProcess.onExit(({ exitCode }) => {
    clearTimeout(readinessTimer);
    clearTimeout(idleReportTimer);
    codexReader?.stop();
    restoreInput();
    agent.write({ type: "state", sessionId, runState: "ended", exitCode });
    agent.end();
    process.exit(exitCode ?? 0);
  });

  function submitPtyInstruction(message, done) {
    agent.write({ type: "state", sessionId, runState: "running" });
    const merged = formatInstructionWithAttachments(message.text, message.attachments);
    const input = formatPtyInstructionInput(provider, merged);
    // Write the instruction payload and the submit keystroke (\r) as a
    // single PTY write so they land in the same kernel buffer flush.
    // The previous code split them across a 50 ms setTimeout; that gap
    // allowed the PTY's write queue to deliver the paste content while the
    // provider was still streaming, which some providers (Codex, Claude)
    // silently discard. A single atomic write eliminates that race window.
    ptyProcess.write(input + "\r");
    agent.write({
      type: "ack",
      sessionId,
      instructionId: message.instructionId,
      status: "injected"
    });
    done();
  }

  function schedulePtyIdleReport(currentProvider) {
    if (currentProvider !== "claude") return;
    clearTimeout(idleReportTimer);
    idleReportTimer = setTimeout(() => {
      const report = extractPtyIdleReport(currentProvider, ptyBuffer);
      if (!report) return;
      if (report === lastIdleReport) return;
      if (lastIdleReport && lastIdleReport.length > report.length && lastIdleReport.startsWith(report)) {
        return;
      }

      lastIdleReport = report;
      agent.write({ type: "output", sessionId, stream: "report", chunk: `${report}\n` });
      agent.write({ type: "state", sessionId, runState: "waiting" });
    }, 900);
    idleReportTimer.unref?.();
  }
}

function spawnInteractivePtyProcess(provider, sessionId, childCommand, childArgs) {
  const env = {
    ...process.env,
    STEER_PROVIDER: provider,
    STEER_SESSION_ID: sessionId,
    STEER_PTY_COLS: String(process.stdout.columns || 80),
    STEER_PTY_ROWS: String(process.stdout.rows || 24)
  };

  return pty.spawn(childCommand, childArgs, {
    name: process.env.TERM || "xterm-256color",
    cols: process.stdout.columns || 80,
    rows: process.stdout.rows || 24,
    cwd: process.cwd(),
    env
  });
}

function observePtyReadiness(provider, chunk, markReady) {
  if (provider === "codex") {
    const text = cleanTerminalControl(chunk);
    if (/MCP startup (?:incomplete|complete)/i.test(text)) {
      markReady();
    }
    return;
  }

  if (chunk.length > 0) {
    markReady();
  }
}

function cleanTerminalControl(value) {
  return value
    .replace(/\x1B\][^\x07]*(?:\x07|\x1B\\)/g, "")
    .replace(/\x1B[PX^_][\s\S]*?\x1B\\/g, "")
    .replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\x1B[@-Z\\-_]/g, "")
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "");
}

async function runClaudeAdapter(args) {
  if (args[0] === "--headless") {
    await runClaudeHeadlessAdapter(args.slice(1));
    return;
  }

  if (args[0] === "--raw") {
    await wrapProvider("claude", "claude", args.slice(1));
    return;
  }

  ensureClaudeHooksInstalled();
  await wrapPtyProvider("claude", "claude", args);
}

function ensureClaudeHooksInstalled() {
  if (isClaudeHookInstalled()) return;
  try {
    const settingsPath = installClaudeHooks();
    process.stderr.write(
      `[steer] installed Claude Stop/Notification hooks at ${settingsPath}\n` +
      `[steer] (hooks let Steer show clean stop reports instead of guessing from PTY output)\n`
    );
  } catch (error) {
    process.stderr.write(
      `[steer] could not install Claude hooks (${error.message})\n` +
      `[steer] cards will fall back to PTY heuristic; run 'steer install-claude-hooks' manually to fix\n`
    );
  }
}

async function runClaudeHeadlessAdapter(args) {

  const sessionId = `claude-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const agent = await connectToAgent();
  const claudeArgs = [
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--replay-user-messages",
    "--verbose",
    "--include-partial-messages",
    ...args
  ];
  const child = spawn("claude", claudeArgs, {
    cwd: process.cwd(),
    env: {
      ...process.env,
      STEER_PROVIDER: "claude",
      STEER_SESSION_ID: sessionId
    },
    stdio: ["pipe", "pipe", "pipe"]
  });

  agent.write(encodeMessage({
    type: "register",
    sessionId,
    provider: "claude",
    adapterKind: "claude-stream-json",
    command: "claude",
    args: claudeArgs,
    cwd: process.cwd(),
    pid: child.pid
  }));

  process.stderr.write(`[steer] claude session ${sessionId}\n`);
  process.stderr.write(`[steer] send with: steer send ${sessionId} "your instruction"\n`);

  child.stdout.on("data", (chunk) => {
    const raw = chunk.toString("utf8");
    handleClaudeStream(raw, agent, sessionId);
    setImmediate(() => {
      agent.write(encodeMessage({ type: "output", sessionId, stream: "stdout", chunk: raw }));
    });
  });

  child.stderr.on("data", (chunk) => {
    const raw = chunk.toString("utf8");
    process.stderr.write(raw);
    setImmediate(() => {
      agent.write(encodeMessage({ type: "output", sessionId, stream: "stderr", chunk: raw }));
    });
  });

  agent.on("data", createLineDecoder((message) => {
    if (message.type !== "instruction") return;

    agent.write(encodeMessage({ type: "state", sessionId, runState: "running" }));
    const payload = formatInstructionWithAttachments(message.text, message.attachments);
    child.stdin.write(`${JSON.stringify({
      type: "user",
      message: {
        role: "user",
        content: [{ type: "text", text: payload }]
      }
    })}\n`);
    agent.write(encodeMessage({
      type: "ack",
      sessionId,
      instructionId: message.instructionId,
      status: "injected"
    }));
  }));

  child.on("exit", (exitCode) => {
    agent.write(encodeMessage({ type: "state", sessionId, runState: "ended", exitCode }));
    agent.end();
    process.exit(exitCode ?? 0);
  });
}

async function runCodexAdapter(args) {
  if (args[0] === "--headless") {
    await runCodexHeadlessAdapter(args.slice(1));
    return;
  }

  if (args[0] === "--raw") {
    await wrapProvider("codex", "codex", args.slice(1));
    return;
  }

  await wrapPtyProvider("codex", "codex", args);
}

async function runCodexHeadlessAdapter(args) {

  const sessionId = `codex-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const agent = await connectToAgent();
  const codex = createCodexRpcClient();
  let threadId = null;
  let activeTurnId = null;
  let runState = "starting";
  let printedDelta = false;

  const writeAgent = (message) => agent.write(encodeMessage(message));
  const writeAgentLater = (message) => {
    setImmediate(() => agent.write(encodeMessage(message)));
  };
  const writeOutput = (stream, chunk) => {
    writeAgentLater({ type: "output", sessionId, stream, chunk });
  };
  const setState = (nextState) => {
    runState = nextState;
    writeAgent({ type: "state", sessionId, runState });
  };

  codex.onNotification = (message) => {
    switch (message.method) {
      case "thread/status/changed": {
        const statusType = message.params?.status?.type;
        if (statusType === "active") setState("running");
        if (statusType === "idle") setState("waiting");
        break;
      }
      case "turn/started":
        activeTurnId = message.params?.turn?.id ?? activeTurnId;
        printedDelta = false;
        setState("running");
        break;
      case "turn/completed":
        activeTurnId = null;
        if (printedDelta) {
          process.stdout.write("\n");
          writeOutput("stdout", "\n");
        }
        setState("waiting");
        break;
      case "item/agentMessage/delta": {
        const delta = message.params?.delta ?? "";
        if (!delta) break;
        printedDelta = true;
        process.stdout.write(delta);
        writeOutput("stdout", delta);
        break;
      }
      case "item/commandExecution/outputDelta": {
        const delta = message.params?.delta ?? "";
        if (!delta) break;
        process.stdout.write(delta);
        writeOutput("stdout", delta);
        break;
      }
      case "item/plan/delta": {
        const delta = message.params?.delta ?? "";
        if (!delta) break;
        writeOutput("system", `[plan] ${delta}`);
        break;
      }
      case "warning": {
        const warning = message.params?.message;
        if (warning) writeOutput("system", `[codex warning] ${warning}\n`);
        break;
      }
      case "error": {
        const error = message.params?.error?.message ?? JSON.stringify(message.params?.error ?? message.params);
        process.stderr.write(`[codex error] ${error}\n`);
        writeOutput("stderr", `[codex error] ${error}\n`);
        setState("blocked");
        break;
      }
    }
  };
  codex.onStderr = (chunk) => {
    process.stderr.write(chunk);
    writeOutput("stderr", chunk);
  };
  codex.onExit = (exitCode) => {
    writeAgent({ type: "state", sessionId, runState: "ended", exitCode });
    agent.end();
    process.exit(exitCode ?? 0);
  };

  const threadOptions = parseCodexThreadOptions(args);
  await codex.request("initialize", {
    clientInfo: { name: "steer", version: "0.0.0" },
    capabilities: { experimental: true }
  });
  codex.notify("initialized");
  const thread = await codex.request("thread/start", {
    cwd: process.cwd(),
    sessionStartSource: "startup",
    ...threadOptions
  });
  threadId = thread.thread.id;

  writeAgent({
    type: "register",
    sessionId,
    provider: "codex",
    adapterKind: "codex-app-server",
    command: "codex",
    args: ["app-server", "--listen", "stdio://"],
    cwd: process.cwd(),
    pid: codex.pid,
    providerThreadId: threadId
  });
  setState("waiting");

  process.stderr.write(`[steer] codex session ${sessionId}\n`);
  process.stderr.write(`[steer] codex thread ${threadId}\n`);
  process.stderr.write(`[steer] send with: steer send ${sessionId} "your instruction"\n`);

  agent.on("data", createLineDecoder(async (message) => {
    if (message.type !== "instruction") return;

    try {
      setState("running");
      const payload = formatInstructionWithAttachments(message.text, message.attachments);
      const input = [{ type: "text", text: payload, text_elements: [] }];
      if (activeTurnId && runState === "running") {
        const response = await codex.request("turn/steer", {
          threadId,
          input,
          expectedTurnId: activeTurnId
        });
        activeTurnId = response.turnId ?? activeTurnId;
      } else {
        const response = await codex.request("turn/start", { threadId, input });
        activeTurnId = response.turn.id;
      }
      writeAgent({
        type: "ack",
        sessionId,
        instructionId: message.instructionId,
        status: "injected"
      });
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      process.stderr.write(`[steer] codex injection failed: ${detail}\n`);
      writeOutput("stderr", `[steer] codex injection failed: ${detail}\n`);
      writeAgent({
        type: "ack",
        sessionId,
        instructionId: message.instructionId,
        status: "failed"
      });
      setState("blocked");
    }
  }));
}

async function sendInstruction(args) {
  const { sessionId, text, attachments } = parseSendArgs(args);

  if (!sessionId || (!text && attachments.length === 0)) {
    throw new Error("usage: steer send <sessionId> <instruction> [--attach <path>]...");
  }

  // How long we retry when the agent returns a transient
  // "session not found" / "session is disconnected" error.
  // The wrapper's agent_link reconnects within ~250 ms on a
  // normal socket bounce and up to ~6 s after a SIGKILL restart
  // while the OS-level agent lock reaches its stale threshold.
  // 8 s keeps send alive across that restart window without
  // blocking the caller too long if the session genuinely ended.
  //
  // Inlined here instead of a module-level const because the
  // CLI dispatcher at the top of this file awaits sendInstruction
  // before module evaluation reaches any const declared *after*
  // the dispatcher — running into a TDZ ReferenceError. Inline
  // const is fine; the value is set on every send call.
  const SEND_RECONNECT_RETRY_MS = 8000;
  const deadline = Date.now() + SEND_RECONNECT_RETRY_MS;
  let backoffMs = 150;
  let lastError;

  while (true) {
    let response;
    try {
      response = await requestAgent({ type: "send", sessionId, text, attachments });
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
      if (!isTransientAgentSendError(lastError) || Date.now() >= deadline) {
        throw error;
      }
      const remaining = deadline - Date.now();
      await delay(Math.min(backoffMs, remaining));
      backoffMs = Math.min(backoffMs * 2, 500);
      continue;
    }

    if (response.type !== "error") {
      console.log(JSON.stringify(response, null, 2));
      return;
    }

    // Retry only for transient "session not yet registered" or "socket
    // bounce" errors. Any other error (bad sessionId format, unknown type,
    // etc.) is permanent and should surface immediately.
    const isTransient =
      typeof response.error === "string" &&
      isTransientAgentSendError(response.error);

    if (!isTransient || Date.now() >= deadline) {
      console.error(response.error);
      process.exit(1);
    }

    lastError = response.error;
    const remaining = deadline - Date.now();
    await delay(Math.min(backoffMs, remaining));
    backoffMs = Math.min(backoffMs * 2, 500);
  }
}

function isTransientAgentSendError(message) {
  return (
    message.includes("session not found") ||
    message.includes("session is disconnected") ||
    message.includes("SteerAgent did not start within")
  );
}

function parseSendArgs(args) {
  const positional = [];
  const attachments = [];
  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    if (token === "--attach" || token === "-a") {
      const next = args[i + 1];
      if (!next) {
        throw new Error(`${token} requires a path argument`);
      }
      attachments.push(next);
      i += 1;
      continue;
    }
    if (token.startsWith("--attach=")) {
      attachments.push(token.slice("--attach=".length));
      continue;
    }
    positional.push(token);
  }
  const [sessionId, ...textParts] = positional;
  return {
    sessionId,
    text: textParts.join(" ").trim(),
    attachments
  };
}

async function reportHookEvent(args) {
  const [provider, eventName] = args;
  const rawInput = fs.readFileSync(0, "utf8");
  let payload;

  try {
    payload = parseHookInput(rawInput);
  } catch (error) {
    process.stderr.write(`[steer hook] ignored invalid JSON: ${error.message}\n`);
    return;
  }

  const event = normalizeHookPayload(provider, eventName, payload);
  if (!event.sessionId) {
    process.stderr.write("[steer hook] missing STEER_SESSION_ID; start the session with steer claude\n");
    return;
  }

  const response = await requestAgent({ type: "hook_event", ...event });
  if (response.type === "error") {
    process.stderr.write(`[steer hook] ${response.error}\n`);
  }
}

async function installClaudeHooksCommand() {
  const settingsPath = installClaudeHooks();
  console.log(`Installed Steer Claude hooks at ${settingsPath}`);
}

async function listSessions() {
  const response = await requestAgent({ type: "sessions" });
  console.log(JSON.stringify(response.sessions ?? [], null, 2));
}

async function printStats() {
  if (!fs.existsSync(databasePath)) {
    console.log("No Steer database yet. Start a session with `steer codex` or `steer claude`.");
    return;
  }
  const db = new DatabaseSync(databasePath);

  const sessionRows = db.prepare(`
    SELECT run_state, COUNT(*) AS n
    FROM sessions
    GROUP BY run_state
  `).all();

  const cardRows = db.prepare(`
    SELECT category, state, COUNT(*) AS n
    FROM action_cards
    GROUP BY category, state
    ORDER BY category, state
  `).all();

  const recentInstructions = db.prepare(`
    SELECT status, COUNT(*) AS n
    FROM instructions
    WHERE created_at > datetime('now', '-7 days')
    GROUP BY status
  `).all();

  const replyLatency = db.prepare(`
    SELECT
      AVG((julianday(injected_at) - julianday(created_at)) * 86400.0) AS avg_seconds,
      COUNT(*) AS n
    FROM instructions
    WHERE injected_at IS NOT NULL
      AND created_at > datetime('now', '-7 days')
  `).get();

  console.log("Sessions");
  if (sessionRows.length === 0) {
    console.log("  (none)");
  } else {
    for (const row of sessionRows) {
      console.log(`  ${row.run_state.padEnd(14)} ${row.n}`);
    }
  }

  console.log("\nAction cards by category × state");
  if (cardRows.length === 0) {
    console.log("  (none)");
  } else {
    for (const row of cardRows) {
      console.log(`  ${(row.category + " · " + row.state).padEnd(28)} ${row.n}`);
    }
  }

  console.log("\nInstructions (last 7 days)");
  if (recentInstructions.length === 0) {
    console.log("  (none)");
  } else {
    for (const row of recentInstructions) {
      console.log(`  ${row.status.padEnd(14)} ${row.n}`);
    }
    if (replyLatency?.n > 0) {
      const avg = replyLatency.avg_seconds.toFixed(2);
      console.log(`  avg reply→inject ${avg}s (${replyLatency.n} samples)`);
    }
  }

  db.close();
}

async function connectToAgent() {
  if (fs.existsSync(socketPath)) {
    try {
      return await openAgentSocket();
    } catch {
      try {
        fs.unlinkSync(socketPath);
      } catch {}
    }
  }

  await startAgent();
  return openAgentSocket();
}

async function requestAgent(message) {
  const socket = await connectToAgent();

  return new Promise((resolve, reject) => {
    socket.setEncoding("utf8");
    socket.on("data", createLineDecoder((response) => {
      resolve(response);
      socket.end();
    }));
    socket.on("error", reject);
    socket.write(encodeMessage(message));
  });
}

function openAgentSocket() {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    socket.once("connect", () => resolve(socket));
    socket.once("error", reject);
  });
}

async function startAgent() {
  fs.mkdirSync(path.dirname(socketPath), { recursive: true });
  const logPath = path.join(path.dirname(socketPath), "agent.log");
  const logFd = fs.openSync(logPath, "a");
  const child = spawn(process.execPath, [agentEntryPath], {
    cwd: process.cwd(),
    env: process.env,
    detached: true,
    stdio: ["ignore", logFd, logFd]
  });
  child.unref();

  const deadline = Date.now() + 7000;
  while (Date.now() < deadline) {
    if (fs.existsSync(socketPath)) return;
    await delay(50);
  }

  throw new Error("SteerAgent did not start within 7s");
}

function printUsage() {
  console.log(`Usage:
  steer agent
  steer wrap -- <command> [...args]
  steer claude [...claude args]
  steer claude --headless [...claude print-mode args]
  steer claude --raw [...claude args]
  steer codex [...codex args]
  steer codex --headless [--model <model>] [--approval-policy <policy>] [--sandbox <mode>]
  steer codex --raw [...codex interactive args]
  steer sessions
  steer stats
  steer send <sessionId> <instruction>
  steer hook <provider> <eventName>
  steer install-claude-hooks
`);
}

function parseCodexThreadOptions(args) {
  const options = {};

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const next = args[index + 1];

    if (arg === "--model" && next) {
      options.model = next;
      index += 1;
    } else if (arg === "--approval-policy" && next) {
      options.approvalPolicy = next;
      index += 1;
    } else if (arg === "--sandbox" && next) {
      options.sandbox = next;
      index += 1;
    } else {
      throw new Error(`unsupported steer codex option: ${arg}`);
    }
  }

  return options;
}

function createCodexRpcClient() {
  const child = spawn("codex", ["app-server", "--listen", "stdio://"], {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"]
  });
  let nextId = 1;
  let stdoutBuffer = "";
  const pending = new Map();
  const client = {
    pid: child.pid,
    onNotification: null,
    onStderr: null,
    onExit: null,
    request(method, params) {
      const id = nextId;
      nextId += 1;
      const payload = { jsonrpc: "2.0", id, method, params };

      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        child.stdin.write(`${JSON.stringify(payload)}\n`, (error) => {
          if (!error) return;
          pending.delete(id);
          reject(error);
        });
      });
    },
    notify(method, params) {
      child.stdin.write(`${JSON.stringify({
        jsonrpc: "2.0",
        method,
        ...(params ? { params } : {})
      })}\n`);
    }
  };

  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString("utf8");

    for (;;) {
      const newlineIndex = stdoutBuffer.indexOf("\n");
      if (newlineIndex === -1) return;

      const line = stdoutBuffer.slice(0, newlineIndex);
      stdoutBuffer = stdoutBuffer.slice(newlineIndex + 1);
      if (!line.trim()) continue;

      handleCodexRpcLine(line, pending, client);
    }
  });

  child.stderr.on("data", (chunk) => {
    client.onStderr?.(chunk.toString("utf8"));
  });

  child.on("exit", (exitCode) => {
    for (const { reject } of pending.values()) {
      reject(new Error(`codex app-server exited with code ${exitCode}`));
    }
    pending.clear();
    client.onExit?.(exitCode);
  });
  child.on("error", (error) => {
    for (const { reject } of pending.values()) {
      reject(error);
    }
    pending.clear();
    client.onStderr?.(`[codex app-server] ${error.message}\n`);
  });

  return client;
}

function handleCodexRpcLine(line, pending, client) {
  let message;

  try {
    message = JSON.parse(line);
  } catch {
    client.onStderr?.(`[codex rpc] non-json line: ${line}\n`);
    return;
  }

  if (message.id !== undefined) {
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);

    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
    return;
  }

  client.onNotification?.(message);
}

function handleClaudeStream(raw, agent, sessionId) {
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;

    try {
      const event = JSON.parse(line);
      const textDelta = event?.event?.delta?.type === "text_delta"
        ? event.event.delta.text
        : null;
      const result = typeof event?.result === "string" ? event.result : null;
      const userText = event?.type === "user"
        ? event.message?.content?.find?.((item) => item.type === "text")?.text
        : null;

      if (textDelta) process.stdout.write(textDelta);
      else if (result) {
        process.stdout.write(`${result}\n`);
        setImmediate(() => {
          agent.write(encodeMessage({ type: "state", sessionId, runState: "waiting" }));
        });
      }
      else if (userText) process.stderr.write(`[user] ${userText}\n`);
    } catch {
      process.stdout.write(line);
    }
  }
}
