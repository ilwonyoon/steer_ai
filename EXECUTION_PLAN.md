# Steer Execution Plan

Last updated: 2026-05-08 (ready-card + terminal-typing handoff)

## Purpose

This is the master execution document for Steer. Use it to track what we are building, why the current architecture exists, what is in scope for each phase, and which decisions have already been made.

Steer is a macOS-first AI action queue for CLI coding agents. The core loop is simple: capture reports from multiple AI CLI sessions, surface stuck or waiting sessions as prioritized action cards, and inject user replies or proactive instructions back into the correct session so work does not stall.

## Source Documents

- `DESIGN.md`: visual system and interaction direction.
- `AGENTS.md`: contributor and agent workflow guide.
- `docs/CLASSIFIER_CONTRACT.md`: card classifier input/output and lifecycle rules.
- `docs/MAC_UI_E2E.md`: current Mac UI end-to-end validation notes.
- `docs/DOGFOOD_NOTES.md`: living log of observations during the dogfood week.
- `docs/SETTINGS_PLAN.md`: phased settings/UX backlog and iOS sync prerequisites.
- Backtick Memory `Steer / prd`: product requirements and positioning.
- Backtick Memory `Steer / tech-spec`: technical architecture and implementation notes.

Keep this document focused on execution. Durable product or architecture changes should also be reflected in the source documents above.

## Current Product Decisions

- Steer is an AI action queue, not a full chat mirror.
- The default UX is an action card stack, not a chat timeline.
- Opening a card shows a Claude/Codex-style session detail with full context and reply controls.
- The Mac app should start as a focused mobile-width utility window, 375px wide x 812px tall, so the core stack ports cleanly to iOS.
- The UI should feel iOS-native and use Liquid Glass sparingly for app chrome, navigation controls, sheets, and larger floating surfaces. Do not use it for card reply chips/input.
- The main card bottom should be a reply input with suggested chips above it, not Skip/Snooze/Done buttons.
- The main card body should show the last actionable terminal block as the primary trust surface. AI summary is secondary.
- Rooms are grouping/filtering constructs, and users may later create multiple rooms.
- Room membership and session invitation/routing are follow-up specs.
- v1 is Mac-first and local-first.
- The core loop requires bidirectional control: report capture plus instruction injection.
- Hook-only mode is not sufficient for the product. It can only be a read-only fallback.
- Happy is a reference implementation and possible source for wrapper/pty learnings, not the product architecture to fork wholesale.
- Design direction: Tinder-style card stack for primary triage, light terminal report cards for card content, Claude/Codex-style session detail, Instagram DM for reply lightness, Gmail/Smart Reply for quick responses, and Linear for technical status and metadata.

## Target v1 Architecture

```text
Steer.app
  - SwiftUI/AppKit shell
  - Menu bar and action queue UI
  - Notifications
  - Local API client

SteerAgent
  - Per-user background agent / Login Item
  - Session registry
  - SQLite single writer
  - Message and instruction store
  - Classification orchestration
  - Instruction delivery queue

steer CLI wrapper
  - User launches: steer claude / steer codex
  - Owns child process pty
  - Streams transcript and state to SteerAgent
  - Injects pending instructions into target stdin
```

Prototype may use TypeScript/Node for the wrapper and agent to move quickly. Production should evaluate a signed Swift or Rust `SteerAgent`, XPC for app-to-agent communication, and a minimal signed wrapper.

## Execution Phases

### Phase 0: Repository Foundation

Goal: make the repository useful for future implementation.

- [x] Create `DESIGN.md`.
- [x] Create `AGENTS.md`.
- [x] Push initial docs to GitHub.
- [x] Add `README.md` with product summary and local setup notes.
- [x] Add `docs/` directory for PRD, tech spec exports, and research notes.
- [x] Decide initial source layout: `apps/mac`, `packages/agent`, `packages/cli`, `docs`.
- [x] Add static card-stack UX prototype in `apps/prototype`.

### Phase 1: Wrapper Spike

Goal: prove we can own a CLI session and safely inject input.

