# Sync stability + Cloudflare cost — plan

Two problems we keep hitting:

1. **Mac ↔ iPhone sync drifts in ways that are hard to debug.** Device
   rows pile up, APNS tokens go stale, dev-vs-prod APNS endpoint
   mismatches cause silent drops. Every fix has been reactive.
2. **Cloudflare Workers usage is way ahead of expectations.** One
   active user burned 70k / 100k requests in a day. At this rate the
   free plan caps at 1.4 users.

This doc lays out what's actually causing each and what order to
fix them in.

## Diagnosis

### What's happening at the request level

Per-user steady-state traffic against the relay, measured today
from `wrangler tail`:

| Caller | Endpoint | Cadence | Requests/hour |
|---|---|---|---|
| iOS DevicePresence | `GET /v1/sync/devices` | every 5s | 720 |
| iOS DevicePresence | `GET /v1/sync/sessions` | every 5s | 720 |
| Mac (drain instructions) | `GET /v1/sync/instructions/queued` | every ~2s | 1800 |
| Mac (heartbeat) | `POST /v1/sync/devices` | every 15s | 240 |
| Mac (chip publish, when active) | `POST /v1/sync/sessions` | per 30s heartbeat | 120 |
| Mac (card publish, dedupe) | `PUT /v1/sync/cards/:id` | per state change | ~30 |
| iOS WS | various | persistent | not counted as HTTP |

**~3,600 requests/hour per active user.** A single user awake 16h/day
= 58k requests/day. The 70k figure isn't a bug, it's the design.

### Sync drift root causes

Today's incidents traced back to:

1. **Device rows accumulate forever.** Every iOS reinstall got a new
   `device_id` (per-install UUID), the old row + old APNS token stayed
   in D1. One user → 9 device rows. Each APNS fanout spent a JWT slot
   on dead tokens, hitting `429 TooManyProviderTokenUpdates` before
   the live token's push got out.
2. **APNS endpoint dev/prod toggle is fragile.** Debug-signed iOS
   gives sandbox tokens; relay routes through production endpoint
   unless `APNS_USE_SANDBOX=1` is set. The flag isn't tied to the
   token's environment — it's a global var the operator has to
   remember to flip per deploy.
3. **JWT bearer cache is isolate-local.** Workers spin up new
   isolates per request burst; each gets its own `cachedToken`. Many
   tokens issued in the same minute → 429.
4. **Token rotation isn't observed end-to-end.** Apple rotates iOS
   device tokens occasionally. iOS gets the new one and heartbeats
   it, but if the heartbeat race loses to a fanout in flight, the
   old token sticks around and slowly poisons future fanouts until
   pruned.

## Plan — three phases

### Phase A: Stop the bleeding (1 PR, ~2h)

These are the highest-leverage fixes. Order matters; each lands
on its own.

| # | Change | Effect |
|---|---|---|
| A1 | iOS `DevicePresence` polls every **15s instead of 5s**, AND consolidates `GET /v1/sync/devices` + `GET /v1/sync/sessions` into a single `GET /v1/sync/presence` | -83% request volume from iOS |
| A2 | iOS poll **pauses while the app is backgrounded** (UIApplication didEnterBackground / willEnterForeground) | -60% on top of A1 for typical phone-in-pocket usage |
| A3 | Mac drain-instructions loop trigger on **WS `instruction.queued` push** instead of 2s polling. Keep a 30s sweeper as fallback | -90% Mac drain traffic |

After Phase A: realistic steady-state is **~300 requests/hour per
user** instead of 3,600. 100k cap becomes 13 days of one heavy
user, or 333 users on the free plan.

### Phase B: Stable device identity (1 PR, ~1h)

A2/A3 reduce volume but don't fix the device-pileup loop. This
phase fixes that.

| # | Change | Effect |
|---|---|---|
| B1 | iOS `deviceId` becomes deterministic per (Apple user_id + bundle_id) instead of a fresh UUID per install. Reinstall reuses the same row. | At most 1 iOS row per user. No pileup. |
| B2 | iOS hands `aps-environment` along with each heartbeat. Relay stores it per-device, fanout reads each device's setting to pick sandbox vs production endpoint per-target. | No more global `APNS_USE_SANDBOX` flag. Dev + TestFlight clients can coexist on one relay. |
| B3 | Fanout deletes 410 tokens (already shipped in PR #22), AND the heartbeat path checks for the previous device_id with same Apple user — deletes if found. Belt + suspenders. | Token rotation is non-poisoning. |

### Phase C: Migrate off polling entirely (optional, ~half day)

If costs are still uncomfortable after A+B, the next move is:

- iOS drops `DevicePresence` polling entirely. Mac → iOS chip state
  rides the existing WebSocket as `device.upsert` messages.
- Cloudflare cost falls to WebSocket message count (cheaper than
  HTTP requests on Workers paid plan, free on free plan up to a
  much higher ceiling).

We don't need this until A+B isn't enough. Recording for later.

## What's NOT in this plan

- Sparkle auto-update — already shipped in v0.1.5 release pipeline.
- iOS NSE for notification icon — separate user task (#279).
- Demo mode / SignInPrompt design — separate user decisions.
- Wrangler v4 upgrade — cosmetic warning, no impact (#281).

## Decisions needed before starting

1. **OK to merge polling consolidation (A1) before A2 ships?** A1
   moves to 15s but app-still-in-foreground = 15s × 2 endpoints
   = 8 requests/min. With A2's background pause that's only when
   the phone is open. If A1 ships first the cost drop is small until
   A2 lands.
2. **Phase B's deterministic device_id breaks the existing rows.**
   We need a one-shot migration: on first heartbeat from the new
   iOS build, delete any rows for the same Apple user with a
   different device_id. OK to do this in B1?
3. **Phase C — when?** Default: not now. Revisit after a week of
   real usage on A+B.

## Sequencing

```
A1 → deploy → verify Cloudflare graph drops ~80%
       ↓
A2  → deploy → verify backgrounded phone produces no traffic
       ↓
A3  → deploy → verify Mac instruction-drain rides WS
       ↓
(pause, observe for 1–2 days)
       ↓
B1  → deploy + iOS rebuild
       ↓
B2  → deploy + iOS rebuild
       ↓
B3  → deploy (server-only)
       ↓
(pause, observe)
       ↓
C   → only if A+B isn't enough
```

Each step is its own PR. Phase A items can be batched in one PR if
we're comfortable with the migration; Phase B should be three
separate PRs because the device-row migration in B1 is the
riskiest single change.
