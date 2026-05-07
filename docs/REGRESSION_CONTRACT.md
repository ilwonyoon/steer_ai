# Steer Regression Contract

These checks define the minimum product loop that must keep working before any UI, wrapper, or classifier change ships.

## Required Lifecycle

1. When a wrapped CLI session merely starts or runs, Steer does not show a live terminal mirror card.
2. When the AI stops and reports completion, question, blocker, or waiting state, Steer opens one card with the last relevant message.
3. When the user sends text from Steer, the current action card for that session is resolved/closed.
4. When the AI resumes/runs, Steer keeps the card closed until the next stopped report.
5. The reopened card shows the completed message with readable formatting, stable line breaks, and no transient repaint/status noise.
6. Disconnected terminal cards disappear automatically and never keep notifying.

## Source Rules

- `report`, provider-native stdout/stderr, and hook/app-server events are trusted action-card sources.
- Raw `pty` output is not a trusted action-card source and must not drive visible action cards.
- The Mac app is not a live terminal preview; it shows stopped/actionable reports only.
- Notifications are only for notifiable stopped/action cards.
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

Expected result: session start/running does not create a card, stopped reports open one readable card, sending from Steer closes it, the next stopped report reopens it, and no repeated notifications fire while the terminal is only repainting progress.
