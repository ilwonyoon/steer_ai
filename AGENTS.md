# Repository Guidelines

This file is the shared workflow guide for coding agents working in Steer.
Keep it aligned with `CLAUDE.md`, `README.md`, and the current project state.

## Working Principles

- **Diagnose, then act.** Before writing a fix, capture the exact failure mode with logs, test output, schema dumps, process state, or a minimal repro. If the diagnosis is uncertain, say so before committing to a fix.
- **Keep scope surgical.** Do not bundle unrelated cleanup. Sync architecture work should not touch the wrapper layer unless the task explicitly crosses that boundary; storage work should not change product copy; UI copy work should not refactor persistence.
- **Prefer simple, layer-appropriate tools.** Use proven primitives already in the repo, such as `proper-lockfile` for OS-level agent locking and SQLite for local persistence. Do not add config knobs or dependencies until there is a real need.
- **Reproduce regressions first.** When a user reports a regression, add or run the automated test that reproduces it before changing production code. Then make the minimum fix and rerun the relevant gate.
- **The user owns visual golden-set QA; agents own technical validation.** Do not hand data-layer debugging to the user. Deliver a small visual checklist only after automated checks pass.

For non-trivial work, state the plan as `step -> verification` pairs in the PR description or handoff.

## Project Overview

Steer is a macOS-first AI action queue for CLI coding agents such as Claude Code and Codex CLI. It is not a chat mirror or live terminal preview.

Core loop:

```text
steer CLI wrapper -> SteerAgent -> Steer Mac/iOS apps
       ^                 |
       |                 v
  instruction injection <- user reply / instruction
```

Wrapped sessions stream reports and state to the agent. The apps surface stopped or actionable cards only. Replies typed in the app route back through the wrapper into the wrapped CLI's stdin or provider control channel.

## Project Structure

- `apps/mac/`: SwiftUI macOS shell, SwiftPM executable, macOS 15+.
- `apps/ios/`: SwiftUI iOS app and UI tests.
- `apps/prototype/`: static HTML card-stack UX prototype.
- `packages/agent/`: Node SteerAgent, Unix socket server, SQLite store, classifier.
- `packages/cli/`: Node `steer` CLI, wrappers, provider adapters, send/sessions commands.
- `packages/relay/`: Cloudflare relay for sync and APNS fanout.
- `packages/SteerCore/`: shared Swift package.
- `scripts/`: release, dogfood, screenshot, and regression helpers.
- `docs/`: PRD, tech specs, classifier and regression contracts, launch docs.
- `EXECUTION_PLAN.md`: backlog and decision log.
- `DESIGN.md`: visual and interaction direction.

Keep macOS UI, iOS UI, background agent logic, relay logic, and CLI wrapper code separated. Do not mix prototype scripts into product source directories.

## Build, Test, and Run Commands

Node side, from repo root:

```sh
npm test
STEER_INTEGRATION=1 npm test
node --test packages/agent/test/foo.test.js
npm run agent
npm run steer -- <command> [...args]
```

Mac app:

```sh
swift build --package-path apps/mac
swift run --package-path apps/mac SteerMac
scripts/build-mac-app.sh
open .build/SteerMac.app
```

iOS app:

```sh
xcodebuild -project apps/ios/Steer.xcodeproj -scheme Steer -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
bash scripts/release-ios.sh
```

Relay:

```sh
cd packages/relay && npm test
cd packages/relay && npx wrangler deploy
```

Full wrapper/Mac regression gate:

```sh
scripts/verify-steer-regression.sh
```

## Validation Gates

Run the smallest relevant gate, then broaden when the blast radius crosses layers.

- Any wrapper, classifier, Mac card loading, notification, or terminal rendering change: `scripts/verify-steer-regression.sh`.
- Any agent, wrapper, sync, lockfile, or instruction-delivery change: `STEER_INTEGRATION=1 npm test`.
- Any relay change: `cd packages/relay && npm test`.
- Any Mac app change: `swift build --package-path apps/mac`; build `.build/SteerMac.app` when notification/app-bundle behavior matters.
- Any iOS launch or UI change: simulator build plus the relevant XCUITest slice.
- New behavior gets new tests. A regressed bug gets a regression test.

If a technical gate cannot pass, do not hand the build to the user as ready. Explain the failing gate and residual risk.

## CLI Usage

