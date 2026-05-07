import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { installClaudeHooks, normalizeHookPayload, parseHookInput } from "../src/hooks.js";

test("normalizes Claude Stop hook payload with Steer session env", () => {
  const event = normalizeHookPayload("claude", "Stop", {
    session_id: "claude-provider-session",
    transcript_path: "/tmp/transcript.jsonl",
    last_assistant_message: "Which option should I use?"
  }, {
    STEER_SESSION_ID: "claude-steer-session",
    PWD: "/repo"
  });

  assert.equal(event.provider, "claude");
  assert.equal(event.eventName, "Stop");
  assert.equal(event.sessionId, "claude-steer-session");
  assert.equal(event.providerSessionId, "claude-provider-session");
  assert.equal(event.transcriptPath, "/tmp/transcript.jsonl");
  assert.equal(event.lastAssistantMessage, "Which option should I use?");
});

test("parses empty hook stdin as empty object", () => {
  assert.deepEqual(parseHookInput("\n"), {});
});

test("installs Claude hooks without removing existing hooks", () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-hooks-"));
  const claudeDir = path.join(tempDir, ".claude");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(path.join(claudeDir, "settings.local.json"), JSON.stringify({
    hooks: {
      Stop: [
        {
          hooks: [
            {
              type: "command",
              command: "echo existing"
            }
          ]
        }
      ]
    }
  }));

  const settingsPath = installClaudeHooks({ cwd: tempDir });
  const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));

  assert.equal(settings.hooks.Stop[0].hooks[0].command, "echo existing");
  assert.ok(settings.hooks.Stop[0].hooks.some((hook) => hook.command === "steer hook claude Stop"));
  assert.ok(settings.hooks.Notification[0].hooks.some((hook) => hook.command === "steer hook claude Notification"));
});
