# Steer Execution Plan

Last updated: 2026-05-10 (iPhone App Store review gate added)

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
- `docs/CROSS_DEVICE_ONBOARDING_PLAN.md`: Mac-first setup, iPhone sync onboarding, and GitHub Release instructions.
- `docs/IOS_LAUNCH_PLAN.md`: iPhone launch architecture, CloudKit sync plan, and App Store review strategy.
- `docs/IOS_PRE_CONNECTION_ONBOARDING.md`: iOS signed-out, demo, empty, offline, and pre-Mac connection UX spec.
- `docs/legal/`: Privacy Policy, Terms, App Store privacy labels, App Review notes, and launch legal checklist.
- Backtick Memory `Steer / prd`: product requirements and positioning.
- Backtick Memory `Steer / tech-spec`: technical architecture and implementation notes.

Keep this document focused on execution. Durable product or architecture changes should also be reflected in the source documents above.

## Current Product Decisions

- Steer is an AI action queue, not a full chat mirror.
- The default UX is an action card stack, not a chat timeline.
- Opening a card shows a Claude/Codex-style session detail with full context and reply controls.
- The Mac app should start as a focused mobile-width utility window, 375px wide x 812px tall, so the core stack ports cleanly to iOS.
- Text zoom should be workspace-scoped, not app-global: `Cmd++`, `Cmd+-`, and `Cmd+0` adjust the central card/detail transcript reading area while sidebars, metadata, toolbar chrome, and status controls keep their default size.
- The UI should feel iOS-native and use Liquid Glass sparingly for app chrome, navigation controls, sheets, and larger floating surfaces. Do not use it for card reply chips/input.
- The main card bottom should be a reply input with suggested chips above it, not Skip/Snooze/Done buttons.
- The main card body should show the last actionable terminal block as the primary trust surface. AI summary is secondary.
- Rooms are grouping/filtering constructs, and users may later create multiple rooms.
- Room membership and session invitation/routing are follow-up specs.
- v1 is Mac-first and local-first.
- Real iPhone live use is Mac-first: users should install and configure Steer for Mac, start `steer codex` or `steer claude`, enable iPhone Sync on Mac, then sign in on iPhone with the same Apple account.
- iPhone App Store release must be reviewable without a live Mac: the iOS app needs a full demo/offline action inbox path, not only a "connect your Mac" empty state.
- App Store positioning must avoid remote-terminal language. Use "AI coding action inbox"; do not market it as remote shell, terminal control, command runner, or remote desktop.
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
- [ ] Workspace text zoom: `Cmd++`, `Cmd+-`, and `Cmd+0` adjust only the central action card/detail transcript area. Keep surrounding metadata, sidebar/list chrome, toolbar/status controls, and settings UI at system size.
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

- [ ] Apple Developer Program membership active; record Team ID in `docs/RELEASE.md`. *(scaffold landed; user must enroll)*
- [ ] Generate a *Developer ID Application* signing certificate (not the MAS variant) and import into the keychain used by the release machine. *(blocked on enrollment)*
- [ ] Generate an app-specific password for `notarytool` and store it in keychain via `xcrun notarytool store-credentials steer-notary`. *(blocked on enrollment)*
- [x] Author `apps/mac/Steer.entitlements` with the minimal hardened-runtime entitlements (`allow-jit`, `allow-unsigned-executable-memory`). Escalation path (`disable-library-validation`) is documented in `docs/RELEASE.md` for when something actually fails under hardened runtime.
- [x] Extend `scripts/build-mac-app.sh` for hardened-runtime signing + entitlements + version-from-git-tag, and add `scripts/release-mac.sh` that wraps build, signs with the Developer ID identity, runs `xcrun notarytool submit --wait`, and `xcrun stapler staple`s the bundle.
- [x] Build the `.dmg` (`create-dmg` with `hdiutil` fallback) inside `scripts/release-mac.sh`, sign + notarize + staple the dmg as well as the inner `.app`.
- [x] Drive `CFBundleShortVersionString` and `CFBundleVersion` from `git describe --tags --abbrev=0` and `git rev-list --count HEAD` at build time so each release has a unique build number.
- [ ] Verify spawn paths under hardened runtime: `node-pty` `spawn-helper`, `node packages/agent/src/agent.js`, `steer send`, `sqlite3`. Capture which entitlements are actually needed in `docs/RELEASE.md`. *(needs the first signed build to actually exercise.)*
- [x] Provide a 1024×1024 master icon and an `iconutil`-driven `.icns` generator (`scripts/generate-app-icon.sh`). A placeholder master is committed; replace `apps/mac/Resources/AppIcon-master.png` with final art before any release.

