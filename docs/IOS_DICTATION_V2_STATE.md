# iOS Dictation v2 — Spike state (2026-05-15)

Branch: `spike/ios-dictation-v2`. Not merged to main.

## Working pieces

- **Permissions**: speech + mic prompts only fire from explicit
  mic-button tap, never on view appear. Fast-path skips prompt
  when status is already determined.
- **System language**: `SFSpeechRecognizer(locale:)` rebuilt each
  `start()` with `Locale.autoupdatingCurrent`. Falls back to
  `en-US` when system model isn't available. Logged on start as
  `dictation locale: <id>`.
- **Listening UX (takeover pattern)**: TextField cross-fades out,
  full-width waveform + 44pt circular stop button cross-fades in
  (0.25s). Recognized text commits to `reply` only on stop —
  matches ChatGPT / Claude / Gemini.
- **Haptics**: medium impact on record start, light on stop,
  success on send, error on permission deny.
- **Layout**: 56pt input row, mic/send vertically centered on
  trailing edge, leading 16 padding. Waveform sits 20pt off the
  left wall + 20pt off the stop button.

## Broken / unsolved

The pixel-sliding waveform.

**Goal**: bars literally translate from right → left at a steady
pace, the way ChatGPT mac's listening indicator does. New bars
emerge on the right; bars exit on the left through a 0.2-alpha
"faded zone" so they look like they're flowing into the past.

**Current symptom (2026-05-15 23:50)**: bars wobble side-to-side
instead of flowing left, and the leftmost faded zone doesn't
read as faded.

**Root cause hypothesis**: the current implementation in
`ScrollingWaveform` (apps/ios/SteerIOS/ReplyDock.swift) ties the
HStack's `offset(x:)` to `(now - lastShiftTime) / shiftInterval`,
where `lastShiftTime` is a `@Published` value updated by the
audio thread via `DispatchQueue.main.async`. That dispatch +
@Published mutation chain is not phase-locked with the next
audio buffer arrival, so:

1. `progress` overshoots 1 before the next buffer lands, then
   snaps back to 0 — visible as a backwards twitch.
2. When the buffer does land, `samples` and `lastShiftTime` are
   not guaranteed to commit in the same SwiftUI update cycle,
   so the offset reset can happen one frame before / after the
   ring index shift. The eye sees that as a stutter.

## Recommended next attempt

**Decouple visual flow from audio timing.** Instead of trying
to phase-lock the slide animation to audio buffer arrivals:

- Drive the slide off a self-contained TimelineView phase that
  ticks at ~60fps and accumulates a single monotonically
  increasing pixel offset.
- Audio thread only fills the amplitude ring — it does NOT
  drive the slide motion.
- View renders the ring with `HStack.offset(x: -phase % slotWidth)`.
  When phase crosses a slotWidth boundary, the ring index that
  each visible bar maps to advances by one (virtual shift).
- New amplitudes from the audio thread land in the right edge
  of the ring; they show up on screen as the slide carries
  them into view.

This is the pattern ChatGPT / Claude / Gemini almost certainly
use: the row's leftward drift is a UI clock, not an audio clock.

Once that's stable, the faded-zone alpha (leftmost 20 of 32 at
0.2, rest at 1.0) should also become visible because bars will
actually traverse the zone as they age out of the row.

## Files touched in this spike

- `apps/ios/SteerIOS/DictationController.swift` — recognizer,
  audio tap, amplitude ring (32 slots), `lastShiftTime` /
  `shiftInterval` (currently unused by the recommended next
  attempt; can stay or be removed).
- `apps/ios/SteerIOS/ReplyDock.swift` — listening takeover,
  cross-fade transition, ScrollingWaveform (needs rewrite per
  recommendation above).
- `apps/ios/SteerIOS/DictationTestView.swift` — simulator-only
  test surface, gated by `#if targetEnvironment(simulator)` in
  `SteerIOSApp.swift`.

## Test status

- Build (device): green.
- Manual: pixel-sliding visual still failing; recognizer +
  permissions + takeover + haptics all confirmed working on
  device (iPhone 14 Pro, 989C72E4-E090-5170-B3C5-0747986FE558).
- Simulator: SFSpeechRecognizer assets aren't shipped — only
  permission + UI flow can be verified there.

## Merge gate (for when sliding is fixed)

Before merging spike → main:

1. Sliding looks right on device (single-frame eye check).
2. `swift build --package-path apps/mac` clean (Mac side
   unaffected but the spike branch tracks main).
3. `STEER_INTEGRATION=1 npm test` green.
4. `bash scripts/verify-steer-regression.sh` green.
5. Dogfood smoke: open inbox → tap mic → speak → stop →
   transcript appears → send.
</content>
</invoke>