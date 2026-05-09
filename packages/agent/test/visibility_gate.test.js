// The Mac side filters cards through this exact SQL. We unit-test it
// against an in-process SQLite so that any drift in apps/mac/Sources/
// SteerMac/LocalSteerStore.swift is loud and immediate.
//
// If you change the gate clauses in LocalSteerStore.swift, update
// VISIBILITY_GATE_SQL below and add or revise the scenario rows.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const VISIBILITY_GATE_SQL = `
  SELECT ac.id, s.run_state
  FROM action_cards ac
  JOIN sessions s ON s.id = ac.session_id
  WHERE ac.state = 'active'
    AND ac.category IN ('blocker', 'decision', 'question', 'waiting')
    AND (
      s.run_state IN ('waiting', 'blocked')
      OR (
        s.run_state = 'running'
        AND NOT EXISTS (
          SELECT 1
          FROM transcript_entries traffic
          WHERE traffic.session_id = s.id
            AND traffic.stream IN ('report', 'stdout', 'stderr', 'user')
        )
      )
    )
  ORDER BY ac.id
`;

function createGateFixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-gate-"));
  const dbPath = path.join(dir, "gate.sqlite");
  const db = new DatabaseSync(dbPath);
  db.exec(`
    PRAGMA foreign_keys = OFF;
    CREATE TABLE sessions(id TEXT PRIMARY KEY, run_state TEXT NOT NULL);
    CREATE TABLE action_cards(
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      state TEXT NOT NULL,
      category TEXT NOT NULL
    );
    CREATE TABLE transcript_entries(session_id TEXT, stream TEXT);
  `);

  function addSession(id, runState) {
    db.prepare("INSERT INTO sessions(id, run_state) VALUES (?, ?)").run(id, runState);
  }
  function addCard(sessionId, { state = "active", category = "waiting" } = {}) {
    db.prepare("INSERT INTO action_cards VALUES (?, ?, ?, ?)")
      .run(`card-${sessionId}`, sessionId, state, category);
  }
  function addTraffic(sessionId, stream) {
    db.prepare("INSERT INTO transcript_entries(session_id, stream) VALUES (?, ?)").run(sessionId, stream);
  }
  function visibleIds() {
    return db.prepare(VISIBILITY_GATE_SQL).all().map((row) => row.id);
  }
  function close() {
    db.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }

  return { addSession, addCard, addTraffic, visibleIds, close };
}

test("visibility gate: waiting session always surfaces", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "waiting");
    f.addCard("s1", { category: "waiting" });
    assert.deepEqual(f.visibleIds(), ["card-s1"]);
  } finally { f.close(); }
});

test("visibility gate: blocked session always surfaces", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "blocked");
    f.addCard("s1", { category: "blocker" });
    assert.deepEqual(f.visibleIds(), ["card-s1"]);
  } finally { f.close(); }
});

test("visibility gate: running session with no semantic traffic surfaces (ready card)", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "running");
    f.addCard("s1", { category: "waiting" });
    assert.deepEqual(f.visibleIds(), ["card-s1"]);
  } finally { f.close(); }
});

test("visibility gate: running + only PTY repaint still surfaces (pty is not semantic)", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "running");
    f.addCard("s1", { category: "waiting" });
    for (let i = 0; i < 10; i += 1) f.addTraffic("s1", "pty");
    assert.deepEqual(f.visibleIds(), ["card-s1"]);
  } finally { f.close(); }
});

test("visibility gate: running + report traffic hides the card", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "running");
    f.addCard("s1", { category: "waiting" });
    f.addTraffic("s1", "report");
    assert.deepEqual(f.visibleIds(), []);
  } finally { f.close(); }
});

test("visibility gate: running + stdout traffic hides the card", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "running");
    f.addCard("s1", { category: "waiting" });
    f.addTraffic("s1", "stdout");
    assert.deepEqual(f.visibleIds(), []);
  } finally { f.close(); }
});

test("visibility gate: running + user traffic hides the card", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "running");
    f.addCard("s1", { category: "waiting" });
    f.addTraffic("s1", "user");
    assert.deepEqual(f.visibleIds(), []);
  } finally { f.close(); }
});

test("visibility gate: done cards never surface", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "waiting");
    f.addCard("s1", { state: "done", category: "answered" });
    assert.deepEqual(f.visibleIds(), []);
  } finally { f.close(); }
});

test("visibility gate: silent categories never surface", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "waiting");
    f.addCard("s1", { state: "active", category: "progress" });
    assert.deepEqual(f.visibleIds(), []);
  } finally { f.close(); }
});

test("visibility gate: disconnected session is hidden even with active card", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "disconnected");
    f.addCard("s1", { category: "waiting" });
    assert.deepEqual(f.visibleIds(), []);
  } finally { f.close(); }
});

test("visibility gate: Stop transition restores visibility even when traffic exists", () => {
  const f = createGateFixture();
  try {
    f.addSession("s1", "waiting");
    f.addCard("s1", { category: "waiting" });
    for (let i = 0; i < 5; i += 1) f.addTraffic("s1", "stdout");
    assert.deepEqual(
      f.visibleIds(),
      ["card-s1"],
      "after Stop, waiting surfaces despite prior traffic"
    );
  } finally { f.close(); }
});
