#!/usr/bin/env node
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { encodeMessage, createLineDecoder } from "../../agent/src/protocol.js";
import { socketPath } from "../../agent/src/paths.js";
import { formatPtyInstructionInput } from "./pty_input.js";

const [, , command, ...args] = process.argv;
const agentEntryPath = fileURLToPath(new URL("../../agent/src/agent.js", import.meta.url));
const ptyBridgePath = fileURLToPath(new URL("./pty_bridge.py", import.meta.url));

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
  case "sessions":
    await listSessions();
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
    env: process.env,
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
    agent.write(encodeMessage({ type: "output", sessionId, stream: "stdout", chunk: chunk.toString("utf8") }));
  });

  child.stderr.on("data", (chunk) => {
    process.stderr.write(chunk);
    agent.write(encodeMessage({ type: "output", sessionId, stream: "stderr", chunk: chunk.toString("utf8") }));
  });

  agent.on("data", createLineDecoder((message) => {
    if (message.type !== "instruction") return;

    child.stdin.write(`${message.text}\n`);
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
  const agent = await connectToAgent();
  const pendingInstructions = [];
  let ptyReady = provider === "custom";
  let instructionInFlight = false;
  const child = spawn("python3", [ptyBridgePath, childCommand, ...childArgs], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      STEER_PTY_COLS: String(process.stdout.columns || 80),
      STEER_PTY_ROWS: String(process.stdout.rows || 24)
    },
    stdio: ["pipe", "pipe", "pipe"]
  });

  agent.write(encodeMessage({
    type: "register",
    sessionId,
    provider,
    adapterKind: "pty-bridge",
    command: childCommand,
    args: childArgs,
    cwd: process.cwd(),
    pid: child.pid
  }));

  process.stderr.write(`[steer] ${provider} session ${sessionId}\n`);
  process.stderr.write(`[steer] send with: steer send ${sessionId} "your instruction"\n`);

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
  process.stdin.on("data", (chunk) => {
    child.stdin.write(chunk);
  });

  const restoreInput = () => {
    process.stdin.setRawMode?.(false);
    process.stdin.pause();
  };

  child.stdout.on("data", (chunk) => {
    process.stdout.write(chunk);
    agent.write(encodeMessage({ type: "output", sessionId, stream: "stdout", chunk: chunk.toString("utf8") }));
    observePtyReadiness(provider, chunk.toString("utf8"), markPtyReady);
  });

  child.stderr.on("data", (chunk) => {
    process.stderr.write(chunk);
    agent.write(encodeMessage({ type: "output", sessionId, stream: "stderr", chunk: chunk.toString("utf8") }));
    observePtyReadiness(provider, chunk.toString("utf8"), markPtyReady);
  });

  process.stdout.on("resize", () => {
    child.kill("SIGWINCH");
  });

  agent.on("data", createLineDecoder((message) => {
    if (message.type !== "instruction") return;

    pendingInstructions.push(message);
    processInstructionQueue();
  }));

  child.on("exit", (exitCode) => {
    clearTimeout(readinessTimer);
    restoreInput();
    agent.write(encodeMessage({ type: "state", sessionId, runState: "ended", exitCode }));
    agent.end();
    process.exit(exitCode ?? 0);
  });

  function submitPtyInstruction(message, done) {
    const input = formatPtyInstructionInput(provider, message.text);
    child.stdin.write(input, (textError) => {
      if (textError) {
        agent.write(encodeMessage({
          type: "ack",
          sessionId,
          instructionId: message.instructionId,
          status: "failed",
          failureReason: textError.message
        }));
        done();
        return;
      }

      setTimeout(() => {
        child.stdin.write("\r", (submitError) => {
          agent.write(encodeMessage({
            type: "ack",
            sessionId,
            instructionId: message.instructionId,
            status: submitError ? "failed" : "injected",
            ...(submitError ? { failureReason: submitError.message } : {})
          }));
          done();
        });
      }, 50);
    });
  }
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

  await wrapPtyProvider("claude", "claude", args);
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
    env: process.env,
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
    agent.write(encodeMessage({ type: "output", sessionId, stream: "stdout", chunk: raw }));
    handleClaudeStream(raw, agent, sessionId);
  });

  child.stderr.on("data", (chunk) => {
    const raw = chunk.toString("utf8");
    process.stderr.write(raw);
    agent.write(encodeMessage({ type: "output", sessionId, stream: "stderr", chunk: raw }));
  });

  agent.on("data", createLineDecoder((message) => {
    if (message.type !== "instruction") return;

    agent.write(encodeMessage({ type: "state", sessionId, runState: "running" }));
    child.stdin.write(`${JSON.stringify({
      type: "user",
      message: {
        role: "user",
        content: [{ type: "text", text: message.text }]
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
  const writeOutput = (stream, chunk) => {
    writeAgent({ type: "output", sessionId, stream, chunk });
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
      const input = [{ type: "text", text: message.text, text_elements: [] }];
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
  const [sessionId, ...textParts] = args;
  const text = textParts.join(" ").trim();

  if (!sessionId || !text) {
    throw new Error("usage: steer send <sessionId> <instruction>");
  }

  const response = await requestAgent({ type: "send", sessionId, text });
  if (response.type === "error") {
    console.error(response.error);
    process.exit(1);
  }
  console.log(JSON.stringify(response, null, 2));
}

async function listSessions() {
  const response = await requestAgent({ type: "sessions" });
  console.log(JSON.stringify(response.sessions ?? [], null, 2));
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
  const child = spawn(process.execPath, [agentEntryPath], {
    cwd: process.cwd(),
    env: process.env,
    detached: true,
    stdio: "ignore"
  });
  child.unref();

  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    if (fs.existsSync(socketPath)) return;
    await delay(50);
  }

  throw new Error("SteerAgent did not start within 3s");
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
  steer send <sessionId> <instruction>
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
        agent.write(encodeMessage({ type: "state", sessionId, runState: "waiting" }));
      }
      else if (userText) process.stderr.write(`[user] ${userText}\n`);
    } catch {
      process.stdout.write(line);
    }
  }
}