#### P0 — first-run UX without which the product cannot run

- [x] First-run check: detect whether `steer` CLI is on PATH. If not, offer to install a symlink to `~/.local/bin/steer`. (System-path symlink with admin elevation deferred — userland path is the safe default.)
- [x] First-run check: detect whether the Claude Stop/Notification hooks are installed; if not, offer to run `steer install-claude-hooks`. Implemented as a status check (parses `~/.claude/settings.local.json` for a steer hook command) plus a button that runs `steer install-claude-hooks` directly.
- [x] First-run check: prompt the macOS Notification authorization (`UNUserNotificationCenter.requestAuthorization`).
- [ ] First-run check: if the bundled launch path needs Documents folder access, trigger the TCC dialog explicitly (already partially done — verify it survives notarization).
- [ ] Implement `docs/CROSS_DEVICE_ONBOARDING_PLAN.md` Mac-first checklist: CLI install, provider verification, notifications, Apple sign-in, iPhone Sync opt-in, first `steer codex` / `steer claude` session, and iPhone install handoff.
- [ ] Mac Settings exposes signed-in Apple state, iPhone Sync toggle, What Syncs review, editable Mac device label, and "keep Steer for Mac running" guidance.
- [ ] GitHub Release notes explain the Mac-first setup order and include iPhone setup once App Store/TestFlight URL exists.

#### P1 — needed for sustainable distribution

- [ ] Integrate Sparkle (Swift Package): generate EdDSA key pair, ship the public key in the bundle, keep the private key only on the release machine.
- [ ] Host `appcast.xml` and the `.dmg` artifacts on GitHub Releases. The release script uploads both and runs `generate_appcast` to produce a signed entry.
- [ ] Wire a "Check for Updates…" menu item into the existing status menu and trigger Sparkle's update check on launch (silent if no update).
- [ ] Crash + telemetry: opt-in MetricKit collector that writes to `~/.steer/diagnostics/`. Defer Sentry until we have a real install base.
- [ ] About window: surface app version, agent version, link to `~/.steer/` log folder ("Reveal in Finder"), and a "Copy diagnostics" button that bundles the last N session logs.
- [x] Draft Privacy Policy, Terms, App Store privacy labels, App Review notes, and legal launch checklist in `docs/legal/`.
- [ ] Privacy + Terms static pages hosted at a stable URL (steer.ai or a GitHub Pages fallback). Sparkle's network call alone is enough that we should publish a one-page privacy statement.
- [x] Relay account deletion API for App Store account-deletion requirements (`DELETE /v1/me`) with route coverage.
- [x] iOS account/settings UI exposes Delete Account, Sign Out, Privacy Policy, and Terms.

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

### Phase 7: iPhone App Store Review Gate

Goal: make the iPhone app approvable as a real native App Store app, not a thin companion shell that fails review when the reviewer has no Mac setup. This phase is a release gate for TestFlight-to-App-Store submission and should be completed before uploading a public App Store candidate.

#### Review Rejection Model

The likely App Review objections are:

