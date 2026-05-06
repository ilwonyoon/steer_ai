#!/usr/bin/env node
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { encodeMessage, createLineDecoder } from "./protocol.js";
import { sessionsDir, socketPath } from "./paths.js";

const sessions = new Map();

fs.mkdirSync(sessionsDir, { recursive: true });
if (fs.existsSync(socketPath)) {
  fs.unlinkSync(socketPath);
}

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
        appendTranscript({
          sessionId: message.sessionId,
          stream: "system",
          chunk: `[steer] instruction ${message.instructionId} ${message.status}\n`
        });
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
      }
    }
  });
  socket.on("error", () => {});
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
    command: message.command,
    args: message.args ?? [],
    cwd: message.cwd,
    pid: message.pid,
    runState: "running",
    createdAt: now,
    updatedAt: now,
    socket
  };

  sessions.set(message.sessionId, session);
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
    process.exit(0);
  });
}
