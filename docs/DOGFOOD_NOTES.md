# Dogfood Notes

A running log of what we observe while using Steer for real coding sessions.
Goal: collect concrete signal that should drive the next round of fixes
*before* expanding scope (e.g. iOS sync). One week minimum.

## How to use this doc

- Add an entry whenever something feels wrong, misses, or surprises.
- Keep entries terse — one line per observation, one block per session if a
  pattern appears.
- Tag entries: `[bug]` `[fp]` (false positive card) `[fn]` (missed card)
  `[ux]` `[idea]`. Multiple tags allowed.
- Run `steer stats` at the end of each day; paste the output below. It is
  the easiest way to spot trend changes (new fail rate, latency drift).

## Daily log

### YYYY-MM-DD

- [bug] short description — session id if relevant — what happened — what
  *should* have happened.
- [fp] card opened that didn't need a reply — what category — what was the
  trigger text.
- [fn] codex stopped and waited but no card opened — the actual transcript
  excerpt.
- [ux] friction observed during real use.
- [idea] something that would make the workflow smoother.

`steer stats` output:

```
Sessions
  ...
Action cards by category × state
  ...
Instructions (last 7 days)
  ...
```

## Patterns to watch

These are the questions we want a one-week sample to answer. Mark with
✅ / ❌ / ⚠️ as evidence accumulates.

- [ ] Does every codex/claude *stop* surface a card within ~1s?
- [ ] Are progress/intermediate outputs ever shown as active cards?
  (should be silent)
- [ ] Does reply close the card immediately and remain closed until the
  next stop?
- [ ] Does the carousel order match the user's mental priority?
- [ ] Do the cwd-based hue tints actually help recognition?
- [ ] Is the running badge useful or just noise?
- [ ] Are notifications fired for the right cards (and never spam)?

## Decisions deferred

When dogfood reveals a question that needs a real product decision, write
it here instead of fixing immediately. The point of the week is to *see*
patterns, not patch reflexively.

- _example_: when codex enters a long edit, should we show a "running"
  card with a live preview, or stay silent? Need to see how often the
  silence feels wrong.

## Stop criteria for the dogfood week

End the week when one of:
- 7 calendar days have passed.
- Two consecutive days produce zero new entries.
- A blocker bug surfaces that prevents normal use (fix that first, restart
  the clock).

After the week: triage entries into (a) immediate fixes, (b) backlog,
(c) deferred-with-rationale. Then make the iOS / sync go-no-go call.