- **4.2.3 Minimum Functionality**: if signed-out or no-card states only say "install/open Steer for Mac", the app appears useless without another app.
- **2.1 App Completeness**: reviewers need a complete flow through cards, detail, reply, queued/delivered/failed status, account settings, and policy links without setting up a local Mac agent.
- **4.2.7 Remote Desktop / remote terminal confusion**: wording such as "control terminal", "run commands", "remote shell", or screenshots that look like terminal mirroring can route the app into the wrong policy bucket.
- **5.1.1 Privacy and account deletion**: Sign in with Apple, relay storage, user content sync, Privacy Policy links, and Delete Account must all be complete and consistent.
- **Privacy Nutrition Labels**: App Store Connect must disclose linked Contact Info, Identifiers, and User Content because relay data is stored beyond real-time request handling.

#### P0 — must finish before App Store submission

- [ ] Implement `docs/IOS_PRE_CONNECTION_ONBOARDING.md` as the source of truth for signed-out, demo, signed-in-empty, and Mac-offline states.
- [ ] Treat the `App Review Pass Strategy` section in `docs/IOS_PRE_CONNECTION_ONBOARDING.md` as a submission gate: reviewer can complete the demo flow without Mac, privacy/legal links are reachable before sign-in, account deletion is reachable after sign-in, and Mac-first setup is explained without blocking review.
- [ ] Build **Demo Mode** available from the signed-out screen and from the empty signed-in state. It must show the full native flow: action card stack, detail, terminal excerpt, suggested replies, reply composer, and simulated queued / delivered / failed status.
- [ ] Replace any signed-out dead end with a useful first-run surface: Sign in with Apple, Try Demo, Privacy Policy, Terms, Support, and a short explanation that live delivery requires the user's own Mac.
- [ ] Use Apple's native `SignInWithAppleButton` styling instead of a custom black capsule button.
- [ ] Publish live public URLs for `https://steer.ai/privacy`, `https://steer.ai/terms`, and `https://steer.ai/support`; remove all `TODO` placeholders from legal docs before publishing.
- [ ] Ensure Privacy Policy and Terms are reachable without signing in and from Account/Settings after signing in.
- [ ] Complete Delete Account for Sign in with Apple: reauthenticate as needed, revoke Apple tokens using Apple's revocation flow, call relay `DELETE /v1/me`, clear Keychain token, and return to signed-out state.
- [ ] Add Mac-side **Enable iPhone Sync** consent screen listing exactly what leaves the Mac: card title, summary, short terminal excerpt, suggested replies, project/provider/branch labels, iPhone reply text, and delivery status.
- [ ] Add a setting or launch-time choice for terminal excerpt sync. Default should be conservative: either off until explicitly enabled, or on only after the sync consent screen clearly explains the risk.
- [ ] Align iPhone setup and recovery copy with the Mac-first flow in `docs/CROSS_DEVICE_ONBOARDING_PLAN.md`: install/open Mac app, sign in on Mac, enable iPhone Sync, start `steer codex` or `steer claude`, keep Mac running.
- [ ] Add iOS **What Syncs?** screen reachable before and after sign-in, matching the field list in `docs/IOS_PRE_CONNECTION_ONBOARDING.md`.
- [ ] Add relay-backed Mac device presence/heartbeat (`deviceId`, `platform`, `displayName`, `deviceClass`, `appVersion`, `lastSeenAt`, `syncEnabled`) and an authenticated iPhone status endpoint.
- [ ] Add persistent top-right iOS Mac connection chip using the Mac's recognizable label (`MacBook Air`, `Mac mini`, user display name, or fallback `Mac`) with `Sample`, `No Mac`, `online`, `idle`, `offline`, and `sync issue` states; tapping opens a `Mac Sync Status` sheet with setup/recovery instructions.
- [ ] Update App Store Connect privacy answers from `docs/legal/APP_STORE_PRIVACY_LABELS.md`: Tracking = No; data linked to user includes Contact Info, Identifiers, and Other User Content for app functionality.
- [ ] Finalize App Review notes from `docs/legal/APP_REVIEW_NOTES.md`, including reviewer demo instructions and explicit "not remote terminal / not remote desktop / not arbitrary command launcher" language.
- [ ] Audit App Store metadata, screenshots, onboarding, and in-app copy for banned framing. Avoid: "remote terminal", "remote shell", "control your Mac terminal", "run commands from iPhone", "terminal mirror". Prefer: "AI coding action inbox", "review waiting agent cards", "queue replies to your own Mac sessions".

