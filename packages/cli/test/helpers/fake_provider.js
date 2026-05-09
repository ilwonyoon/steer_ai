#!/usr/bin/env node
// Test-only fake CLI that imitates codex/claude turn cycles closely
// enough to exercise the wrapper + agent + classifier path. Reads
// instructions on stdin, then drives a deterministic response based on
// a control file that the test sets up.
//
// Control protocol — the test writes a JSON file at $STEER_FAKE_PLAN
// describing the response sequence:
//
//   {
//     "turns": [
//       {
//         "preamble": "claude is thinking…\n",   // optional, emitted first
//         "responseBytes": 12000,                 // total bytes of body
//         "responseDelayMs": 30000,               // emitted over this duration
//         "stopHook": true,                       // emit Stop signal at end
//         "ptyRepaints": 4                        // sprinkle PTY repaint chunks
//       },
//       ...
//     ]
//   }
//
// Each line on stdin consumes the next turn entry.
//
// We don't try to be a real PTY — node-pty wraps us with a real one,
// which is the actual test surface we care about.

import fs from "node:fs";
import readline from "node:readline";
import { setTimeout as delay } from "node:timers/promises";

const planPath = process.env.STEER_FAKE_PLAN;
if (!planPath || !fs.existsSync(planPath)) {
  process.stderr.write("[fake-provider] missing STEER_FAKE_PLAN\n");
  process.exit(1);
}

const plan = JSON.parse(fs.readFileSync(planPath, "utf8"));
let turnIndex = 0;

// Banner emitted at start so the wrapper sees first PTY data and the
// session feels alive.
process.stdout.write("> ");

const rl = readline.createInterface({ input: process.stdin });

rl.on("line", async (line) => {
  if (!line.trim()) {
    process.stdout.write("> ");
    return;
  }
  const turn = plan.turns[turnIndex] ?? plan.turns[plan.turns.length - 1];
  turnIndex += 1;
  await runTurn(line, turn);
  process.stdout.write("> ");
});

async function runTurn(input, turn) {
  // Echo the user's instruction, mimicking codex's "› <input>" line.
  process.stdout.write(`› ${input}\n`);

  if (turn.preamble) {
    process.stdout.write(turn.preamble);
  }

  const repaintCount = turn.ptyRepaints ?? 0;
  const stages = repaintCount + 1;
  const stageDelayMs = (turn.responseDelayMs ?? 0) / stages;

  if (turn.responseBytes && turn.responseBytes > 0) {
    const chunkSize = Math.max(1, Math.floor(turn.responseBytes / stages));
    for (let stage = 0; stage < stages; stage += 1) {
      if (stage > 0 && repaintCount > 0) {
        // ANSI cursor / repaint sequence — should be classified as PTY
        // noise, not as model output.
        process.stdout.write("\x1b[2K\x1b[1G⠋ working… \x1b[0m");
      }
      const slice = "x".repeat(chunkSize);
      process.stdout.write(slice + "\n");
      if (stageDelayMs > 0) await delay(stageDelayMs);
    }
  } else if (turn.responseDelayMs > 0) {
    await delay(turn.responseDelayMs);
  }

  if (turn.stopHook) {
    // The test driver, not the fake, fires `steer hook claude Stop` —
    // we just mark our log so the test can confirm we got here.
    fs.appendFileSync(
      planPath + ".log",
      `turn ${turnIndex - 1} done at ${Date.now()}\n`
    );
  }
}

process.on("SIGTERM", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));
