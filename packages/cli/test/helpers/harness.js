// Test harness that boots an isolated SteerAgent + can run wrappers
// against the fake provider in test/helpers/fake_provider.js.
//
// Each test gets its own STEER_HOME so the production DB and socket are
// untouched.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { DatabaseSync } from "node:sqlite";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const AGENT_ENTRY = path.join(REPO_ROOT, "packages", "agent", "src", "agent.js");
const CLI_ENTRY = path.join(REPO_ROOT, "packages", "cli", "src", "index.js");
const FAKE_PROVIDER = path.join(__dirname, "fake_provider.js");

export function createHarness() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "steer-test-"));
  const socketPath = path.join(home, "steer.sock");
  const dbPath = path.join(home, "steer.sqlite");
  const planPath = path.join(home, "fake_plan.json");

  const env = {
    ...process.env,
    STEER_HOME: home,
    STEER_SOCKET: socketPath,
    STEER_DB: dbPath,
    STEER_FAKE_PLAN: planPath
  };

  const procs = [];
  let agent = null;

  return {
    home, socketPath, dbPath, planPath, env,

    async startAgent() {
      if (agent) return agent;
      const child = spawn(process.execPath, [AGENT_ENTRY], {
        env,
        cwd: home,
        stdio: ["ignore", "pipe", "pipe"]
      });
      procs.push(child);
      agent = child;

      // Wait until the socket is accepting connections.
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline) {
        if (fs.existsSync(socketPath)) {
          try {
            const ok = await new Promise((resolve) => {
              const s = net.createConnection(socketPath);
              const finish = (val) => {
                s.destroy();
                resolve(val);
              };
              s.once("connect", () => finish(true));
              s.once("error", () => finish(false));
              setTimeout(() => finish(false), 200);
            });
            if (ok) return agent;
          } catch {}
        }
        await delay(50);
      }
      throw new Error("agent did not come up within 5s");
    },

    /// Kill the agent. Set graceful=false to simulate a SIGKILL crash
    /// that leaves the socket file behind.
    async stopAgent({ graceful = true } = {}) {
      if (!agent) return;
      const proc = agent;
      agent = null;
      proc.kill(graceful ? "SIGTERM" : "SIGKILL");
      await new Promise((resolve) => {
        const t = setTimeout(resolve, 1500);
        proc.once("exit", () => {
          clearTimeout(t);
          resolve();
        });
      });
    },

    setPlan(plan) {
      fs.writeFileSync(planPath, JSON.stringify(plan));
    },

    /// Spawn `steer wrap -- node fake_provider.js`. Returns the child
    /// process; tests should write to child.stdin to deliver keystrokes
    /// and rely on the harness DB queries to observe state.
    spawnWrappedSession({ provider = "custom" } = {}) {
      const args = [CLI_ENTRY, "wrap", "--", process.execPath, FAKE_PROVIDER];
      const child = spawn(process.execPath, args, {
        env: { ...env, STEER_FAKE_PROVIDER: provider },
        cwd: home,
        stdio: ["pipe", "pipe", "pipe"]
      });
      procs.push(child);
      return child;
    },

    /// Trigger a Stop hook against the live agent. Uses the real
    /// `steer hook claude Stop` path with stdin-injected JSON, the same
    /// way Claude Code runs it in production.
    async fireStopHook(sessionId, lastAssistantMessage = "") {
      return new Promise((resolve, reject) => {
        const args = [CLI_ENTRY, "hook", "claude", "Stop"];
        const child = spawn(process.execPath, args, {
          env: { ...env, STEER_SESSION_ID: sessionId },
          cwd: home,
          stdio: ["pipe", "pipe", "pipe"]
        });
        let stderr = "";
        child.stderr.on("data", (c) => { stderr += c.toString("utf8"); });
        child.on("exit", (code) => {
          if (code === 0) resolve();
          else reject(new Error(`steer hook claude Stop exit ${code}: ${stderr}`));
        });
        child.stdin.write(JSON.stringify({
          session_id: sessionId,
          last_assistant_message: lastAssistantMessage
        }));
        child.stdin.end();
      });
    },

    /// Convenience: drive `steer send` against the live agent.
    async sendInstruction(sessionId, text, attachments = []) {
      return new Promise((resolve, reject) => {
        const args = [CLI_ENTRY, "send", sessionId, text];
        for (const a of attachments) {
          args.push("--attach", a);
        }
        const child = spawn(process.execPath, args, { env, cwd: home });
        let stderr = "";
        child.stderr.on("data", (c) => { stderr += c.toString("utf8"); });
        child.on("exit", (code) => {
          if (code === 0) resolve();
          else reject(new Error(`steer send exit ${code}: ${stderr}`));
        });
      });
    },

    /// Direct DB read for assertions. Read-only.
    db() {
      return new DatabaseSync(dbPath, { readOnly: true });
    },

    async waitFor(predicate, { timeoutMs = 5000, intervalMs = 100 } = {}) {
      const deadline = Date.now() + timeoutMs;
      let lastError = null;
      while (Date.now() < deadline) {
        try {
          if (predicate()) return true;
        } catch (e) {
          lastError = e;
        }
        await delay(intervalMs);
      }
      if (lastError) throw lastError;
      throw new Error(`waitFor timed out after ${timeoutMs}ms`);
    },

    async cleanup() {
      for (const p of procs) {
        try { p.kill("SIGKILL"); } catch {}
      }
      // Best-effort socket cleanup; the OS unlinks tmpdir anyway.
      try { fs.rmSync(home, { recursive: true, force: true }); } catch {}
    }
  };
}
