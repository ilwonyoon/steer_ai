import net from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import fs from "node:fs";
import { spawn } from "node:child_process";
import path from "node:path";
import { encodeMessage, createLineDecoder } from "../../agent/src/protocol.js";
import { socketPath } from "../../agent/src/paths.js";

const RECONNECT_INITIAL_MS = 250;
const RECONNECT_MAX_MS = 5_000;
const STARTUP_DEADLINE_MS = 7_000;

export function createAgentLink({ agentEntryPath }) {
  let socket = null;
  let connecting = false;
  let stopped = false;
  let reconnectDelay = RECONNECT_INITIAL_MS;
  let registerMessage = null;
  let onInstruction = null;
  const buffer = [];

  const connect = async () => {
    if (connecting || stopped) return;
    connecting = true;

    while (!stopped) {
      try {
        if (!fs.existsSync(socketPath)) {
          await startAgent(agentEntryPath);
        }

        const next = await openSocket();
        attach(next);
        connecting = false;
        return;
      } catch (error) {
        // ECONNREFUSED on an existing socket file means the agent died without
        // unlinking it (e.g. SIGKILL). Clear the stale entry and re-spawn.
        const isStale =
          error.code === "ECONNREFUSED" || error.code === "ENOENT";
        if (isStale && fs.existsSync(socketPath)) {
          try {
            fs.unlinkSync(socketPath);
          } catch (unlinkError) {
            process.stderr.write(`[steer] could not clear stale socket: ${unlinkError.message}\n`);
          }
        }
        process.stderr.write(`[steer] agent reconnect failed: ${error.message}; retrying in ${reconnectDelay}ms\n`);
        await delay(reconnectDelay);
        reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
      }
    }
    connecting = false;
  };

  const attach = (next) => {
    socket = next;
    reconnectDelay = RECONNECT_INITIAL_MS;

    socket.on("data", createLineDecoder((message) => {
      if (message.type === "instruction") onInstruction?.(message);
    }));
    socket.on("error", () => {});
    socket.on("close", () => {
      socket = null;
      if (stopped) return;
      void connect();
    });

    if (registerMessage) {
      socket.write(encodeMessage(registerMessage));
    }
    while (buffer.length > 0 && socket) {
      const next = buffer.shift();
      socket.write(encodeMessage(next));
    }
  };

  return {
    async start({ register, onInstruction: handler }) {
      registerMessage = register;
      onInstruction = handler;
      await connect();
    },
    write(message) {
      if (socket) {
        socket.write(encodeMessage(message));
        return;
      }
      buffer.push(message);
      if (buffer.length > 1024) {
        const dropIndex = buffer.findIndex((m) => !isPriorityMessage(m));
        if (dropIndex >= 0) buffer.splice(dropIndex, 1);
        else buffer.shift();
      }
      void connect();
    },
    end() {
      stopped = true;
      if (socket) socket.end();
    }
  };
}

function isPriorityMessage(message) {
  if (message?.type === "state") return true;
  if (message?.type === "ack") return true;
  if (message?.type === "output" && (message.stream === "report" || message.stream === "stdout" || message.stream === "stderr")) return true;
  return false;
}

function openSocket() {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    socket.once("connect", () => resolve(socket));
    socket.once("error", reject);
  });
}

async function startAgent(agentEntryPath) {
  fs.mkdirSync(path.dirname(socketPath), { recursive: true });
  const logPath = path.join(path.dirname(socketPath), "agent.log");
  const logFd = fs.openSync(logPath, "a");
  try {
    const child = spawn(process.execPath, [agentEntryPath], {
      cwd: process.cwd(),
      env: process.env,
      detached: true,
      stdio: ["ignore", logFd, logFd]
    });
    child.unref();
  } finally {
    fs.closeSync(logFd);
  }

  const deadline = Date.now() + STARTUP_DEADLINE_MS;
  while (Date.now() < deadline) {
    if (fs.existsSync(socketPath)) return;
    await delay(50);
  }
  throw new Error("SteerAgent did not start within 3s");
}