- [x] Study current `slopus/happy` wrapper/session code.
- [x] Build minimal `steer claude` wrapper.
- [x] Build minimal `steer codex` wrapper.
- [x] Capture stdout/stderr transcript chunks.
- [x] Detect prompt-ready / waiting states for Claude stream-json result events.
- [x] Inject single-line instruction into a wrapped process.
- [x] Test multiline injection behavior.
- [x] Add Claude hook bridge for Stop/Notification events while preserving wrapper-owned input.
- [x] Document failure cases and edge cases.

Exit criteria:
- A wrapped Claude or Codex session can receive an instruction from another local process.
- Injection does not corrupt output during normal waiting states.

### Phase 2: Local Agent And Storage

Goal: centralize session state, messages, and instruction delivery.

- [x] Define SQLite schema for `Room`, `Session`, `Message`, `Instruction`, and `MetricEvent`.
- [x] Implement `SteerAgent` as the single writer.
- [x] Add Unix domain socket or local IPC API.
- [x] Stream wrapper events into the agent.
- [x] Persist session state transitions.
- [x] Persist pending/injected/failed instruction status.
- [x] Add crash/reconnect behavior for wrapper processes. *(agent_link with auto-reconnect, register replay, priority-aware buffer)*

Exit criteria:
- Multiple wrapped sessions can stream into one local store.
- Instructions are queued, delivered, and status-tracked.

### Phase 3: Mac App Prototype

Goal: make the core loop usable from a native Mac UI.

- [x] Create SwiftUI macOS app shell.
- [x] Add menu bar status item.
- [x] Build default action card stack view.
- [x] Open card into Claude/Codex-style session detail.
- [x] Show session badges and state pills.
- [x] Render stopped/actionable report, decision, blocker, completion, and question cards.
- [x] Add quick reply / quick instruction chips above the input field.
- [x] Add detail composer with target session selection.
- [x] Pivot card content from large summary cards to terminal-tail excerpts.
- [x] Read stopped/actionable cards from local SQLite without turning running sessions into live terminal mirrors.
- [x] Send replies from the card/detail composer through `steer send`.
- [x] Verify card composer Enter key sends through the real Mac UI path.
- [x] Add macOS notifications for new active action cards.
- [x] Add local `.app` bundle script for notification-capable dogfooding.
- [x] Compact action card carousel for waiting cards (replaces live-session chip strip).
- [x] Per-cwd accent hue strip on card header + compact preview header (light/dark aware).
- [x] Git branch label on session header (worktree-aware).
- [x] Menu bar count badge ("Steer · N waiting"); left click activates, right click opens menu.
- [x] Multi-line reply box that grows upward (Shift+Enter newline, Enter sends).
- [x] Inline error banner above the card on send/load failures.
- [x] EmptyState with explicit `cd ~/your/project && steer codex` recipe.
- [x] RunningBadge above main card while live sessions exist.
- [x] Keyboard shortcuts: Cmd+Shift+[ / ] for prev/next card, Cmd+R refresh.
- [x] Document folder TCC handling: spawn sub-processes with `/tmp` cwd + `NSDocumentsFolderUsageDescription` in Info.plist.
- [x] Notification click jumps to that session's card.
- [x] Settings sheet (Cmd+,) for notifications/sound/categories/DND/Always-on-top/Run-at-login. Menu bar Settings… and Open agent log. See `docs/SETTINGS_PLAN.md` Phase 1.

Exit criteria:
- User can monitor multiple sessions and send a reply/instruction from the Mac UI.

### Phase 4: Classification And Triage

Goal: make reports actionable without becoming noisy.

- [x] Define classifier JSON contract.
- [x] Add first heuristic categories: `progress`, `completion`, `waiting`, `decision`, `blocker`, `question`.
- [x] Generate first `ActionCard` rows with `priority`, `summary`, `actionPrompt`, and `options`.
- [x] Add regression tests for real Codex chrome/noise and answered-card lifecycle failures.
- [x] Add regression coverage for Claude Stop hook -> active action card creation.
- [x] Stop treating raw interactive PTY repaint bytes as authoritative action-card content.
- [x] Replace codex PTY heuristic with `~/.codex/sessions/*.jsonl` reader matched by spawn timestamp; emit `event_msg` `agent_message` `final_answer` as `stream:"report"`.
- [x] Auto-install Claude Stop/Notification hooks on first `steer claude` (was opt-in).
- [x] Stream-aware transcript queries (rowid-ordered) so high-volume PTY chunks no longer crowd out trusted entries.
- [x] Debounce action card refresh (200ms) for pty/stdout, flush immediately for report/user.
- [x] Auto-reap zombie sessions and stale active cards on agent startup.
- [x] `steer stats` CLI for session/card/instruction summary + avg reply→inject latency.
- [x] Surface a `waiting` "ready" card the moment a session is registered (run_state=running, no trusted output, no user reply). Card body uses a canned summary; PTY content never sources card body.
- [x] Auto-resolve the active card when the user types directly in the wrapped terminal (wrapper sends `user_input` debounced; agent records a synthetic user transcript entry and resolves the card). Prevents double-replying via Steer + terminal.
- [ ] Run classifier against a broader real transcript sample set.
- [ ] Track false positive and false negative notifications. *(dogfood-driven)*
- [ ] Tune prompts for high precision on `requiresAction`. *(dogfood-driven)*

