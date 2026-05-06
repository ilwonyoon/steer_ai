#!/usr/bin/env node
import fs from "node:fs";
import net from "node:net";
import process from "node:process";
import { spawn } from "node:child_process";
import { encodeMessage, createLineDecoder } from "../../agent/src/protocol.js";
import { socketPath } from "../../agent/src/paths.js";

const [, , command, ...args] = process.argv;

switch (command) {
  case "agent":
    await import("../../agent/src/agent.js");
    break;
  case "wrap":
    await wrapCommand(args);
    break;
  case "claude":
    await wrapProvider("claude", "claude", args);
    break;
  case "codex":
    await wrapProvider("codex", "codex", args);
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

  await wrapProvider("custom", childCommand, childArgs);
}

async function wrapProvider(provider, childCommand, childArgs) {
  const sessionId = `${provider}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const agent = connectToAgent();
  const child = spawn(childCommand, childArgs, {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"]
  });

  agent.write(encodeMessage({
    type: "register",
    sessionId,
    provider,
    command: childCommand,
    args: childArgs,
    cwd: process.cwd(),
    pid: child.pid
  }));

  process.stderr.write(`[steer] session ${sessionId}\n`);
  process.stderr.write(`[steer] send with: node packages/cli/src/index.js send ${sessionId} \"your instruction\"\n`);

  process.stdin.setRawMode?.(false);
  process.stdin.pipe(child.stdin);

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

async function sendInstruction(args) {
  const [sessionId, ...textParts] = args;
  const text = textParts.join(" ").trim();

  if (!sessionId || !text) {
    throw new Error("usage: steer send <sessionId> <instruction>");
  }

  const response = await requestAgent({ type: "send", sessionId, text });
  console.log(JSON.stringify(response, null, 2));
}

async function listSessions() {
  const response = await requestAgent({ type: "sessions" });
  console.log(JSON.stringify(response.sessions ?? [], null, 2));
}

function connectToAgent() {
  if (!fs.existsSync(socketPath)) {
    throw new Error(`SteerAgent is not running. Start it with: node packages/agent/src/agent.js`);
  }

  return net.createConnection(socketPath);
}

function requestAgent(message) {
  return new Promise((resolve, reject) => {
    const socket = connectToAgent();
    socket.setEncoding("utf8");
    socket.on("data", createLineDecoder((response) => {
      resolve(response);
      socket.end();
    }));
    socket.on("error", reject);
    socket.write(encodeMessage(message));
  });
}

function printUsage() {
  console.log(`Usage:
  steer agent
  steer wrap -- <command> [...args]
  steer claude [...args]
  steer codex [...args]
  steer sessions
  steer send <sessionId> <instruction>
`);
}