#### P1 — strong risk reduction before first public release

- [ ] Add secret redaction before card payload publish for common patterns such as API keys, private keys, bearer tokens, `.env` lines, and obvious password assignments. Redaction should run before data reaches the relay.
- [ ] Add server-side retention cleanup for resolved cards and old instruction records, with retention periods reflected in the Privacy Policy.
- [ ] Add a local data deletion/help screen that explains what account deletion removes from the relay and what remains on the Mac under local Steer storage.
- [ ] Add a "What Syncs" inspection screen that shows current sync scope and last sync status.
- [ ] Document production Cloudflare log retention and whether IP/request logs are retained in a way that changes privacy labels.

#### Submission Exit Criteria

- Reviewer can complete the iPhone product loop without a Mac by using Demo Mode.
- Reviewer can verify live relay behavior if review credentials or a prepared Mac account are provided.
- User can see Mac connection state before sending a reply, and offline replies clearly queue instead of pretending to deliver.
- Privacy Policy, Terms, Support URL, Account deletion, and App Store privacy labels are all live and internally consistent.
- The app and metadata frame Steer as an action inbox for the user's own coding agents, not as a remote terminal or remote desktop client.
- TestFlight build passes on-device smoke test for sign-in, card load, reply send, WebSocket reconnect, account deletion, and demo mode.

## Current Backlog

- [x] Create `README.md`.
- [x] Export Backtick PRD and Tech Spec into `docs/`.
- [x] Write Happy wrapper research note.
- [x] Choose prototype stack: Node agent first vs Swift/Rust agent first.
- [x] Define v1 SQLite schema.
- [x] Define local IPC protocol.
- [x] Create first wrapper spike.
- [x] Create Mac app skeleton.
- [ ] Add workspace-scoped text zoom to the Mac app (`Cmd++`, `Cmd+-`, `Cmd+0`) for the central card/detail reading area.

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

### 2026-05-09: Workspace-Scoped Text Zoom

Mac-style `Cmd++` / `Cmd+-` zoom should not scale the whole Steer window. The high-value reading surface is the central action card and session detail transcript, while the surrounding session list, metadata, status pills, toolbar chrome, and settings controls are already appropriately sized.

Implement zoom as a persisted workspace/detail text scale with bounded steps and a reset command:

- `Cmd++`: increase central reading text scale.
- `Cmd+-`: decrease central reading text scale.
- `Cmd+0`: reset central reading text scale.

Implementation plan:

- Add a persisted setting such as `workspaceTextScale` or `detailTextScale`, with conservative bounds around the default, for example `0.9...1.35`.
- Apply the scale only inside the central card/detail transcript environment. Scale text size, line spacing, transcript block padding, and row/message vertical spacing together so the layout remains balanced.
- Keep navigation, sidebars, metadata panes, status pills, quick chips, composer controls, and Settings at system/default size.
- Use explicit menu commands under View, with labels such as `Increase Workspace Text Size`, `Decrease Workspace Text Size`, and `Reset Workspace Text Size`, so users do not expect full-window zoom.
- Add regression coverage or a UI smoke test that verifies the central transcript grows while surrounding chrome does not shift materially.

### 2026-05-09: Relay Backend Mac → Backend E2E

Sign in with Apple + Cloudflare Workers relay verified end-to-end on Mac. The Mac app signs in once via `ASAuthorizationAppleIDProvider`, the worker verifies the Apple identity token against Apple's JWKS, mints a 30-day session JWT (kept in macOS keychain), and the running Steer process publishes every active card to D1 each reload tick. Verified by reading D1 `cards` rows back via REST. Open follow-ups: iOS sign-in + WebSocket card receive (#204) and the launch-time main-window restoration regression (#205, `open .app` shows zero windows; `open -F` works).

