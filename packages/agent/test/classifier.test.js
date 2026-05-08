import test from "node:test";
import assert from "node:assert/strict";
import { classifyTranscript, terminalScreenText, transcriptDisplayLines } from "../src/classifier.js";

const codexSession = {
  provider: "codex",
  adapter_kind: "codex-app-server",
  command: "codex",
  run_state: "waiting"
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

test("removes Codex working repaint suffix from question lines", () => {
  const lines = transcriptDisplayLines("• Hi. What would you like to work on?•Work");

  assert.deepEqual(lines, ["• Hi. What would you like to work on?"]);
});

test("renders terminal repaint output from the final screen state", () => {
  const screen = terminalScreenText("\x1B[1;1HWorking\x1B[1;1H\x1B[K• Hi. What would you like to work on?");
  const lines = transcriptDisplayLines("\x1B[1;1HWorking\x1B[1;1H\x1B[K• Hi. What would you like to work on?");

  assert.equal(screen, "• Hi. What would you like to work on?");
  assert.deepEqual(lines, ["• Hi. What would you like to work on?"]);
});

test("preserves logical lines from long provider-native reports", () => {
  const report = Array.from({ length: 72 }, (_, index) => `Line ${String(index + 1).padStart(2, "0")}: completed step`).join("\n");
  const lines = transcriptDisplayLines(report);

  assert.equal(lines.length, 72);
  assert.equal(lines[0], "Line 01: completed step");
  assert.equal(lines.at(-1), "Line 72: completed step");
});

test("keeps paragraph breaks and indentation in provider-native reports", () => {
  const lines = transcriptDisplayLines(`
    Completed:
    - Updated transcript parsing
      - Preserved nested detail

    Next:
    Run verification.
  `);

  assert.deepEqual(lines, [
    "Completed:",
    "- Updated transcript parsing",
    "  - Preserved nested detail",
    "",
    "Next:",
    "Run verification."
  ]);
});

test("filters Claude running status repaint lines", () => {
  const lines = transcriptDisplayLines(`
    ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt
    Cultivating…running stop hooks… 0/3 · 39s · ↓1.4k tokens)
    Cultivating…
    1
    Cultivating…
    *Worked for 39s
    +Crunching…85
    Crunching…5
    *Crunching…9
    *Baked for 3s
  `);

  assert.deepEqual(lines, ["[no transcript yet]"]);
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

test("does not open an active card while the session is still running", () => {
  const result = classifyTranscript({
    session: {
      provider: "codex",
      adapter_kind: "codex-app-server",
      command: "codex",
      run_state: "running"
    },
    entries: [
      {
        stream: "stdout",
        timestamp: "2026-05-06T23:00:00.000Z",
        chunk: "Need answer?\n"
      }
    ]
  });

  assert.equal(result.card.category, "progress");
  assert.equal(result.card.state, "done");
  assert.deepEqual(result.card.options, []);
});

test("does not classify interactive PTY repaint text as a content source", () => {
  // While the session is just starting and no trusted output has arrived,
  // we surface a ready card. The card body must NOT be sourced from raw PTY
  // (no "Need answer?" leaking in); it must use the canned ready summary.
  const result = classifyTranscript({
    session: {
      provider: "claude",
      adapter_kind: "pty-bridge",
      command: "claude",
      run_state: "running"
    },
    entries: [
      {
        stream: "pty",
        timestamp: "2026-05-06T23:00:00.000Z",
        chunk: "Cascading… (20s · ↓784 tokens)\r\n› user text echoed in the prompt\r\nNeed answer?\r\n"
      }
    ]
  });

  assert.equal(result.card.category, "waiting");
  assert.equal(result.card.state, "active");
  assert.match(result.card.summary, /session opened/);
  assert.deepEqual(result.displayLines, ["[no transcript yet]"]);
});

test("prefers provider report events over noisy interactive PTY output", () => {
  const result = classifyTranscript({
    session: {
      provider: "claude",
      adapter_kind: "pty-bridge",
      command: "claude",
      run_state: "waiting"
    },
    entries: [
      {
        stream: "pty",
        timestamp: "2026-05-06T23:00:00.000Z",
        chunk: "Cultivating…running stop hooks… 0/3 · 39s · ↓1.4k tokens)\n"
      },
      {
        stream: "report",
        timestamp: "2026-05-06T23:00:01.000Z",
        chunk: "Decision needed: choose Option A or Option B before I continue.\n"
      }
    ]
  });

  assert.equal(result.card.category, "decision");
  assert.equal(result.card.state, "active");
  assert.deepEqual(result.displayLines, ["Decision needed: choose Option A or Option B before I continue."]);
});

test("does not resurrect a question after the user answers", () => {
  const result = classifyTranscript({
    session: {
      provider: "codex",
      adapter_kind: "codex-app-server",
      command: "codex",
      run_state: "running"
    },
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

test("keeps disconnected sessions out of the active queue", () => {
  const result = classifyTranscript({
    session: {
      provider: "claude",
      command: "claude",
      run_state: "disconnected"
    },
    entries: [
      {
        stream: "stdout",
        timestamp: "2026-05-06T23:00:00.000Z",
        chunk: "Need answer?\n"
      }
    ]
  });

  assert.equal(result.card.category, "disconnected");
  assert.equal(result.card.state, "done");
});
