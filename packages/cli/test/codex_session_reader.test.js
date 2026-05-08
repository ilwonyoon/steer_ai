import test from "node:test";
import assert from "node:assert/strict";
import { extractFinalAgentMessage, parseRolloutStartedAt } from "../src/codex_session_reader.js";

test("extracts final assistant message from event_msg", () => {
  const event = {
    timestamp: "2026-05-07T21:40:56.607Z",
    type: "event_msg",
    payload: {
      type: "agent_message",
      message: "Hello world.",
      phase: "final_answer",
      memory_citation: null
    }
  };

  assert.equal(extractFinalAgentMessage(event), "Hello world.");
});

test("ignores reasoning events", () => {
  const event = {
    type: "response_item",
    payload: { type: "reasoning", summary: [], content: null }
  };

  assert.equal(extractFinalAgentMessage(event), null);
});

test("ignores agent_message that is not final_answer", () => {
  const event = {
    type: "event_msg",
    payload: { type: "agent_message", message: "partial", phase: "delta" }
  };

  assert.equal(extractFinalAgentMessage(event), null);
});

test("ignores empty messages", () => {
  const event = {
    type: "event_msg",
    payload: { type: "agent_message", message: "   ", phase: "final_answer" }
  };

  assert.equal(extractFinalAgentMessage(event), null);
});

test("parses rollout filename to local-time epoch", () => {
  const filename = "rollout-2026-05-07T14-50-48-019e046c-02bb-7d41-9b69-042405223269.jsonl";
  const time = parseRolloutStartedAt(filename);
  assert.ok(Number.isFinite(time));

  const expected = new Date(2026, 4, 7, 14, 50, 48).getTime();
  assert.equal(time, expected);
});

test("returns null for non-matching filename", () => {
  assert.equal(parseRolloutStartedAt("garbage.jsonl"), null);
  assert.equal(parseRolloutStartedAt("rollout-bad.jsonl"), null);
});

test("safe on null/undefined/non-object", () => {
  assert.equal(extractFinalAgentMessage(null), null);
  assert.equal(extractFinalAgentMessage(undefined), null);
  assert.equal(extractFinalAgentMessage("string"), null);
  assert.equal(extractFinalAgentMessage(42), null);
  assert.equal(extractFinalAgentMessage({}), null);
  assert.equal(extractFinalAgentMessage({ type: "event_msg" }), null);
  assert.equal(extractFinalAgentMessage({ type: "event_msg", payload: null }), null);
});
