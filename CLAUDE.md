# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Steer is a macOS-first **AI action queue** for CLI coding agents (Claude Code, Codex CLI, Gemini CLI, etc.). It is **not** a chat mirror or live terminal preview. The core loop:

```
steer CLI wrapper -> SteerAgent -> Steer.app
       ^                 |
       |                 v
  instruction injection <- user reply / instruction
```

A wrapped session streams reports/state to the agent; the Mac app surfaces only stopped/actionable cards; replies typed in the app are routed back through the wrapper into the wrapped CLI's stdin (or provider control channel).

The repo is in early execution. v1 is local-first and Mac-first. See `EXECUTION_PLAN.md` for current phase/backlog and `DESIGN.md` for the visual/interaction direction.

## Repository Layout

```
apps/mac/             SwiftUI macOS shell (SteerMac, SwiftPM exec, macOS 15+)
apps/prototype/       Static HTML card-stack UX prototype
packages/agent/       Node SteerAgent: Unix socket server, SQLite store, classifier
packages/cli/         Node `steer` CLI: wrapper, provider adapters, send/sessions
scripts/              build-mac-app.sh, verify-steer-regression.sh
docs/                 PRD, TECH_SPEC, CLASSIFIER_CONTRACT, REGRESSION_CONTRACT, etc.
EXECUTION_PLAN.md     Master backlog + decision log (single source of truth for status)
```

The Node side is an npm workspace (`packages/agent`, `packages/cli`). The Mac side is a separate SwiftPM package — they communicate via SQLite at `~/.steer/steer.sqlite` and by shelling out to `steer send`.

## Build, Test, and Run

Node side (root `package.json`, requires Node >= 22.5.0 because the agent uses `node:sqlite`):

```sh
npm test                                       # runs agent + cli tests via node --test
node --test packages/agent/test/foo.test.js    # run a single test file
npm run agent                                  # start SteerAgent manually (debug only)
npm run steer -- <command> [...args]           # invoke the CLI from source
```

Mac app:

```sh
swift build --package-path apps/mac            # compile SteerMac
swift run --package-path apps/mac SteerMac     # raw SwiftPM exec (no notifications)
scripts/build-mac-app.sh                       # build a signed .app bundle for dogfooding
open .build/SteerMac.app                       # launch the bundled app (needed for notifications)
```

Full regression gate (run before any commit touching wrappers, classifier, Mac card loading, notifications, or terminal rendering — see `docs/REGRESSION_CONTRACT.md`):

```sh
scripts/verify-steer-regression.sh             # npm test + swift build + .app build
```

CLI usage (after `npm install` at the root, the `steer` bin is `packages/cli/src/index.js`):

```sh
steer claude              # interactive PTY-bridged Claude session (default)
steer claude --headless   # Claude Code stream-json adapter
steer codex               # interactive PTY-bridged Codex session (default)
steer codex --headless    # Codex app-server JSON-RPC adapter
steer wrap -- <cmd>       # generic PTY wrapper for any command
steer send <sessionId> "instruction" [--attach <image-path>]...
steer sessions
steer install-claude-hooks   # writes Stop/Notification hook commands to .claude/settings.local.json
steer hook claude Stop       # internal: invoked by Claude hooks; reads JSON payload from stdin
```

`steer claude`/`steer codex`/`steer send`/`steer sessions` auto-start `SteerAgent` in the background by spawning `node packages/agent/src/agent.js` if `~/.steer/steer.sock` is missing. You normally do **not** run `steer agent` manually.

## Local State and Environment Overrides

Defaults live under `~/.steer/` (see `packages/agent/src/paths.js`):

- `~/.steer/steer.sock` — Unix domain socket the agent listens on
- `~/.steer/steer.sqlite` — single-writer SQLite store (rooms, sessions, messages, instructions, transcript_entries, terminal_excerpts, action_cards, metric_events)
- `~/.steer/sessions/<sessionId>.log` — per-session transcript

Overrides for isolated tests/dogfood: `STEER_HOME` (entire dir), `STEER_SOCKET`, `STEER_DB`. The Mac app reads the same overrides — set them in the launching shell so the SwiftUI process sees them.

## Architecture (the parts that span files)

### Three processes, one local store

