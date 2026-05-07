import test from "node:test";
import assert from "node:assert/strict";
import { classifyTranscript, transcriptDisplayLines } from "../src/classifier.js";

const codexSession = {
  provider: "codex",
  command: "codex",
  run_state: "running"
};

test("filters Codex startup chrome and MCP boilerplate", () => {
  const lines = transcriptDisplayLines(`
    Tip: Try the Codex App. Run 'codex app' or visit
    https://chatgpt.com/codex?app-landing-page=true
    ⚠ Under-development features enabled: goals.
    MCP client for \`pencil\` failed to start: MCP startup failed:
    No such file or directory (os error 2)
    ⚠ MCP startup incomplete (failed: pencil)
    › Implement {feature}
    gpt-5.5 high fast · ~/Documents/Steer_ai
  `);

  assert.deepEqual(lines, ["[no transcript yet]"]);
});

test("separates Codex prompt chrome appended after content", () => {
  const lines = transcriptDisplayLines("• two›Improve documentation in @filename  gpt-5.5 high fast · ~/Developer/steer_ai");

  assert.deepEqual(lines, ["• two"]);
});

test("filters repeated Codex working repaint lines", () => {
  const lines = transcriptDisplayLines(`
    Working•Working•WorkingWorking1•
    • Hello. How can I help?orking
  `);

  assert.deepEqual(lines, ["• Hello. How can I help?orking"]);
});

test("classifies direct questions as active question cards", () => {
  const result = classifyTranscript({
    session: codexSession,
    entries: [
      {
        stream: "stdout",
        timestamp: "2026-05-06T23:00:00.000Z",
        chunk: "Need answer?\n"
      }
    ]
  });

  assert.equal(result.card.category, "question");
  assert.equal(result.card.state, "active");
  assert.deepEqual(result.displayLines, ["Need answer?"]);
});

test("does not resurrect a question after the user answers", () => {
  const result = classifyTranscript({
    session: codexSession,
    entries: [
      {
        stream: "stdout",
        timestamp: "2026-05-06T23:00:00.000Z",
        chunk: "Need answer?\n"
      },
      {
        stream: "user",
        timestamp: "2026-05-06T23:00:01.000Z",
        chunk: "[user] answer\n"
      },
      {
        stream: "system",
        timestamp: "2026-05-06T23:00:02.000Z",
        chunk: "[steer] instruction injected\n"
      },
      {
        stream: "stdout",
        timestamp: "2026-05-06T23:00:03.000Z",
        chunk: "received:answer\n"
      }
    ]
  });

  assert.equal(result.card.state, "done");
  assert.notEqual(result.card.category, "question");
  assert.deepEqual(result.displayLines, ["received:answer"]);
});

test("classifies decision prompts as active decision cards", () => {
  const result = classifyTranscript({
    session: codexSession,
    entries: [
      {
        stream: "stdout",
        timestamp: "2026-05-06T23:00:00.000Z",
        chunk: "Decision needed: choose Option A or Option B.\n"
      }
    ]
  });

  assert.equal(result.card.category, "decision");
  assert.equal(result.card.state, "active");
});

test("keeps stopped waiting sessions active even when the output looks complete", () => {
  const result = classifyTranscript({
    session: {
      provider: "claude",
      command: "claude",
      run_state: "waiting"
    },
    entries: [
      {
        stream: "stdout",
        timestamp: "2026-05-06T23:00:00.000Z",
        chunk: "Completed the implementation and tests passed.\n"
      }
    ]
  });

  assert.equal(result.card.category, "waiting");
  assert.equal(result.card.state, "active");
  assert.deepEqual(result.card.options, ["Continue", "Summarize result", "Start next task"]);
});