### 2026-05-09: iOS Sign-in End-to-End on Real Device

iPhone signs in via Apple, hits the relay, receives WebSocket card upserts. First end-to-end use of the relay path from a real iPhone — fixes iOS-side onboarding crash (#191), CloudKit→Workers pivot follow-through, and `open .app` window restoration regression on Mac (#205, `applicationShouldHandleReopen` + `newDocument:` selector).

### 2026-05-09: Auto-mode App Review Compliance (12 items)

One pass over App Store guideline requirements: legal placeholder docs replaced with launch defaults; server-side Sign in with Apple revocation on account deletion (`/v1/me` DELETE flow); device presence/heartbeat endpoint on the relay; Mac heartbeat publisher every ~60s; Settings "Report an Issue" GitHub deep link on both platforms; iOS "What Syncs?" disclosure and Mac mirror; marketing copy audit; native `SignInWithAppleButton` everywhere (was a custom black capsule, App Store guideline 4.8); Demo Mode (signed-out → sample card stack) for App Review; iOS top-right Mac connection chip + Mac Sync Status sheet; all 5 pre-connection inbox states. Tracks #210-#221.

### 2026-05-10: Connection-Stability Harness (Terminal → Mac → Relay → iPhone)

Four-phase harness covering the entire delivery path. Phase 1 (`packages/agent/test/connection_perf.test.js`, `store_perf.test.js`) measures classifier p50 0.006ms / store SQLite p50 0.081ms — both well under any user-visible budget. Phase 2 (`packages/relay/test/connection_contract.test.ts`) adds 8 contract tests for the Mac→Relay loop. Phase 3 (`apps/ios/SteerIOSTests/CardPayloadMappingPerfTests.swift`) pins iOS markdown mapping at 7µs/card after memoization. Phase 4 (`packages/relay/test/e2e_round_trip.test.ts`) simulates the full 8-hop loop in-process at <2s. Tracks #222-#225.

### 2026-05-10: Security P0 — JWT Device Binding + Delete-Account Local Clear

Two App Store / security P0s. `mintSessionJWT` now binds an optional `deviceId` into the `did` claim; `extractAuthorizedUser` cross-checks `X-Steer-Device-Id` against `did` and rejects mismatches (a stolen token from another device returns 401). Backward compat — tokens without `did` claim continue to work during the rollout window. iOS `deleteAccount()` now funnels through `signOut()` in BOTH success and failure paths so the Keychain token is cleared even if the relay DELETE fails (App Store guideline 5.1.1(v)). 4 new contract tests in `packages/relay/test/device_binding.test.ts`, 2 in `apps/ios/SteerIOSTests/DeleteAccountTokenClearTests.swift`. Tracks #242, #243.

### 2026-05-10: WebSocket Exponential Backoff

`WSReconnectBackoff` in SteerCore (1s, 2s, 4s, 8s, 16s, then 30s capped, ±20% jitter). Replaced the flat 3s sleep both clients used between WS reconnects. Numerical proof in `WSReconnectBackoffTests` (5/5 PASS): 60s outage drops attempts 20 → 6 (3.3×); 10-minute outage drops 200 → 25 (8×). First reconnect still under 2s so a single dropped frame recovers fast. Eliminates the battery drain + Cloudflare bill from network-hiccup retry storms. Tracks #244.

### 2026-05-10: Mac LocalSteerStore Perf Harness

Measured the cost of the `/usr/bin/sqlite3` subprocess fork on every Mac reload. Result: mean 3.7ms, p95 7.5ms across 50 sequential calls — well under the 50ms budget the dashboard's snappy-reload cadence demands. No replacement (in-process SQLite binding) needed; the test stays in the suite (`LocalSteerStorePerfTests`) so a future refactor that pushes p95 over budget fails fast. Tracks #245.

### 2026-05-10: iOS XCUITest Harness (Smoke + Golden + Stress)

11 scenarios across three suites driven from `xcodebuild test`. Smoke (`CardFlowUITests`, ~28s, 3 tests): launch → fixture card → reply send → tab switch. Golden (`GoldenFlowUITests`, ~47s, 4 tests): demo entry round-trip, multi-card swipe with per-card draft preservation, keyboard show/hide layout stability, Settings drill-down. Stress (`StressFlowUITests`, ~8min, 4 tests): 100× swipe under XCTMemoryMetric + XCTCPUMetric, 50× demo reply send, rotation + lifecycle churn (5 cycles × 4 orientations + 10 home/activate), 1800 input events typing test. Apple sign-in skipped via the `--uitest` launch arg → fixture mode wiring; `--uitest-signed-out` for the sign-in screen itself. Tracks #227-#241.

### 2026-05-10: UX Writing Diet

14 user-facing surfaces trimmed using "what does the user MUST know" as the only filter. Major reductions: sign-in subtitle 13w→7w, delete-account footer 41w→13w, empty states 14-21w→3-11w, Mac Settings privacy line 37w→12w, Folder Access guidance 41w→11w. Deletions (no info loss): Settings ▸ Identity Apple Relay paraphrase (Apple's UI explains this), Settings ▸ Server "scoped to this id" jargon, confirm-sheet message that restated the footer. Approximately 60% fewer words overall.

### 2026-05-10: APNS Push Pipeline

End-to-end push notifications. iOS: `SteerAppDelegate` registers for remote notifications, forwards device token to `SyncInbox.updateAPNSToken`, and triggers a `/v1/sync/devices` heartbeat carrying the new `apnsToken` field. Relay: new `packages/relay/src/apns.ts` (ES256 JWT bearer cached 50min) + `/v1/sync/cards/:cardId` PUT fans out to every iOS device with a token, only for actionable categories (blocker / decision / question / waiting). D1 migration 0004 adds `apns_token` column. UX layer: permission dialog auto-prompts after sign-in, denied state surfaces both a dismissible banner and a Settings row. Notification tap routes through `SyncInbox.requestFocus` → `InboxView` scrolls to the matching card. Open: user must provision APNS_KEY_ID / APNS_PRIVATE_KEY / APNS_BUNDLE_ID secrets + run D1 migration 0004 on prod. Tracks #255-#257, #260, #261.

### 2026-05-10: Mac Instruction Drain Race + iPhone Sync Toggle Semantics

Diagnosed user-visible "markInjected failed: cancelled" red banner: the reload loop (~2s) was reentrant — a slow `steer send` subprocess overlapped the next tick which re-fetched the same queued instruction and double-POSTed `markInstructionStatus`, with URLSession cancelling one of the two. Fix: `drainInFlight` flag serializes the drain. Same diagnosis revealed the iPhone Sync toggle was incorrectly gating BOTH outbound mirroring AND inbound instruction drain — meaning iPhone replies sat queued forever when the user hadn't flipped the toggle. Fix: outbound respects the toggle (privacy promise), inbound drain runs whenever signed in. Tracks #250-#253.

### 2026-05-11: Brand — App Icon + Menu Bar Mark

User shipped a 1024×1024 master and a SVG sidebar mark. Mac AppIcon.icns regenerated via `sips` + `iconutil` for every macOS rendition; iOS Assets.xcassets/AppIcon.appiconset wired through `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` so Xcode 13+ auto-generates per-size renditions from the single 1024 image. Menu-bar template image: 24/48/72 px three-rep composite at 22pt point size, loaded from SwiftPM's executableTarget Bundle.module (build-mac-app.sh now copies `${TARGET}_${TARGET}.bundle` into Contents/Resources/ so the runtime can find it). Provider claude.png / codex-color.png copied from Mac into iOS Assets.xcassets so ProviderMark renders the real logos on iPhone instead of the fallback gradient.

### 2026-05-11: iOS Shell Redesign — Drop Bottom Tab, Mirror Mac

User feedback: "Mac에는 이미 empty status 디자인까지 잘해놨구만 — 그대로 가져가." iOS scrapped the bottom TabView in favor of a single-screen shell that mirrors Mac 1:1. Settings lives behind a top-left 44pt Liquid Glass capsule (`.glassEffect(.regular.interactive(), in: Circle())`); the Mac connection chip lives in the top-right 44pt Liquid Glass pill. Compact carousel sized exactly like Mac (132 width, 14pt ProviderMark, 10pt project label, 10.5pt body @ 3 lines reservesSpace). Empty state copied verbatim: terminal SF Symbol, monospaced "No waiting actions" / "Running sessions appear here when they stop." Connection chip shows `N running` when the Mac has live sessions and no card has popped (cards in the carousel are NOT counted in the chip — the user explicitly called out that duplication). Live sessions arrive over new `GET /v1/sync/sessions` (Store.listLiveSessions filters running/waiting/blocked < 5min old); the Mac publishes its LiveSessionChip list via the existing POST /v1/sync/sessions endpoint each reload tick. Tracks #267-#269.

### 2026-05-11: Connect-Chip Latency + WS Card Flicker

Two perf/UX fixes shipped together. Mac↔iPhone connection-state lag cut from worst-case 90s+ to ~20s: iPhone polling 30s → 5s, Mac heartbeat 60s → 15s, "connected" age threshold 90s → 30s, "stale" age threshold 10min → 5min. Push fanout dedupe: APNS only fires on first insert of a cardId (`Store.upsertCard` now returns `{ inserted: boolean }`); Mac's reload-tick re-PUTs no longer pump a notification every 2s. iOS card-flicker after reply (disappear → reappear → disappear): WS card.upsert and HTTP reload now both skip any cardId in `pendingReplies` so the optimistic remove sticks until the relay broadcasts the matching card.resolved.

### 2026-05-11: macOS 26 Deployment Bump + DMG Release Pipeline

Mac deployment target raised macOS 15 → 26 because GlassSurface.swift relies on `.glassEffect`, which only exists on macOS 26 SDK. swift-tools-version 6.0 doesn't expose `.v26` symbolically yet, so Package.swift passes the raw `"26.0"` platform string (works through to the -target deployment flag). LSMinimumSystemVersion bumped in scripts/build-mac-app.sh. GlassSurface drops the pre-26 fallback branch. Strict-concurrency fix on SteerAppDelegate.startHeartbeatTimer (the Timer closure was synchronously calling @MainActor fireHeartbeat, which Swift 6 rejects). CI: test.yml and release.yml both `runs-on: macos-26` and use `npm install` (package-lock.json is gitignored). Branch cleanup: fix/mac-launchd-spawn force-promoted to main; release/mac-dmg-distribution, feature/mas-edition, feature/relay-backend, ios-spike, fix-terminal-excerpt-formatting all deleted locally. Outstanding: Developer ID provisioning profile needs `com.apple.developer.applesignin` added in Apple Developer Portal before the next signed release can include the iPhone Sync flow. Tracks #270-#272.

### 2026-05-11: First Signed DMG Built Locally (v0.1.1)

End-to-end pipeline validated on the local release machine: `scripts/release-mac.sh` with the Developer ID cert + `steer-notary` keychain profile + `Steer_Mac_Developer_ID.provisionprofile` produced a notarized stapled `.build/release/Steer-0.1.1.dmg`. App and DMG both Accepted by Apple notary service, stapled successfully. CI release workflow (run 25655009842) for tag v0.1.1 passed swift build / npm tests / cert import, then failed at "Register notarytool credentials" with HTTP 401 — one of NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_APP_SPECIFIC_PASSWORD secrets is wrong (user task #273). Provisioning profile entitlements audit: neither the Developer ID nor the Development profile carries `com.apple.developer.applesignin`, so a locally built v0.1.1 DMG would launch and run but would fail Sign-in-with-Apple at `iPhone Sync → Sign in`. To unblock the full iPhone Sync flow, user must enable "Sign In with Apple" on the ai.steer.mac App ID in Apple Developer Portal and regenerate both profiles.

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