Exit criteria:
- Classifier reliably separates silent progress from user-action-needed items.

### Phase 5: Dogfooding

Goal: prove Steer reduces operational latency. Tools and template are ready
(`steer stats`, `docs/DOGFOOD_NOTES.md`); pending is one week of real use.

- [ ] Use Steer for real coding sessions for one week. *(in progress, see DOGFOOD_NOTES.md)*
- [x] Tooling for tracking latency/usage available (`steer stats` shows
  session run states, card category × state, last-7-day instruction status,
  avg reply→inject latency).
- [ ] Track false positive and false negative notifications. *(populate via DOGFOOD_NOTES)*
- [ ] Track average answer latency. *(read from `steer stats`)*
- [ ] Track average instruction latency. *(read from `steer stats`)*
- [ ] Track waiting/block duration.
- [ ] Track quick action usage.
- [ ] Track session continuation after intervention.
- [ ] Write dogfooding findings and next-phase decision.

Exit criteria:
- Clear evidence that Steer helps keep multiple AI sessions moving.
- Triaged dogfood notes split into immediate-fix / backlog / deferred.

### Phase 6: Direct Distribution (Notarized .dmg)

Goal: ship Steer to non-developer Mac users without joining the Mac App Store. The current "no App Store sandbox in v1" rule stays in effect; this phase builds out the notarize / sign / auto-update / first-run pipeline that direct distribution requires. Mac App Store is explicitly out of scope here — see "MAS Out of Scope" in the Decision Log.

#### P0 — required to release at all

