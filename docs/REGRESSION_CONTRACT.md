# Steer Regression Contract

These checks define the minimum product loop that must keep working before any UI, wrapper, or classifier change ships.

## Required Lifecycle

1. When a wrapped CLI session starts, Steer shows a session card.
2. When the user sends text from Steer, the current action card for that session is resolved/closed.
3. When the AI stops again and reports completion, question, blocker, or waiting state, Steer opens a new card.
4. The reopened card shows the completed message with readable formatting, stable line breaks, and no transient repaint/status noise.
5. Disconnected terminal cards disappear automatically and never keep notifying.

## Source Rules

- `report`, provider-native stdout/stderr, and hook/app-server events are trusted action-card sources.
- Raw `pty` output is not a trusted action-card source. It may be used only as a live session preview fallback.
- Live session preview must prefer semantic OSC 9 provider messages when available.
- Notifications are only for notifiable action cards, not live running-session previews.
- Notification identity is stable per card id; changing repaint summaries must not create repeated notifications.

## Verification Commands

Run before committing changes that touch wrappers, classification, Mac app card loading, notifications, or terminal rendering:

```sh
npm test
swift build --package-path apps/mac
scripts/build-mac-app.sh
```

Manual dogfood check:

```sh
steer codex
steer send <sessionId> "Say READY and wait."
```

Expected result: session appears, send resolves the current card, the next AI report reopens it with readable text, and no repeated notifications fire while the terminal is only repainting progress.
