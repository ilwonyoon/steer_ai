# iOS Dictation (Voice Reply) — Design Document

Date: 2026-05-15
Status: Draft (pre-implementation)
Owner: iPhone client
Target version: v1.1 (post App Store approval of v1.0)

## Problem

ReplyDock's input field already supports the system keyboard's
built-in mic button (dictation). The user wants a faster path: a
mic icon inside the input field itself, no keyboard required, that
turns spoken instruction into text in the same `reply` binding the
send button already consumes.

Trade we accept up front: this is a real new feature, not a wrapper
around system dictation. The iOS keyboard mic button is a different
mechanism — it's owned by the keyboard, only fires while the
keyboard is up, and we have no programmatic hook to trigger it. To
get an in-card mic button we need to drive `SFSpeechRecognizer` +
`AVAudioEngine` ourselves.

## Goals

1. **Tap-to-speak from the card.** User taps a mic icon inside the
   ReplyDock; speech is transcribed live; tap again to stop. No
   keyboard required, no extra screens.
2. **Streaming partial transcript** so the user sees text appear as
   they speak — same UX as ChatGPT iOS.
3. **Editable result.** Final transcript lands in the same `reply`
   binding the send button already consumes. User can correct typos
   in the same field before sending.
4. **Permission UX matches the existing NotificationsRow pattern**:
   first tap triggers system prompt; denied state deep-links to
   Settings; granted state runs silently.
5. **Doesn't fight the keyboard.** If the keyboard is already open,
   tapping mic dismisses it; tapping it again while listening goes
   straight back to keyboard input without losing the transcript.

## Non-Goals

- **Server-side STT.** Apple's on-device + cloud `SFSpeechRecognizer`
  is good enough and stays inside the user's device for the on-device
  models. Avoids privacy / cost / latency from a third-party API.
- **Multi-language switching UI.** Use the device's preferred
  locale; if Korean/English/Spanish users want a different language
  for dictation only, that's v1.2.
- **Mac dictation.** Mac already has a system dictation shortcut
  (fn-fn). We don't add an in-card mic on Mac.
- **Push-to-talk** (hold-to-record). Toggle pattern decided —
  see Decisions below.
- **Auto-send.** Transcript lands in the input field; user still
  taps send. Avoids a misheard word firing an instruction into
  someone's CLI.

## Decisions (locked)

- **UX pattern:** tap-to-toggle (`2B` in the discovery thread). One
  tap starts listening, second tap stops. State indicator: the mic
  icon changes (`mic.fill` → `stop.circle.fill`) plus a faint
  capsule glow on the input border while live.
- **Streaming:** the partial transcript replaces `reply` text live
  as it grows. Final result on stop is the same string.
- **Mic icon position:** right side of the TextField, **left of the
  send arrow** when send is visible, otherwise alone on the right.
  When listening, the send button is hidden (you can't send an
  unfinished transcript). Stop ends listening AND reveals send.
- **Locale:** `SFSpeechRecognizer(locale: Locale.current)`. Falls
  back to `Locale(identifier: "en-US")` if the device locale isn't
  supported.