After `npm install`, the `steer` bin points at `packages/cli/src/index.js`.

```sh
steer claude
steer claude --headless
steer codex
steer codex --headless
steer wrap -- <cmd>
steer send <sessionId> "instruction" [--attach <image-path>]...
steer sessions
steer install-claude-hooks
steer hook claude Stop
```

`steer claude`, `steer codex`, `steer send`, and `steer sessions` auto-start `SteerAgent` if the socket is missing. You normally do not run `steer agent` manually.

## Local State and Environment

Default local state lives under `~/.steer/`:

- `~/.steer/steer.sock`: Unix domain socket.
- `~/.steer/steer.sqlite`: single-writer SQLite store.
- `~/.steer/sessions/<sessionId>.log`: per-session transcript.

Use these overrides for isolated tests and dogfood:

- `STEER_HOME`
- `STEER_SOCKET`
- `STEER_DB`

The Mac app reads the same overrides only if they are present in the shell that launches the app.

## Architecture Rules

Three local processes share responsibility:

1. `packages/cli/src/index.js` owns the child CLI process and PTY/control-channel instruction injection.
2. `packages/agent/src/agent.js` is the single SQLite writer, socket server, classifier runner, and instruction router.
3. `apps/mac/Sources/SteerMac/` reads stopped/actionable cards from SQLite and sends replies by shelling out to `steer send`.

Keep these boundaries intact:

- UI does not speak the agent socket protocol directly.
- The agent is the only SQLite writer.
- The wrapper never classifies.
- Running sessions stay quiet; cards open only when the AI stops and reports an actionable or completed state.

## Trusted Action-Card Sources

This behavior is contractual. See `docs/CLASSIFIER_CONTRACT.md` and `docs/REGRESSION_CONTRACT.md`.

Trusted sources:

- `stream: "report"`
- provider-native headless stdout/stderr
- Claude hook events
- Codex `turn/completed` or equivalent control-channel reports

Not trusted:

- raw `stream: "pty"` repaint bytes from interactive TUIs

Do not create active cards from PTY repaint alone. Only one active card may exist per session. Injecting a user reply must resolve the current action card; the next stopped report reopens a card if needed.

## Product Invariants

- No App Store sandbox for Mac v1 unless explicitly chosen.
- No Accessibility or Input Monitoring permission for core injection; the wrapper owns the PTY.
- Do not attach to arbitrary existing terminal sessions in v1. Sessions must be launched through `steer ...`.
- Do not send raw transcripts to remote services without an explicit user-controlled setting.
- Keep card-stack UX first. Do not drift the apps toward a chat timeline, large editorial summary cards, or a live terminal dashboard.
- Treat CLI output as sensitive; it may contain paths, secrets, or customer data.

## Coding Style

- Swift types use `PascalCase`; Swift methods and properties use `camelCase`.
- TypeScript and JavaScript files use `kebab-case.ts` or `kebab-case.js` unless a framework requires otherwise.
- Keep modules small with explicit ownership: UI, session registry, wrapper/PTY control, classifier, persistence, relay, and instruction delivery.
- Comments should be short and useful. Explain non-obvious races, contracts, and ownership boundaries.

## Testing Guidelines

- Add tests beside the feature they cover.
- For Swift, prefer XCTest names like `testInjectsInstructionWhenSessionIsWaiting`.
- For JS/TS, use `*.test.js` or `*.test.ts`.
- Prioritize coverage for PTY injection, session state transitions, SQLite persistence, classifier parsing, relay fanout, APNS/device registration, and instruction delivery failures.
- For Mac reply/card-loading changes, do not verify by diff alone. Use `docs/MAC_UI_E2E.md` or the relevant app build/dogfood flow.

## Commit and PR Guidelines

- Use concise imperative commits, such as `Fix agent restart send retry` or `Document iOS launch gate`.
- Do not amend after a user-visible failed delivery unless explicitly asked. Put follow-up fixes in a new commit.
- PRs should include a short summary, test notes, screenshots for UI changes, and links to related docs or issues.
- Call out security, privacy, macOS permission, Apple signing, APNS, or data-retention changes explicitly.

## Security and Configuration

Never commit transcripts, API keys, local database files, provisioning profiles, App Store Connect keys, APNS `.p8` keys, or personal shell configuration.

Legal/public launch docs may contain paste-ready metadata, but secrets and account credentials must stay out of the repo.
