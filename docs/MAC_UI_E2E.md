# Mac UI E2E Checks

Date: 2026-05-06

## Goal

Prove the visible SteerMac card composer can send a reply through the real app path:

`TextField Return -> LocalSteerStore.send -> steer send -> SteerAgent -> wrapped PTY -> active card resolved`

## Current Manual Automation

The current repository is a SwiftPM macOS executable, not an `.app` bundle with an Xcode UI test target. For now, UI E2E is run with a temporary `STEER_HOME`, a fake wrapped PTY session, a foreground SteerMac process, and AppleScript/System Events.

Successful run:

```text
Input: ui answer
Wrapper output: received:ui answer
Active cards before: 1
Active cards after: 0
```

Observed transcript rows:

```text
system  [steer] registered custom session ...
stdout  Need answer?
user    [user] ui answer
stdout  ui answer
system  [steer] instruction ... injected
stdout  received:ui answer
```

## AppleScript Path

The passing path focuses the SwiftUI text field before pressing Return:

```applescript
tell application "System Events"
  tell process "SteerMac"
    set frontmost to true
    set focused of text field 1 of group 1 of window 1 to true
    keystroke "ui answer"
    key code 36
  end tell
end tell
```

Directly setting the text field `value` is not enough because it bypasses SwiftUI `.onSubmit`.

## Testability Notes

- `ReplyDock` exposes `reply-input` and `reply-send` accessibility identifiers for future XCUITest or AppKit automation.
- The current check still depends on Accessibility permission for System Events.
- A packaged `.app` target or Xcode project should add a durable UI test target later.