- **Audio session category:** `.record` (we don't need playback).
  Restore to previous category on stop so the rest of the app's
  audio (notification sound, future TTS) isn't disturbed.

## Architecture

Three new pieces; everything else is unchanged.

```
ReplyDock (existing)
   │
   │  @StateObject var dictation = DictationController()
   │
   ▼
DictationController  ◄──────  SFSpeechRecognizer
   │                          AVAudioEngine
   │                          AVAudioSession
   │
   ├─ @Published state: .idle | .requestingPermission |
   │                    .listening | .denied | .failed
   ├─ @Published partialText: String   // streams to ReplyDock
   ├─ start(append baseText:)
   ├─ stop()
   └─ openSettings() // for denied state
```

### Component 1 — `DictationController` (new file `apps/ios/SteerIOS/DictationController.swift`)

A `@MainActor` `ObservableObject` that wraps Speech + AVFoundation.
One per ReplyDock (not a singleton) so dismissing a card cleanly
tears down the recognizer.

**State machine** (`enum State: Equatable`):

```
.idle ───tap mic───▶ .requestingPermission ───granted───▶ .listening
                            │                                  │
                            │                            tap mic / VAD
                            ▼                                  ▼
                          .denied                            .idle
                          (Settings deep-link)
```

`.failed(reason: String)` is a terminal state we recover from with
a fresh tap. The user-facing surface is a one-line banner; the
recognizer is reset on next start.

**Public API:**

```swift
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The live partial transcript. Empty when not listening; on
    /// stop, holds the final string. ReplyDock observes this and
    /// folds it into the `reply` binding.
    @Published private(set) var partialText: String = ""

    func start(appendingTo baseText: String) async
    func stop()
    func openSettings()
}
```

**Why `start(appendingTo:)` instead of replacing:** the user might
already have typed half a sentence, then want to dictate the rest.
ReplyDock passes the current `reply` value; the controller
remembers it and emits `baseText + " " + recognized` on every
partial.

### Component 2 — ReplyDock changes

- Add `@StateObject private var dictation = DictationController()`.
- New child view `MicButton` placed inside the input-overlay ZStack,
  trailing edge, left of the send button when both visible.
- `.onChange(of: dictation.partialText)` updates `reply` while
  `state == .listening`.
- `.onChange(of: dictation.state)` toggles UI: send button hidden
  when `.listening`, banner shown when `.denied` or `.failed`.
- Permission alert (a single `.alert` modifier) for the denied
  case: "Steer needs microphone and speech recognition access. Open
  Settings?" with a Settings deep-link button.

### Component 3 — Info.plist additions

Two usage descriptions. The strings below are draft; final copy
gets a pass before submission.

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Steer uses the mic to capture spoken replies you dictate inside an action card.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>Steer transcribes your speech so you can reply to AI sessions hands-free. Speech is processed on-device when supported.</string>
```

App Store reviewer notes: both strings name the user action ("you
dictate", "you reply"), not a passive system capability. Apple's
guideline is that usage strings explain what the user gets, not
what the API does.

## File-by-file change list

| File | Change | Risk |
|---|---|---|
| `apps/ios/SteerIOS/DictationController.swift` | NEW | low — single class, fully encapsulated |
| `apps/ios/SteerIOS/ReplyDock.swift` | add MicButton, observe dictation state, fold partialText into reply | medium — existing send/focus paths must keep working |
| `apps/ios/SteerIOS/Info.plist` | add the two NS*UsageDescription keys | low — additive |
| `apps/ios/Steer.xcodeproj/project.pbxproj` | register DictationController.swift | mechanical |

No backend / relay / agent / Mac changes. Pure iOS-side.

## Permission flow

Identical shape to `NotificationsRow`:

1. **First tap (`.notDetermined`)** — request mic via
   `AVAudioSession.sharedInstance().requestRecordPermission`, then
   speech via `SFSpeechRecognizer.requestAuthorization`. Both
   prompts fire in sequence. State stays `.requestingPermission`
   until both return.
2. **Both granted** → transition to `.listening`, start engine.
3. **Either denied** → state `.denied`. Subsequent taps show the
   alert with a Settings deep-link (same `openSettingsURLString`
   helper SettingsView already uses).
4. **Out-of-band revocation** — if the user revokes permission in
   Settings while Steer is in the background, the next `start()`
   throws and lands in `.denied`. No bookkeeping needed; the OS
   tells us when we ask.

## Edge cases

- **Phone call mid-dictation.** `AVAudioSession.interruptionNotification`
  fires; controller stops cleanly and lands in `.idle`. The user
  taps the mic again to resume — by design, we don't try to auto-
  resume.
- **App backgrounded while listening.** `scenePhase` changes to
  `.background`; ReplyDock calls `dictation.stop()`. Without this
  the audio engine eats battery in the background and iOS may kill
  the app for over-budget audio use.
- **Empty transcript.** If the user taps stop before speaking,
  `reply` stays at the original base text — no empty space appended.
- **Network-only locale.** If the device language requires server
  recognition and the device is offline, `SFSpeechRecognitionResult`
  delivers no partials. Controller lands in `.failed("offline")`
  after 5 s with no result; user sees a banner.
- **Concurrent ReplyDocks** (carousel scrolled mid-dictation). The
  controller is owned by the visible card; switching cards
  destroys it (`@StateObject` destructor) and the audio engine
  stops with it. New card → fresh controller, fresh state.

## Step-by-step build plan

Each step is independently verifiable. After each green check the
plan can be paused and shipped as-is without breaking existing
behaviour.

| # | Step | Verify |
|---|---|---|
| 1 | Add Info.plist usage strings + register `DictationController.swift` (empty file) | iOS build pass |
| 2 | Implement `DictationController` — state machine, audio engine, recognizer wiring | unit test: state transitions on permission grant/deny |
| 3 | Add `MicButton` to ReplyDock with `dictation.start/stop` calls; preserve existing send/focus paths | manual: tap mic → permission prompt → "hello world" → transcript in field |
| 4 | Wire `partialText` → `reply` binding while `.listening` | manual: streaming transcript replaces text live |
| 5 | Add denied-state alert + Settings deep-link | manual: deny in Settings, tap mic, expect alert |
| 6 | scenePhase teardown + interruption observer | manual: dictate, lock phone, return → reply field is intact, controller idle |
| 7 | Edge cases — offline language fallback, empty transcript | unit test + manual |
| 8 | Visual polish — capsule border glow during `.listening`, icon swap, send-button hide | screen capture review |

## Success criteria

1. From a card view, tapping mic icon + speaking a sentence + tapping
   stop puts that sentence into the reply field and the send button
   appears.
2. Tapping send dispatches the same `onSend(text)` path the typed
   reply takes — no new branch in `InboxView.send(...)`.
3. Permission denied state shows an actionable alert that opens
   Settings; granting in Settings and returning makes the mic icon
   work without an app relaunch.
4. App backgrounded mid-dictation doesn't drain battery (Energy Log
   in Instruments shows zero audio activity 2 s after background).
5. iOS App Store reviewer notes (next submission): mention the new
   permissions and that transcription is on-device when supported.

## Risks

- **App Store review delay.** First time we ship new permissions;
  reviewer may ask follow-up questions. Mitigation: usage strings
  follow Apple's "name the user-facing benefit" guidance.
- **`SFSpeechRecognizer` partial reliability on first-gen devices.**
  iOS 17+ supports on-device for many languages; older devices
  fall back to network. The "offline → failed" state covers it.
- **TextField cursor jitter during streaming.** SwiftUI re-renders
  on every partial. If perf is bad, we throttle to ~5 Hz updates.

## Open questions

- Should the mic icon be hidden when the keyboard is up (since the
  keyboard's own mic exists)? Current call: keep both visible —
  the in-card mic still beats the keyboard mic because the keyboard
  has to be summoned first. Decision can flip post-dogfood.
- Visual treatment when listening — capsule glow, animated waveform,
  or just icon swap? Default: capsule border tinted accent +
  pulsing dot inside the icon. Polishing in Step 8.