- [ ] Apple Developer Program membership active; record Team ID in `docs/RELEASE.md` (new file).
- [ ] Generate a *Developer ID Application* signing certificate (not the MAS variant) and import into the keychain used by the release machine.
- [ ] Generate an app-specific password for `notarytool` and store it in keychain via `xcrun notarytool store-credentials steer-notary`.
- [ ] Author `apps/mac/Steer.entitlements` with hardened-runtime entitlements: `com.apple.security.cs.allow-jit`, `com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.cs.disable-library-validation` *(only if node-pty's `spawn-helper` actually fails under hardened runtime — verify before adding)*.
- [ ] Extend `scripts/build-mac-app.sh` (or split into `scripts/release-mac.sh`) to: deep-sign the bundle with `codesign --options runtime --timestamp`, submit with `xcrun notarytool submit ... --wait`, and `xcrun stapler staple` the result.
- [ ] Build the `.dmg` (prefer `create-dmg` for the layout; fallback `hdiutil create`). Sign + staple the `.dmg` itself, not just the inner `.app`.
- [ ] Drive `CFBundleShortVersionString` and `CFBundleVersion` from the current git tag at build time so each release has a unique build number.
- [ ] Verify spawn paths under hardened runtime: `node-pty` `spawn-helper`, `node packages/agent/src/agent.js`, `steer send`, `sqlite3`. Capture which entitlements are actually needed in `docs/RELEASE.md`.
- [ ] Provide a 1024×1024 master icon and generate the `.iconset` / `AppIcon.icns`. Replace the current placeholder.

#### P0 — first-run UX without which the product cannot run

- [ ] First-run check: detect whether `steer` CLI is on PATH. If not, offer to install a symlink to `/usr/local/bin/steer` (or `~/.local/bin/steer`). Use an `NSAppleScript` admin elevation only if the user picks the system path.
- [ ] First-run check: detect whether the Claude Stop/Notification hooks are installed; if not, offer to run `steer install-claude-hooks`.
- [ ] First-run check: prompt the macOS Notification authorization (`UNUserNotificationCenter.requestAuthorization`).
- [ ] First-run check: if the bundled launch path needs Documents folder access, trigger the TCC dialog explicitly (already partially done — verify it survives notarization).

#### P1 — needed for sustainable distribution

- [ ] Integrate Sparkle (Swift Package): generate EdDSA key pair, ship the public key in the bundle, keep the private key only on the release machine.
- [ ] Host `appcast.xml` and the `.dmg` artifacts on GitHub Releases. The release script uploads both and runs `generate_appcast` to produce a signed entry.
- [ ] Wire a "Check for Updates…" menu item into the existing status menu and trigger Sparkle's update check on launch (silent if no update).
- [ ] Crash + telemetry: opt-in MetricKit collector that writes to `~/.steer/diagnostics/`. Defer Sentry until we have a real install base.
- [ ] About window: surface app version, agent version, link to `~/.steer/` log folder ("Reveal in Finder"), and a "Copy diagnostics" button that bundles the last N session logs.
- [ ] Privacy + Terms static pages hosted at a stable URL (steer.ai or a GitHub Pages fallback). Sparkle's network call alone is enough that we should publish a one-page privacy statement.

#### P1 — code health for shipping

- [ ] Decide whether to keep the Python `pty_bridge.py` fallback. If we ship to non-developers, the system Python is unreliable; the cleaner path is to drop the fallback and treat node-pty as required. Track the decision and the deletion as one item.
- [ ] Verify `SMAppService` "open at login" works for the notarized bundle (it should, but it has historically been brittle; needs a clean-machine test).
- [ ] Add a `make release` (or `npm run release`) entry point that orchestrates: bump version → build → sign → notarize → staple → build dmg → upload to GitHub Releases → regenerate appcast.

#### P2 — polish, not blockers

- [ ] Korean localization of the Settings, status menu, and first-run flow.
- [ ] Marketing page (steer.ai landing) with download link and short demo loop.
- [ ] Optional analytics opt-in: aggregate counters for session count and reply latency, never raw transcripts. Stay aligned with the operating rule "Don't send raw transcripts to remote services without an explicit user-controlled setting."

Exit criteria:

- A non-developer Mac user can download a notarized `.dmg`, drag-install, run through first-run, and receive their first card from a `steer codex` session — all without the terminal or developer tooling being involved beyond installing the CLI symlink.
- An update can be shipped end-to-end (bump → sign → notarize → appcast → user receives prompt → user installs) on the release machine in under 30 minutes of human time.

## Current Backlog

- [x] Create `README.md`.
- [x] Export Backtick PRD and Tech Spec into `docs/`.
- [x] Write Happy wrapper research note.
- [x] Choose prototype stack: Node agent first vs Swift/Rust agent first.
- [x] Define v1 SQLite schema.
- [x] Define local IPC protocol.
- [x] Create first wrapper spike.
- [x] Create Mac app skeleton.

## Decision Log

### 2026-05-06: Product Framing

Steer is framed as an AI action queue / operations room, not just a decision triage tool. The user should be able to receive reports, answer questions, and proactively instruct sessions.

### 2026-05-06: Card Stack Primary UX

The default UI is a Tinder-style action card stack for stuck, waiting, decision, completion, and idle AI sessions. Chat/message views are secondary detail surfaces opened from a card. The detail should feel closer to Claude/Codex session context than a pure DM thread, while reply surfaces can keep Instagram DM-like lightness.

### 2026-05-06: Focused Mac Window

The Mac app should default to a mobile-like focused utility window, 375px wide x 812px tall. This keeps the card stack and detail flow portable to iOS while still allowing Mac-only affordances like menu bar entry, keyboard shortcuts, and a wider optional split view later.

### 2026-05-06: iOS-Native Reply Surface

The card stack should use an iOS-native visual model with restrained Liquid Glass where appropriate. The dominant bottom surface is a minimal reply area: suggested chips above an input field. Skip/Snooze/Done should not be primary bottom buttons; secondary queue movement can live in gestures, keyboard shortcuts, or less prominent controls.

### 2026-05-06: Terminal Tail Card

The card stack remains the primary triage interaction, but the card body should not be a large AI-generated summary. Since Steer is an extension of CLI work, the default card content should be the last actionable terminal block: report tail, error, validation result, prompt-ready question, or decision point. AI summary and quick chips help speed up response, but the terminal excerpt is the primary source of trust. The default visual treatment should be a light terminal report card, not a dark terminal rectangle embedded inside a prose card.

### 2026-05-06: Room Model

The default room is unified, but the system should allow multiple rooms later. Session invitation and room routing are follow-up specs.

### 2026-05-06: Wrapper Required

Hook-only mode cannot satisfy the product loop because it does not own stdin. v1 requires wrapper-owned pty for bidirectional control.

### 2026-05-06: Happy Strategy

Happy should be studied and possibly used for wrapper learnings or minimal vendored code. Steer should not become a wholesale Happy fork because the product model is different.

### 2026-05-06: Provider Control Adapter Strategy

Happy research showed that current Happy is not simply a raw pty wrapper. Claude uses Agent SDK/hooks/session scanning, and Codex uses `codex app-server` JSON-RPC. Steer should define provider control adapters and use provider-native control channels where stable, with raw pty as fallback.

### 2026-05-06: Node Wrapper Spike

The first implementation spike uses Node for speed: a Unix domain socket `SteerAgent`, a `steer wrap -- <command>` wrapper, provider shims for `steer claude` and `steer codex`, transcript logs under `~/.steer/sessions`, and `steer send <sessionId> <instruction>` for local instruction injection. It first proved bidirectional delivery with a wrapped `node -i` REPL, then moved default local launches onto a PTY bridge so `steer claude` and `steer codex` behave like normal terminal CLIs.

Multiline injection now uses provider-specific PTY formatting. Claude/Codex multiline prompts are sent with bracketed paste plus a final submit key; generic custom wrappers preserve raw multiline text. Regression tests cover the input formatter, and an interactive Codex smoke test returned `two` for a multiline prompt.

Claude hook bridge is now available for cleaner action-card creation. `steer install-claude-hooks` writes `.claude/settings.local.json` commands for Stop/Notification/StopFailure/SessionEnd, and `steer claude` exports `STEER_SESSION_ID` so hook events attach to the wrapped session. Stop hooks append `last_assistant_message` to the transcript and mark the session waiting; waiting sessions stay as active cards even when the final message looks like a completion report. Replies still use the wrapper-owned PTY channel.

### 2026-05-06: PTY Is Transport, Not Report Source

Dogfooding showed that Claude/Codex interactive TUIs repaint screens, move cursors, echo user input, and emit transient status lines. Using that same byte stream as card content caused repeated text, broken wrapping, and user input showing up inside Steer cards. Interactive PTY output is now treated as transport/debug transcript, not authoritative action-card evidence. Action cards should come from provider-native reports (`report` stream), Claude Stop hook `last_assistant_message`, Codex app-server events, or semantic headless stdout/stderr. This favors trust over recall until every provider has a structured report path.

The wrapper now tries Node `node-pty` for default interactive launches, with the Python PTY shim retained as a runtime fallback. Local verification on Node 25.4.0 showed `node-pty` can fail with `posix_spawnp failed`, so the next durable implementation option is a packaged Swift/Rust helper rather than more regex filtering.

### 2026-05-06: Claude Stream JSON Adapter

Claude should be the first real provider target. `steer claude --headless` uses Claude Code stream-json mode and sends user instructions as JSON lines. `steer claude` now defaults to the interactive PTY bridge so it behaves like a normal terminal Claude session. A low-budget headless smoke test returned `STEER_CLAUDE_OK`, proving that SteerAgent can inject an instruction into Claude Code and receive output back through the stream.

### 2026-05-06: Codex App-Server Adapter

`steer codex --headless` uses `codex app-server --listen stdio://`, initializes JSON-RPC, starts a Codex thread, sends idle instructions with `turn/start`, streams agent deltas back to the terminal and transcript, and returns the session to `waiting` after `turn/completed`. `steer codex` now defaults to the interactive PTY bridge so it behaves like a normal terminal Codex session. A headless smoke test returned `STEER_CODEX_WAIT_OK`, proving the provider-native Codex control path works for the basic report/instruct loop.

### 2026-05-06: SQLite Store

`SteerAgent` now owns the local SQLite write path at `~/.steer/steer.sqlite`. The schema includes rooms, sessions, messages, instructions, terminal excerpts, transcript entries, and metric events. Session registration, state transitions, transcript chunks, user instructions, and injection acknowledgements are persisted while active delivery sockets remain in memory.

CLI commands now auto-start `SteerAgent` in the background when the local socket is missing. `steer agent` remains available for manual debugging, but users should be able to run `steer claude`, `steer codex`, `steer sessions`, and `steer send` without a separate startup step.

### 2026-05-06: macOS Strategy

v1 should be a notarized direct-distribution Mac app, not App Store-first. Avoid Accessibility/Input Monitoring by owning the pty through the wrapper.

### 2026-05-07: Codex Session Log Reader

The PTY screen-scraping heuristic for codex (`pty_idle.js`) was structurally fragile: codex output mixes spinner repaints, chrome lines, and the actual model answer in the same byte stream, and any regex that filters chrome ends up either letting noise through or blocking real content. We now read codex's own `~/.codex/sessions/<date>/rollout-<timestamp>-<uuid>.jsonl` file. The wrapper finds the matching jsonl by filename timestamp (within ±30s of `spawnedAt`, immune to other concurrent codex sessions) and emits each `event_msg / agent_message / phase: final_answer` line as `stream:"report"`. The PTY heuristic is disabled for codex; claude still uses Stop hooks (now auto-installed) with PTY heuristic as a fallback.

### 2026-05-07: Workspace Layout Cleanup

The repo previously sat at `~/Documents/Steer_ai/repo/` with stale doc copies in the parent. We collapsed the wrapper directory so the git repo root is `~/Documents/Steer_ai/` directly, repointed `npm link` so `/opt/homebrew/bin/steer` resolves to the Documents copy, and reset `~/Developer/steer_ai` (the abandoned older clone) to clean main. A backup of the pre-move state lives at `~/Documents/Steer_ai_backup_20260507/` for one-week safety.

### 2026-05-08: Ready Card + Terminal Typing Handoff

Two product-level changes to the classifier contract, both driven by dogfood-style observation that the user wanted *something* to happen the moment a session opens, and the user must never be asked to reply to a card while they are answering directly in the terminal:

1. **Ready card**: a freshly registered running session with no trusted output and no user reply now produces a `waiting/active` card titled `… ready` with a canned summary ("session opened; send your first instruction"). PTY repaint never sources this card body. Once any trusted output (report/stdout/stderr) arrives, the card collapses to `progress/silent`.
2. **Terminal typing handoff (superseded 2026-05-08 by Terminal-Running Invariant)**: an earlier iteration sent a `user_input` debounce message and inserted a synthetic `[user] (typed in terminal)` transcript row to dismiss the card. This was replaced the same day with a SQL-gate-based invariant — see "Terminal-Running Invariant" below.

The two contract tests that previously asserted "PTY repaint never produces an active card" were updated to assert "PTY repaint never *sources card body content*" — the active flag is allowed for the ready phase.

### 2026-05-08: Terminal-Running Invariant

Replaces the earlier `user_input` debounce with a structurally simpler rule: **while the user is actively interacting with the wrapped terminal, no card exists.** Removes the "two input sources" race entirely (you can't double-input if there's nothing to reply to).

Implementation:

1. Mac SQL gate (`apps/mac/Sources/SteerMac/LocalSteerStore.swift`): cards only fetched when `run_state IN ('waiting','blocked')` OR `(run_state='running' AND no traffic in report/stdout/stderr/pty/user)`. Pure read-side gate — same card row stays in the DB and naturally re-appears when the AI returns to a stopped state.
2. Wrapper stdin (`packages/cli/src/index.js`): first key after a stopped state debounces a `state=running` message (500ms). Esc (`0x1B`) and Ctrl-C (`0x03`) bytes are detected and immediately send `state=waiting` to restore the card.
3. Agent: removed `user_input` handler and the synthetic `[user] (typed in terminal)` transcript entry. Visibility is now derived from `run_state` + traffic existence, not from injected fake transcript rows.

Validated by direct SQL gate exercise on a sample DB: running+no-traffic shows ready card, running+pty-traffic hides it, waiting/blocked always show, and Stop transition restores visibility even when traffic rows already exist.

### 2026-05-08: MAS Out Of Scope For v1

We are not pursuing the Mac App Store for v1. The v1 architecture intentionally relies on capabilities the App Sandbox forbids or makes very awkward: spawning `steer send` and `sqlite3` from the app, free filesystem access under `~/.steer/`, modifying `~/.claude/settings.local.json` to install hooks, and a long-lived Unix domain socket shared with arbitrary wrapped CLI processes. Refactoring to satisfy the sandbox would require a separate XPC daemon, a group container relocation of the SQLite store and socket, an entitlements rework, and a sandbox-friendly hook installation flow — that is roughly the scope of a v1.5 architecture rewrite, not a polish pass.

The decision: ship v1 as a Developer ID-signed, notarized direct-distribution app with Sparkle auto-update (Phase 6 above). Revisit MAS once dogfooding has validated the product loop and there is real user demand to install through the Store. If we do come back to MAS, the rewrite plan should start from a daemon split and the question "what state actually needs to live outside the container."

### 2026-05-08: Document Folder TCC

Sub-processes spawned by SteerMac (sqlite3, `steer send`) inherited the app's working directory under `~/Documents`, which triggered a macOS TCC consent dialog the first time the app actually accessed any file there. We now spawn those sub-processes with `currentDirectoryURL = /tmp` and declare `NSDocumentsFolderUsageDescription` (plus Desktop/Downloads) in the bundle's Info.plist so the consent persists once granted. `tccutil reset SystemPolicyDocumentsFolder ai.steer.mac` is the recovery step if a prior decision is cached.

## Open Questions

- Should the prototype agent be TypeScript/Node for speed or Swift/Rust for production shape?
- Should app-to-agent communication start with Unix domain sockets or XPC?
- Should Claude v1 use Agent SDK control first, or raw pty first?
- How should prompt-ready detection work for Claude Code and Codex?
- How much provider-specific paste/readiness logic should stay in the Node spike versus move into native adapters?
- How much transcript should be stored locally by default?
- When should iOS sync begin: after Mac dogfooding or earlier?

## Operating Rules

- Do not add App Store sandbox constraints to v1 unless explicitly chosen.
- Do not require Accessibility permissions for core input injection.
- Do not attach to arbitrary existing terminal sessions in v1.
- Do not send raw transcripts to any remote service without an explicit user-controlled setting.
- Keep UI action-card-first. Avoid turning the first version into a chat timeline or terminal dashboard.
- Keep card content terminal-grounded. Avoid returning to large editorial summary cards as the default.
- Keep wrapper, agent, and app responsibilities separate.

## Progress Notes

Use this format for future updates:

```md
### YYYY-MM-DD

Completed:
- ...

Learned:
- ...

Next:
- ...

Risks:
- ...
```

### 2026-05-06

Completed:
- Created initial GitHub repository.
- Added `DESIGN.md`.
- Added `AGENTS.md`.
- Added this execution plan.
- Added `README.md`.
- Exported PRD and Tech Spec into `docs/`.
- Created initial source layout placeholders: `apps/mac`, `packages/agent`, `packages/cli`.
- Added SwiftUI Mac shell in `apps/mac` with 375 x 812 card stack, session detail, provider badges, chips, and reply input.
- Added Node wrapper spike with Unix socket agent, session registration, transcript capture, session listing, and one-line instruction injection.

Learned:
- The original `Documents/Steer_ai` folder had macOS privacy restrictions that blocked normal git operations.
- A working clone now exists at `/Users/ilwonyoon/Developer/steer_ai`.
- A wrapped `node -i` session can receive an instruction from another local process through SteerAgent and execute it.
- Pipe-based stdin injection proves the local loop but does not yet prove Claude/Codex TTY behavior.
- Claude Code stream-json mode can receive a Steer instruction and return output without pty wrapping.
- Codex app-server can receive a Steer instruction through JSON-RPC and return output without pty wrapping.

Next:
- Harden Claude adapter event parsing and waiting/action detection.
- Harden Codex same-turn steering, approval events, and waiting/action detection.
- Add transcript excerpt extraction and classifier-generated action card rows.
- Add menu bar status item and notification shell.
- Decide prototype stack, IPC approach, and first provider adapter target.