1. **`steer` CLI wrapper** (`packages/cli/src/index.js`): owns the child process (PTY by default via `node-pty` with a Python `pty_bridge.py` fallback). Streams output to the agent and writes injected instructions back into the child's stdin.
2. **`SteerAgent`** (`packages/agent/src/agent.js`): single-writer node process. Listens on the Unix socket; persists every event through `store.js`; runs the classifier (`classifier.js`) on incoming output to upsert one `action_card` per session; routes `send` instructions to the live wrapper socket.
3. **`SteerMac`** (`apps/mac/Sources/SteerMac/`): reads stopped/actionable cards directly from `~/.steer/steer.sqlite` via `LocalSteerStore.swift`. **Sends replies by shelling out to `steer send` — it does not write to the DB or speak the agent socket protocol.**

The Mac app is intentionally **not** a live terminal mirror. Running sessions stay quiet; cards only open when the AI stops and reports a blocker/question/decision/waiting/completion.

### Wire protocol (CLI ↔ agent)

Newline-delimited JSON over a Unix domain socket. Message types include `register`, `output` (with `stream: "stdout" | "stderr" | "pty" | "report" | "system" | "user"`), `state`, `send`, `instruction`, `ack`, `hook_event`, `sessions`. See `packages/agent/src/protocol.js` and the `handleMessage` switch in `agent.js`.

### Provider adapter strategy

There is no single "wrapper" — each provider has a control adapter, with raw PTY as a fallback. `wrapPtyProvider` (default `steer claude` / `steer codex`) drives the interactive TUI; `runClaudeHeadlessAdapter` uses Claude Code's stream-json mode; `runCodexHeadlessAdapter` speaks `codex app-server` JSON-RPC over stdio. Multiline injection uses bracketed-paste + submit for Claude/Codex (`pty_input.js`); generic `steer wrap` preserves raw text.

### What counts as a trusted action-card source (CRITICAL)

This is enforced by tests in `packages/agent/test/classifier.test.js` and `lifecycle_contract.test.js`, and codified in `docs/CLASSIFIER_CONTRACT.md` + `docs/REGRESSION_CONTRACT.md`:

- **Trusted**: `stream: "report"` (provider-native idle reports / Claude Stop hook `last_assistant_message` / Codex `turn/completed`), provider headless stdout/stderr, hook events.
- **NOT trusted**: raw `stream: "pty"` bytes from interactive TUIs. They contain cursor moves, repaint, user echo, status lines. Do **not** make active cards from PTY repaint alone — prefer a silent/done card.
- Only one active card per session. Injecting a user reply must call `resolveActionCardsForSession(sessionId)` so the card closes; the next stopped report is what reopens it.
- Active cards only for `blocker`, `decision`, `question`, or `waiting`. `completion`/`progress`/`answered`/`disconnected` are silent.

If you add a new provider stream or change classifier behavior, update both contract docs and add a regression test that uses a real transcript snippet, not synthetic noise.

## Conventions and Operating Rules

These come from `EXECUTION_PLAN.md` "Operating Rules" and `AGENTS.md` — they are product invariants, not preferences:

- **No App Store sandbox** in v1 unless explicitly chosen; we plan to ship notarized direct-distribution.
- **No Accessibility / Input Monitoring permissions** for core injection — the wrapper owns the PTY instead.
- **Don't attach to arbitrary existing terminal sessions** in v1; sessions must be launched via `steer …`.
- **Don't send raw transcripts to remote services** without an explicit user-controlled setting.
- **Card-stack first**, terminal-tail card content. Don't drift the UI back toward a chat timeline, big editorial summary cards, or a live terminal dashboard.
- **Keep wrapper, agent, and app responsibilities separate.** UI never speaks the socket protocol; the agent is the only SQLite writer; the wrapper never classifies.
- Swift: `PascalCase` types, `camelCase` methods/properties. TypeScript/JS: `kebab-case.ts/.js` filenames. Keep modules small and ownership explicit (UI / session registry / wrapper-pty / classifier / instruction delivery).
- Prioritize test coverage for: PTY injection, session state transitions, SQLite persistence, classifier JSON parsing, instruction delivery failures.

## Mac UI End-to-End Note

There is no XCUITest target yet. The current end-to-end check for the reply path is documented in `docs/MAC_UI_E2E.md` and uses AppleScript/System Events against a foreground SteerMac process with a temporary `STEER_HOME`. `ReplyDock` exposes `reply-input` and `reply-send` accessibility identifiers for future automation. Do not "verify" the Mac UI by reading the diff alone — if you change reply or card-loading behavior, run the AppleScript flow against `.build/SteerMac.app`.
