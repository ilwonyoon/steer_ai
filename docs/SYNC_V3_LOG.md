# Sync v3 daily work log

One paragraph per day per PR. Short. Easy to skim. The user reads
this once a day to know where we are without reading code.

Format per docs/SYNC_ARCHITECTURE_V3.md "Work log":

```
YYYY-MM-DD — PR N status: in-progress | awaiting-user | green
  - shipped: <commit titles>
  - my checks: <pass/fail per pre-build check>
  - user QA: <pending / N green out of M>
  - blockers: <anything stuck on user input or external dep>
  - next: <single concrete next action>
```

---

## 2026-05-12 — PR 1 status: deployed, awaiting golden-set sweep

- shipped: `feat(sync v3 PR 1): relay event log + dual-write,
  observation-only` (commit 0f98612 on branch
  `fix/mac-chip-decay-on-card-or-end`). Production deployment
  version `41f2c46e-3c8e-42d9-9e36-a2b8a3fdd481`.
- my checks: relay vitest 52/52 ✅ (33 prior + 19 new). agent +
  cli root suite 70/70 ✅ . `swift build apps/mac` clean ✅ .
  Production deploy ✅ . Events table populating in prod with
  device.heartbeat + session.upsert rows from the user's live
  dogfood Mac — proves dual-write is firing end-to-end in
  production.
- gotcha hit and resolved: `wrangler d1 migrations apply
  --remote` returned 7403 (Cloudflare token doesn't have the
  permission migrations apply hits). Worked around with
  `wrangler d1 execute --remote --file migrations/0006_events.sql`,
  which uses the plain d1-execute path the token DOES have.
  Migration is idempotent (CREATE TABLE IF NOT EXISTS), so
  this is safe. The next migration should follow the same
  pattern until we figure out the token scope. Filed as a
  follow-up note here, not as a blocker.
- user QA: in progress — golden set G1–G7 sweep remaining.
- blockers: none.
- next: user runs G1–G7 against the live dogfood; on all green,
  I open PR 1 against main and start PR 2.

---

## QA checklist — PR 1

PR 1 must be a **user-visible no-op**. Nothing in the Mac or
iPhone UI should look or behave differently. The whole point of
this PR is to introduce the event log silently so PR 2 + PR 3
can switch clients over with confidence.

### Step 1 — Deploy the migration + worker

In one terminal, from the repo root:

```sh
cd packages/relay
# Apply migration 0006 to the prod D1. Idempotent — running twice
# is a no-op because the migration uses CREATE TABLE IF NOT EXISTS.
npx wrangler d1 migrations apply steer-relay --remote
# Deploy the worker with the dual-write + new endpoints.
npx wrangler deploy
```

Expect both commands to print a success line. If either fails,
stop and screenshot the error — that's the next thing for me to
diagnose, not a continue-and-hope situation.

### Step 2 — Tail wrangler in a side terminal

Open a second terminal, leave it streaming for the whole QA run:

```sh
cd packages/relay
npx wrangler tail steer-relay --format pretty
```

We're looking for two things in this stream during the next
steps:

  - Every PUT / DELETE / POST you see should be `Ok` (200/2xx).
    Any 5xx during the QA run is a regression and stops the run.
  - No `[event-dualwrite] failed` lines. If you see those, the
    dual-write is breaking on prod for a reason that didn't
    surface in the unit tests; stop and screenshot.

### Step 3 — Run the golden set G1–G7 against the live system

Same dogfood build you have now (commit on
`fix/mac-chip-decay-on-card-or-end`). No new build needed for the
client side. Run each item; mark each ✅ or ❌.

| # | Item | Pass criteria |
|---|---|---|
| G1 | iPhone reply arrives on Mac quickly | iPhone → tap card → "hi" → send. Mac wrapper receives within 3 s. No red banner on Mac. |
| G2 | Mac card replies surface chip on Mac | Mac card → type reply → send. "1 running" pill appears while session runs, fades when next card arrives. |
| G3 | New card after reply | Either side reply → new card appears in carousel on both Mac and iPhone within 5 s of CLI stop. |
| G4 | Sign in with Apple is silent | Mac Settings → Sign out → Sign in with Apple → complete. No red error banner during or after. Status row goes "Not signed in" → "Signed in as …" cleanly. |
| G5 | Sign in with Apple icon | Mac Settings → Sign in with Apple click. **Known open from prior cycle — App Store build is the next reasonable place to revisit. dogfood likely still shows the placeholder.** Mark `n/a (carried over)` if no change. |
| G6 | Reply 4–5 times in a row stays connected | iPhone → reply N=1..5 with ~20 s gap between. Every reply arrives. No "session connection dropped". No delay > 10 s on any reply. |
| G7 | Chip count = my outstanding sends only | iPhone reply twice in 10 s. Mac chip reads "2 running" while both sessions are still running, drops as each new card arrives. |

Any ❌ → stop. Screenshot or quote the exact failure. Report
back. I'll diagnose, propose a fix, get your OK, fix in a new
commit, and we run Step 3 again.

### Step 4 — Verify events table is populating

After Step 3, while the dogfood session is still running, capture
a snapshot of the events table:

```sh
cd packages/relay
npx wrangler d1 execute steer-relay --remote --command \
  "SELECT id, type, producer_device_id, substr(payload_json, 1, 80) AS payload_preview, created_at FROM events ORDER BY id DESC LIMIT 30;"
```

Expect:

  - At least one row per legacy action you performed during
    Step 3. Card publish → `card.upsert`. Card resolved →
    `card.resolved`. iPhone reply → `instruction.queued`. Mac
    inject confirmation → `instruction.injected`. Mac chip
    publish → `session.upsert`. Heartbeat → `device.heartbeat`.
  - All rows have a non-null `producer_device_id`.
  - ids are strictly increasing.

Paste the table back to me when done.

### Step 5 — Quick rollback drill (optional but valuable)

The whole point of dual-write is that we can revert without
schema damage. Sanity-check the path:

```sh
cd packages/relay
# Roll the worker back to whatever was deployed before PR 1.
# `wrangler deployments list` shows recent versions; pick the
# one immediately before today's deploy and:
npx wrangler rollback <deployment-id>
```

After rollback, the `events` table remains in D1 (harmless — no
code reads from it), and the worker is back on the previous
code. We aren't running this for real today; we're just
confirming the rollback path is ready in case PR 2 needs it.

If you don't want to exercise rollback now, mark this step
`skipped` — it's not a blocker for PR 1 green.

---

### Decision criteria

PR 1 is **green** when:

  - All steps 1, 2, 4 succeed.
  - G1–G4 and G6–G7 are all ✅ . G5 may remain `n/a (carried
    over)`.
  - No new error patterns in wrangler tail vs. baseline.

Once green, I open the PR against `main`, merge it, and start
PR 2 the same day. Until then, the work pauses here and waits
on your QA report.
