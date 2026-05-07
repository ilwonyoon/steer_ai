#!/usr/bin/env node
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { encodeMessage, createLineDecoder } from "./protocol.js";
import { sessionsDir, socketPath } from "./paths.js";
import { createStore } from "./store.js";

const sessions = new Map();

await prepareSocketPath();
const store = createStore();
fs.mkdirSync(sessionsDir, { recursive: true });

const server = net.createServer((socket) => {
  socket.setEncoding("utf8");

  const send = (message) => socket.write(encodeMessage(message));

  const handleMessage = (message) => {
    switch (message.type) {
      case "register":
        registerSession(message, socket, send);
        break;
      case "output":
        appendTranscript(message);
        break;
      case "state":
        updateState(message);
        break;
      case "send":
        routeInstruction(message, send);
        break;
      case "sessions":
        send({
          type: "sessions",
          sessions: [...sessions.values()].map(({ socket: _socket, ...session }) => session)
        });
        break;
      case "ack":
        store.updateInstructionStatus(
          message.instructionId,
          message.status,
          message.failureReason ?? null
        );
        appendTranscript({
          sessionId: message.sessionId,
          stream: "system",
          chunk: `[steer] instruction ${message.instructionId} ${message.status}\n`
        });
        if (message.status === "injected") {
          store.resolveActionCardsForSession(message.sessionId);
        }
        break;
      default:
        send({ type: "error", error: `unknown message type: ${message.type}` });
    }
  };

  socket.on("data", createLineDecoder(handleMessage));
  socket.on("close", () => {
    for (const [sessionId, session] of sessions) {
      if (session.socket === socket) {
        sessions.set(sessionId, {
          ...session,
          socket: null,
          runState: session.runState === "ended" ? "ended" : "disconnected",
          updatedAt: new Date().toISOString()
        });
        if (session.runState !== "ended") {
          store.updateSessionState(sessionId, "disconnected");
        }
      }
    }
  });
  socket.on("error", () => {});
});

server.on("error", (error) => {
  console.error(`SteerAgent failed to listen on ${socketPath}: ${error.message}`);
  store.close();
  process.exit(1);
});

server.listen(socketPath, () => {
  fs.chmodSync(socketPath, 0o600);
  console.log(`SteerAgent listening on ${socketPath}`);
});

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

function registerSession(message, socket, send) {
  const now = new Date().toISOString();
  const session = {
    id: message.sessionId,
    provider: message.provider,
    adapterKind: message.adapterKind,
    command: message.command,
    args: message.args ?? [],
    cwd: message.cwd,
    pid: message.pid,
    providerThreadId: message.providerThreadId,
    runState: "running",
    createdAt: now,
    updatedAt: now,
    currentRoomId: store.defaultRoomId,
    socket
  };

  sessions.set(message.sessionId, session);
  store.upsertSession(session);
  appendTranscript({
    sessionId: message.sessionId,
    stream: "system",
    chunk: `[steer] registered ${message.provider} session ${message.sessionId}\n`
  });
  send({ type: "registered", sessionId: message.sessionId });
}

function appendTranscript(message) {
  const filePath = path.join(sessionsDir, `${message.sessionId}.log`);
  const prefix = message.stream === "stdout" || message.stream === "stderr" ? "" : "";
  fs.appendFileSync(filePath, `${prefix}${message.chunk}`);
  store.appendTranscript(message);
}

function updateState(message) {
  const session = sessions.get(message.sessionId);
  if (!session) return;

  sessions.set(message.sessionId, {
    ...session,
    runState: message.runState,
    exitCode: message.exitCode,
    updatedAt: new Date().toISOString()
  });
  store.updateSessionState(message.sessionId, message.runState, message.exitCode ?? null);
}

function routeInstruction(message, send) {
  const session = sessions.get(message.sessionId);
  if (!session) {
    send({ type: "error", error: `session not found: ${message.sessionId}` });
    return;
  }

  if (!session.socket) {
    send({ type: "error", error: `session is disconnected: ${message.sessionId}` });
    return;
  }

  const instructionId = randomUUID();
  store.createInstruction({
    id: instructionId,
    sessionId: message.sessionId,
    text: message.text
  });
  session.socket.write(encodeMessage({
    type: "instruction",
    instructionId,
    text: message.text
  }));
  appendTranscript({
    sessionId: message.sessionId,
    stream: "user",
    chunk: `[user] ${message.text}\n`
  });
  send({ type: "queued", sessionId: message.sessionId, instructionId });
}

function shutdown() {
  server.close(() => {
    try {
      fs.unlinkSync(socketPath);
    } catch {}
    store.close();
    process.exit(0);
  });
}

async function prepareSocketPath() {
  fs.mkdirSync(path.dirname(socketPath), { recursive: true });
  if (!fs.existsSync(socketPath)) return;

  if (await socketAcceptsConnections(socketPath)) {
    console.error(`SteerAgent is already running at ${socketPath}`);
    process.exit(1);
  }

  try {
    fs.unlinkSync(socketPath);
  } catch (error) {
    console.error(`Failed to remove stale SteerAgent socket at ${socketPath}: ${error.message}`);
    process.exit(1);
  }
}

function socketAcceptsConnections(targetPath) {
  return new Promise((resolve) => {
    let settled = false;
    const socket = net.createConnection(targetPath);
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(value);
    };
    const timer = setTimeout(() => finish(false), 300);

    socket.once("connect", () => finish(true));
    socket.once("error", () => finish(false));
  });
}
