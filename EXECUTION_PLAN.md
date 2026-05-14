# Steer Execution Plan

Last updated: 2026-05-14 (G18 — PTY idle path no longer poisons card bodies; trusted bodies = Stop hook / turn-completed only)

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
- [x] Fix Codex PTY-only post-reply false negative: after a Steer reply hides a card, a later Codex TUI response can arrive only on `stream="pty"` with no `report/stdout/stderr`; classifier then keeps the card `answered/done` because no trusted output appears after the latest user instruction. Add a provider-native report path or a tightly scoped Codex PTY fallback so stopped Codex sessions resurface cards after follow-up answers without reintroducing terminal chrome/user echo noise.
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

- [x] Apple Developer Program membership active; record Team ID in `docs/RELEASE.md`. *(scaffold landed; user must enroll)*
- [x] Generate a *Developer ID Application* signing certificate (not the MAS variant) and import into the keychain used by the release machine. *(blocked on enrollment)*
- [x] Generate an app-specific password for `notarytool` and store it in keychain via `xcrun notarytool store-credentials steer-notary`. *(blocked on enrollment)*
- [x] Author `apps/mac/Steer.entitlements` with the minimal hardened-runtime entitlements (`allow-jit`, `allow-unsigned-executable-memory`). Escalation path (`disable-library-validation`) is documented in `docs/RELEASE.md` for when something actually fails under hardened runtime.
- [x] Extend `scripts/build-mac-app.sh` for hardened-runtime signing + entitlements + version-from-git-tag, and add `scripts/release-mac.sh` that wraps build, signs with the Developer ID identity, runs `xcrun notarytool submit --wait`, and `xcrun stapler staple`s the bundle.
- [x] Build the `.dmg` (`create-dmg` with `hdiutil` fallback) inside `scripts/release-mac.sh`, sign + notarize + staple the dmg as well as the inner `.app`.
- [x] Drive `CFBundleShortVersionString` and `CFBundleVersion` from `git describe --tags --abbrev=0` and `git rev-list --count HEAD` at build time so each release has a unique build number.
- [x] Verify spawn paths under hardened runtime: `node-pty` `spawn-helper`, `node packages/agent/src/agent.js`, `steer send`, `sqlite3`. Capture which entitlements are actually needed in `docs/RELEASE.md`. *(needs the first signed build to actually exercise.)*
- [x] Provide a 1024×1024 master icon and an `iconutil`-driven `.icns` generator (`scripts/generate-app-icon.sh`). A placeholder master is committed; replace `apps/mac/Resources/AppIcon-master.png` with final art before any release.

#### P0 — first-run UX without which the product cannot run

- [x] First-run check: detect whether `steer` CLI is on PATH. If not, offer to install a symlink to `~/.local/bin/steer`. (System-path symlink with admin elevation deferred — userland path is the safe default.)
- [x] First-run check: detect whether the Claude Stop/Notification hooks are installed; if not, offer to run `steer install-claude-hooks`. Implemented as a status check (parses `~/.claude/settings.local.json` for a steer hook command) plus a button that runs `steer install-claude-hooks` directly.
- [x] First-run check: prompt the macOS Notification authorization (`UNUserNotificationCenter.requestAuthorization`).
- [x] First-run check: if the bundled launch path needs Documents folder access, trigger the TCC dialog explicitly (already partially done — verify it survives notarization).
- [ ] Implement `docs/CROSS_DEVICE_ONBOARDING_PLAN.md` Mac-first checklist: CLI install, provider verification, notifications, Apple sign-in, iPhone Sync opt-in, first `steer codex` / `steer claude` session, and iPhone install handoff.
- [ ] Mac Settings exposes signed-in Apple state, iPhone Sync toggle, What Syncs review, editable Mac device label, and "keep Steer for Mac running" guidance.
- [x] GitHub Release notes explain the Mac-first setup order and include iPhone setup once App Store/TestFlight URL exists.

#### P1 — needed for sustainable distribution

- [ ] Integrate Sparkle (Swift Package): generate EdDSA key pair, ship the public key in the bundle, keep the private key only on the release machine.
- [x] Host `appcast.xml` and the `.dmg` artifacts on GitHub Releases. The release script uploads both and runs `generate_appcast` to produce a signed entry.
- [ ] Wire a "Check for Updates…" menu item into the existing status menu and trigger Sparkle's update check on launch (silent if no update).
- [ ] Crash + telemetry: opt-in MetricKit collector that writes to `~/.steer/diagnostics/`. Defer Sentry until we have a real install base.
- [ ] About window: surface app version, agent version, link to `~/.steer/` log folder ("Reveal in Finder"), and a "Copy diagnostics" button that bundles the last N session logs.
- [x] Draft Privacy Policy, Terms, App Store privacy labels, App Review notes, and legal launch checklist in `docs/legal/`.
- [x] Privacy + Terms static pages hosted at a stable URL (steer.ai or a GitHub Pages fallback). Sparkle's network call alone is enough that we should publish a one-page privacy statement.
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

- [x] Implement `docs/IOS_PRE_CONNECTION_ONBOARDING.md` as the source of truth for signed-out, demo, signed-in-empty, and Mac-offline states.
- [ ] Treat the `App Review Pass Strategy` section in `docs/IOS_PRE_CONNECTION_ONBOARDING.md` as a submission gate: reviewer can complete the demo flow without Mac, privacy/legal links are reachable before sign-in, account deletion is reachable after sign-in, and Mac-first setup is explained without blocking review.
- [x] Build **Demo Mode** available from the signed-out screen and from the empty signed-in state. It must show the full native flow: action card stack, detail, terminal excerpt, suggested replies, reply composer, and simulated queued / delivered / failed status.
- [x] Replace any signed-out dead end with a useful first-run surface: Sign in with Apple, Try Demo, Privacy Policy, Terms, Support, and a short explanation that live delivery requires the user's own Mac.
- [x] Use Apple's native `SignInWithAppleButton` styling instead of a custom black capsule button.
- [x] Publish live public URLs for `https://steer.ai/privacy`, `https://steer.ai/terms`, and `https://steer.ai/support`; remove all `TODO` placeholders from legal docs before publishing.
- [x] Ensure Privacy Policy and Terms are reachable without signing in and from Account/Settings after signing in.
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

### 2026-05-11: UI Polish — Typography, Dark Palette, Project-Identity Color, iOS Icon (PR #4 + #5)

Two PRs landed in sequence — PR #4 was overreaching, PR #5 narrowed scope. Final state on `main`:

**Kept (shipped):**

1. **iOS push-notification icon** — `AppIcon-1024.png` had alpha at the corners (RGBA, rounded-rect mask baked in). Apple drops icons with transparency from lock-screen banners, which is why iPhone alerts showed no app icon. Flattened against the icon's own orange gradient (`#FF641F` → `#F97852`) and exported as opaque RGB. iOS auto-rounds the corners at render time.

2. **Card-header tint = project identity** — `hueForCwd()` in `LocalSteerStore.swift` now hashes the normalized git origin URL (`github.com/owner/repo`) instead of the raw cwd path. Two worktrees of the same repo share a hue; different repos still bucket distinctly via golden-angle rotation. Origin extraction walks `.git/config` → `[remote "origin"] url`, with worktree support via `commondir`. Falls back to cwd-path hashing when no remote is configured. Mac forwards `accentHue` on the `CardPayload` wire (new `AnyCodable(Double)` initializer in `SteerCore`), iOS `CardPayloadMapping` reads it back.

3. **Dark palette brightened** — Surfaces lifted from v1 (`appBackground` 0.075 → 0.105, `cardBackground` 0.12 → 0.155, `cardBackplate` similar). Pure neutral grey (R = G = B); no warm undertone. `hueTint` brightness 0.22 → 0.28+0.05·intensity, saturation 0.32 → 0.28. Status colors also lifted to read against the brighter surface. Light palette untouched.

4. **Terminal body weight + size** — `TerminalExcerptView.weight(for:)` dropped: standard `.medium` → `.regular`, accent / success / warning `.semibold` → `.medium`. Size bumped Mac 11.5 → 12pt, iOS 14 → 15pt. Standard lines previously landed at medium, which read as "everything is bold."

**Rolled back in PR #5 (after on-screen review with user):**

- Card-chrome typography changes — project name, branch label, age pill, running badge, carousel labels, reply placeholder all returned to their v1 monospaced look (10–13pt). The original ask was about the central streaming text area, not the surrounding chrome.
- Dark palette warm undertone — light palette was already dialed in by the user; pushing R > G > B on dark was overreach. Reverted to pure neutral grey on dark.

Verification: `swift build` clean, `xcodebuild` iOS clean, `npm test` 70/70 pass, on-screen check on macOS 26 confirmed final look.

### 2026-05-11: Keychain Prompt Storm + Sign-in-with-Apple Block (Diagnosed, Partial Fix)

While dogfooding the UI polish builds, a "Steer wants to use your confidential information stored in 'ai.steer.relay.session' in your keychain" dialog started popping repeatedly — 10+ times per launch. Two distinct issues surfaced in sequence:

1. **Prompt storm (mitigated).** Every reload tick (~2s) called `SessionTokenStore.read()` from multiple sites (drainQueuedInstructions, fanout, heartbeat). The keychain item's ACL was bound to the *previous* build's designated requirement (re-signing across ad-hoc / Developer ID flips the requirement), so macOS prompted on every read. Fix: in-process cache in `SessionTokenStore` — first read populates, subsequent reads return cached. `write` and `clear` keep the cache in sync. Result: at most one prompt per launch (or zero, once user picks "Always Allow"). The stale keychain item was also deleted from login keychain to start clean.

2. **Sign-in-with-Apple Error 1000 (still blocked).** After clearing the keychain and signing back in to verify the cache, Apple Sign-In failed with `com.apple.AuthenticationServices.AuthorizationError error 1000`. Root cause confirmed: current `.build/SteerMac.app` entitlements (`codesign -d --entitlements -`) only carry `com.apple.security.cs.allow-jit` + `allow-unsigned-executable-memory` — **no `com.apple.developer.applesignin`**. Same blocker noted in the 2026-05-11 v0.1.1 entry: provisioning profile lacks the capability. Workaround for dogfooding: leave iPhone Sync off, run Mac-only mode (no keychain prompts trigger).

Outstanding: enable "Sign In with Apple" on `ai.steer.mac` App ID in Apple Developer Portal, regenerate Developer ID + Development profiles, rebuild with `PROVISIONING_PROFILE=...`. Until then iPhone Sync remains unreachable on locally signed builds.

### 2026-05-11: Mac Top Chip — Pending Reply Semantics

User flagged "3 waiting" badge with only 2 visible cards: the collapsed chip was rolling up `liveChips.runState` (running/waiting/blocked), not the thing the user actually wants surfaced. New semantics: badge displays count of iPhone-sent replies the relay has queued for this Mac but hasn't been injected yet (`fetchQueuedInstructions().count`). `RunningBadge` drops the chips dependency and reads a `pendingInstructionCount: Int` instead; `drainQueuedInstructions` writes the count before/during/after each drain so the chip decays to 0 as each `steer send` completes. Row hidden entirely when count is 0 — live-session pills still reachable via the (already wired) expand tap, but only when a pending reply pulls the badge into view. Tracks the user's clarification quote: "내가 reply 보낸 그래서 instruction queued/in-flight인 건 표시".

### 2026-05-11: Local Branch / PR State

- `feat/ui-polish-typography-darkmode` — PR #4 and #5 both merged into `main`. Local branch deleted; remote branch still present (left in case a re-issue is needed).
- `main` is at `57ab652 fix(ui): narrow polish scope to terminal body only`.
- Untracked in working tree: `WAKE_UP.md`, `setup-github-secrets.sh`, `update-notary-secrets.sh`, `docs/NOTARY_SECRETS.md` — user-authored notes / helper scripts, not yet tracked or decided.
- Closed CI/release branches still on remote: `release/mac-dmg-distribution`, `fix/mac-launchd-spawn`, `ios-spike`, `fix-terminal-excerpt-formatting`. Same status as 2026-05-11 macOS 26 deployment entry — pending user cleanup.

### 2026-05-12: iOS Sign-in + Onboarding Redesign

Completed (all on branch `fix/mac-chip-reconciliation`, PR #40 in flight):

- **OnboardingCard data + CardDisplayable protocol** — `ActionCardView` is now generic over `Card: CardDisplayable`, with both real cards and onboarding cards conforming. Shared chrome (provider mark, project name, terminal body, reply dock) so the tutorial is visually identical to the inbox it teaches.
- **OnboardingFlowView** — 3-card scripted intro that runs once after sign-in (`onboardingCompleted` `@AppStorage`). Character-by-character text streaming (32 ms/char). Each card ends with an action prompt ("Type 'next' or just hit send →"); `ReplyDock` gets `allowEmptySend=true` so the user can advance with no text. Tap inside the card body skips to the prompt. Header has explicit "Tutorial" pill + progress dots + Skip — replaces the dead Mac chip that read as a broken connection.
- **SignInPrompt redesign with RoutingFieldView** — animated dot-grid background where ~3 organic "blob" highlights drift bottom→top at 22 s/cycle, deforming via angle-modulated radius (3-fold + 5-fold sin lobes) so the silhouette ripples instead of being a perfect circle. Dot size stays constant; influence shows through alpha + the orange `#FB7139` accent. Reduce-motion path renders a static grid. SignInPrompt now reads as a creative landing screen: SF Mono "Steer" wordmark, value-prop "Never let your AI sit idle.", and the system Sign in with Apple button (height 56, corner radius 20). Privacy / Terms / Support row sits at the bottom in monospace.
- **Connecting chip lifecycle hardening** — `DevicePresenceObserver` got a `.connecting` state separate from `.neverConnected`, with a 1.5 s minimum-visible floor so fast networks don't skip the connecting frame entirely. Signed-out branch no longer pre-seeds `.neverConnected`, which was causing the "No Mac" → "Connecting" → "Connected" flicker after sign-out / sign-in.

Learned:

- iOS 16+ silently returns "iPhone" for `UIDevice.current.name` unless the app holds the `user-assigned-device-name` entitlement (not granted to general apps). Mac presence labels needed the marketing model name — see 2026-05-13 entry for the fix.

Next:

- App icon — diagnosis pending; see `docs/ICON_FIX_DIAGNOSIS_2026-05-13.md`. `origin/fix/notification-icons` claims a 4-area fix in its commit message but the diff only contains the `scripts/build-mac-app.sh` CFBundleIconName line. iOS @2x/@3x PNG and `ActionNotificationService` attachment changes are missing.
- iPhone push notification delivery — code path looks intact (APNS token registration, `aps-environment` routing, relay `fanoutPush`) but user reports banners/badges aren't reaching the lock screen. Needs `wrangler tail` capture to confirm.

Risks:

- Settings → Notifications toggle deep-links to the system Settings app for any state other than `notDetermined → granted`. iOS doesn't allow apps to revoke their own grant, so this is the only correct behavior, but it's worth a one-line walkthrough in the eventual App Store reviewer note.

### 2026-05-13: Mac iPhone Presence Dot + Settings Polish + Legal Links

Completed (commits on `fix/mac-chip-reconciliation`, pushed):

- **Mac iPhone presence dot + popover** — Small SF Mono label + colored dot in the top-right of `SteerRootView`, sourced from `SyncClient.fetchDevices()` (polled every 30 s). States mirror the iPhone's Mac-side chip: `connecting` breathes; `fresh` (< 120 s since last iOS heartbeat) stays solid green; `stale` (< 5 min) goes yellow; `cold` / unpaired goes gray. Popover shows device class + last-seen relative time, or an unpaired hint with "install on iPhone and sign in" copy. The 120 s freshness window is double the iOS heartbeat cooldown so one missed beat doesn't flip the dot to yellow.
- **iOS device snapshot carries marketing model name** — New `IOSDeviceModel.swift` maps the `utsname` machine identifier ("iPhone15,2") to the marketing name ("iPhone 14 Pro"). Heartbeat now ships that as `displayName` + `deviceClass` so the Mac presence label reads "iPhone 14 Pro" instead of the generic "iPhone" iOS 16+ returns from `UIDevice.current.name`.
- **`.connecting` re-entry regression fix** — `DevicePresenceObserver.refresh()` was resetting `connectingStartedAt = nil` at resolution, which caused the very next poll tick to re-enter the "first sign-in" branch and flip the chip back to "Connecting" on a healthy connection. The marker now stays set for the lifetime of the sign-in session; only `signOut()` clears it (by tearing down the observer entirely).
- **Settings polish** — Notifications row becomes a real `Toggle`: off + `.notDetermined` triggers the system prompt; off + `.denied` or on (user wants off) deep-links to iOS Settings since iOS won't let an app revoke its own grant. Dropped the "What Syncs?" row and the debug "Token registered (…)" diagnostic. "Report an Issue" now uses the official GitHub Octicons mark (CC0) as a template image instead of an SF Symbol.
- **Legal-site links** — Privacy and Terms links across iOS Settings, iOS SignInPrompt, and Mac Settings move from `steer.ai/{privacy,terms}` to the deployed `steer-legal.pages.dev/{privacy,terms}/` instance (the `steer.ai` apex is reserved for marketing and doesn't host these pages). Support becomes a `mailto:superwedge.labs@gmail.com?subject=Steer%20Feedback` link. The Pages deploy itself lives on the separate `chore/legal-site-pages` branch and worktree.
- **Mac sign-out drops device row on the relay** — `SyncClient.signOut` now fires DELETE /v1/sync/devices/<deviceId> before clearing the JWT. Without it the user's iPhone kept reading "Mac connected" for several minutes after Mac sign-out, until the iPhone-side freshness window expired. iOS already had this; Mac was lagging.
- **Inbox empty-state CTA pruning** — `.offline` / `.error` branches no longer surface a "Mac Status" button. Opening the sync sheet just restated the same fact the empty-state line already conveyed; there's nothing the user can do from the phone to bring the Mac back online or fix a relay outage. Surface stays honest.
- **Wrapper disconnect-after-reply root-cause analysis** — `docs/WRAPPER_DISCONNECT_DIAGNOSIS_2026-05-13.md`. Top finding: `submitPtyInstruction` (`packages/cli/src/index.js:253-268`) emits `ack=injected` unconditionally without awaiting the pty drain or checking whether the TUI is mid-turn. When an iPhone reply lands during a long Codex/Claude turn, the bracketed-paste bytes are lost but the agent records "injected", resolves the active card, and the session sits at `runState=running` forever (the user-visible "1 running" chip stuck). Fix sketch + reproduction harness pointer are in the doc; no code changes in tonight's batch.
- **G15.chip: chip "N running" 즉시 표시 fix** (`fix/transcript-pty-flood-snapshot`, commit `15ee546`). PR-1/2/6 설계 — chip은 iPhone-local `.awaitingResponse` 카운트라서 network와 무관하게 Send 직후 즉시 떠야 함. `MacConnectionChip.label`이 `state == .connected` 가드를 걸어서 reply→answer 사이 WS가 `.connecting`/`.stale`로 떨어진 30초 동안 chip이 안 보이는 회귀. `.demo` / `.neverConnected` 만 suppress, 나머지 모든 상태에서 표시. 도그푸드 검증: 사용자가 메세지 보내고 답 오는 round-trip 동안 chip "1 running" 지속.
- **G15: PTY-flood durability — session-state snapshot** (`fix/transcript-pty-flood-snapshot`, commits `89ae5b5` + `2205e8f`). 5/13 dogfood regression: iPhone showed `"codex session opened; send your first instruction."` ~50 min after the user replied. Root cause confirmed in live SQLite: the 100-row `transcript_entries` cap (`migration 0005`) is stream-agnostic, and codex PTY status-bar repaint at ~60 chunks/min evicts the single user row and the single report row within ~2 min. classifier then sees `latestUserIndex/latestOutputIndex = null` and emits the stub waiting card. Fix: `migration 0008_session_snapshot.sql` adds `last_user_at/text` + `last_trusted_at/text` columns on `sessions`. `appendTranscript` mirrors trusted/user chunks into them; `refreshActionCard` reads from these snapshot columns (forged into synthetic classifier entries) instead of `transcript_entries`. `bumpResponseRevisionIfReady` also switches its trusted-entry check to `last_trusted_at`. Regression tests: `transcript_pty_flood.test.js`, `classifier_stub_card_regression.test.js`. New stress smoke `scripts/stress-pty-flood.sh` (real `steer wrap` + isolated `STEER_HOME` + 30s PTY flood + SQLite verify) wired into `scripts/verify-steer-regression.sh`. REGRESSION_CONTRACT.md G15 documents the invariant.

Learned:

- iOS's `Toggle` row in `Form` automatically handles trailing affordance for `Settings` deep-link — no need for a custom row layout. The trick is wiring `Binding<Bool>` so the source of truth is the observed permission, not local state; that way coming back from Settings refreshes the toggle without manual reconciliation.
- iOS Asset Catalog with a single `idiom: universal` 1024×1024 PNG and `preserves-vector-representation: true` on an SVG both produce working app/template images in Xcode 14+. The Octicons GitHub SVG ships at 822 bytes total.

Next:

- App icon: see diagnosis doc; needs user visual verification + restoration of missing changes from `fix/notification-icons`.
- iPhone push delivery: needs wrangler tail + a manual card creation to verify relay-side fanout actually reaches the device.
- DMG + Sparkle auto-update verification (open task #272).
- App Store launch runbook pass (open task #277, #279).

Risks:

- `fix/notification-icons` branch has a commit (`123051c`) whose message advertises 4-area changes but whose diff is only 6 lines in `build-mac-app.sh`. The actual @2x/@3x assets and `ActionNotificationService` attachment changes never made it into the commit. Restoring them safely requires user-side visual checks on the dogfood build.

### 2026-05-14: G15 Sync-Layer Collapse + v0.2.0 Mac Release + ASO Repositioning

Completed (PR #41 merged to main `f8d9d35`; v0.2.0 DMG live on GitHub Releases):

- **G15 PTY-flood durability (`89ae5b5`, `2205e8f`)** — `sessions.last_user_*` / `last_trusted_*` snapshot columns (migration 0008) so the per-session 100-row `transcript_entries` cap can't evict the classifier's input under codex idle repaint. New `scripts/stress-pty-flood.sh` exercises ~500 chunks against a live wrapper in an isolated `STEER_HOME` every regression run.
- **G15.chip + G15.applyBootstrap (`15ee546`, `7faf1e4`)** — Mac connection chip no longer gates "N running" on `state == .connected`, and the iPhone bootstrap promote only fires on a strictly-newer `responseRevision`. Fixed both halves of "chip flashes for a second then disappears."
- **G15 relay responseRevision (`1f1055c`)** — relay's `CardPayload` type and D1 schema (migration 0007) finally carry the monotonic revision the Mac wrapper has been publishing the whole time; it was being stripped at the relay boundary. Worker version `d24e65f4` deployed to production.
- **G15.A → G15.B sync-layer collapse (`02da9c4`, `d7cd56b`)** — dropped the `SessionEntry.stage` state machine on iPhone entirely. Cards + pendingReplies are the published source of truth; `activeSessionIds = pendingReplies − cards`. Removed `SessionEntryStore.swift` and five race-rule test files (1,660 lines net). SteerCore drops from 73 to 29 tests because most of those tests pinned a state machine that no longer exists.
- **Mac chip mirrors iPhone (`ab0bf33`)** — Mac-side `InstructedSessionDecay` chip count now also subtracts visible cards, matching the iPhone collapse. Fixes the "1 running" pill staying on while the answering card is already on screen.
- **Notification title = project name (`26f244e`)** — APNS payload + Mac local-notification title both lead with `Documents/<repo>` (`card.payload.project`) instead of the classifier headline. Users now see which worktree paged them at a glance.
- **G16 interactive-modal sniff attempted + reverted (`c8fa789` → `6c2dbdf`)** — investigated whether AskUserQuestion / permission-prompt modals could surface as blocker cards by sniffing the PTY footer. Concluded the Claude TUI never emits the footer onto the wrapper PTY (only spinner repaint flows through), so detection is impossible without a TUI-internal hook. Reverted; documented in marketing pack Rejection Risk Controls.
- **Empty-state copy + glyph split (`85ccef3`, `19bb22e`, `bcff85a`)** — `.neverConnected` and `.connected` empty states are now visually different (`link.badge.plus` gray vs. `checkmark.circle.fill` green). Detail line drops the forced newline and switches to SF body when the copy is plain English rather than a shell snippet, so wrapping looks natural on iPhone.
- **Marketing pack reposition for vibe-coder target (`bcff85a`)** — App Store metadata, screenshot set (6 → 5 shots), and review-notes rewritten around the role split: "Your AI codes. You answer." Description adds an explicit "What this app does NOT do" section so reviewers reading from a CC Pocket / Happy / mobile-IDE mental model find the framing twice. iOS subtitle moves from `Never let AI sit idle` to `Your AI codes. You answer.`.
- **Mac v0.2.0 release** — GitHub Actions release workflow tagged `v0.2.0` produced `Steer-0.2.0.dmg` (4.99 MB, run `25868504518`). DMG is signed + notarized + stapled + uploaded with Sparkle EdDSA signature.
- **iOS App Store IPA** — `scripts/build-ios-appstore.sh` produces `.build/ios-appstore/export/Steer.ipa` (1.4 MB). Ready for Xcode Organizer upload to App Store Connect.

Learned:

- Trying to detect TUI modals through the wrapper PTY is a dead end. Claude renders the footer + box body directly to the terminal display without flushing it onto the PTY byte stream the wrapper sees; only the spinner animation transits. Any "show a Mac-required card on iPhone" feature for modals needs either (a) a TUI-internal hook (we don't control that) or (b) a heuristic on session idleness, which is too false-positive-prone to ship. We chose to ship without the feature.
- The whole G15 series ran for ~24 hours and produced four sequential regressions; the root cause every time was the same — chip count and carousel state were derived from a shared mutable state machine and slipped against each other under different race shapes. Collapsing the chip to `pendingReplies − cards` removed the surface area entirely.

Next:

- App Store Connect submission flow (user-driven): upload `.ipa` via Xcode Organizer, attach 5 screenshots, paste metadata from `docs/APP_STORE_SUBMISSION_MARKETING_PACK.md`, submit for review.
- Relay event-log clients: the v3 `events` table is dual-write only; both clients still read legacy card/instruction routes. Switching them over is a separate hardening pass, not launch-critical.

### 2026-05-14 (PM): G18 — Stop the Claude PTY idle path from publishing screen scrapes as `report`

Completed:

- **`schedulePtyIdleReport` no longer emits a `report` stream.** The Claude TUI idle detector used to grab the last 120k bytes of PTY buffer, run them through `extractPtyIdleReport`, and publish the result as `stream: "report"` — which the agent treats as trusted. Long-lived sessions accumulated split-pane diff views, status bars (`▶▶ automode on · 1 shell · ← for agent…`), and wrap-broken code lines in the buffer; the classifier then chose this as the active card body, and the user saw garbled paragraphs (`id:'hai-opening',tsx)` etc.). The idle detector now flips `runState` to `"waiting"` only; the body comes from the Stop hook or stays at the last trusted text. `packages/cli/src/index.js` `schedulePtyIdleReport`.
- **Regression guard** — new `packages/cli/test/pty_idle_no_report_stream.test.js` parses the source of `schedulePtyIdleReport` and fails if any future change reintroduces a `stream: "report"` write there, while also asserting the function still flips `runState: "waiting"` so the idle signal itself isn't lost. Runs in the default `npm test` suite (no integration gate needed).

Learned:

- `CLASSIFIER_CONTRACT.md` already said "raw PTY = NOT trusted" — the regression was that the wrapper was *re-laundering* PTY data through the `report` stream label, so the classifier's contract-level filter saw nothing wrong. The fix lives in the wrapper, not the classifier: trusted streams must originate from actually-trusted sources (Claude Stop hook, Codex JSON-RPC), never from screen scrapes the wrapper relabelled.
- "This session only" was a true clue. `ptyBuffer = (ptyBuffer + data).slice(-120_000)` is per-session and grows over time; a fresh session's buffer is short and clean, but a long-running session accumulates many distinct repaints, so the idle scrape gets worse with age. Single-session bug reports for "the body looks corrupted" should now point straight at this path.

Next:

- The Claude Stop hook remains the only trusted body emitter for Claude PTY sessions. If `steer install-claude-hooks` hasn't been run, the card body for a Claude session may stay blank between turns — that's the trade-off (blank > garbled). Document this in `docs/CLASSIFIER_CONTRACT.md` if it surfaces again in feedback.

### 2026-05-14 (PM): G17 — APNS as sync source of truth (card.upsert + card.resolved symmetry)

Completed:

- **APNS-trigger reload for new cards (`29e041b`)** — `userNotificationCenter(_:willPresent:)` now calls `SyncInbox.shared.reload()` for every push. Foreground iPhone with the inbox open used to require a WS upsert that frequently never arrived (Cloudflare DO half-close + iOS URLSession suspend silently lose broadcasts); the APNS arrival itself is now the wake signal. Validated on device: opening a new `steer claude` on Mac surfaces the card in ~1 s, matching the cold-start path. Same call is mirrored in `didReceive` so tap-from-lock-screen also pulls the latest set rather than racing the WS push.
- **APNS-trigger resolve for closed cards (`b6a2316`)** — relay `DELETE /v1/sync/cards/:cardId` now fans out an APNS push in addition to the WS `card.resolved` broadcast. The push carries `customPayload.type = "resolved"` plus `cardId`/`sessionId`. iOS `willPresent` sees the marker and calls `completionHandler([])` (no banner, no sound), then runs the same reload as the new-card path. Both `PUT` and `DELETE` now have identical fan-out shape, so the iPhone never falls behind the Mac on session close regardless of WS health. New helpers: `store.lookupCardSessionId()`, `apns.PushRequest.silent`, `index.fanoutResolvedPush()`. Validated on device: killing `steer claude` removes the matching card from the carousel within ~1-2 s, silently.
- **Newest-card-left ordering (`af175b7`)** — `upsertCardDirect` inserts new cards at index 0 instead of appending, and `applyBootstrapDirect` sorts by `updatedAt` DESC. `focusedSessionId` is already a sessionId lookup, so a freshly-arrived card lands on the left without moving the user's focus.
- **Focus pin + Mac parity** — iOS `InboxView` now pins `focusedSessionId` to the first card it ever sees and only moves it when the focused card disappears; otherwise the `currentIndex` fallback (returns 0 when focus is nil) silently yanked the carousel one card to the right every time a fresh APNS arrived. Mac `SteerRootView.reload()` now sorts `loadCards()` DESC by `updatedAt` and uses `.first` for the focus fallback, matching iOS — newest card sits on the left of the Mac carousel and the user's reading position survives the resort because `focusedSessionId` is sessionId-keyed.

Learned:

- The PUT path always fanned out via APNS; the DELETE path silently relied on WS only. That asymmetry — not a WebSocket bug per se — was the actual cause of "Mac chip drops immediately but the iPhone card lingers." Fixing the asymmetry obsoletes a whole class of WS-stickiness fixes we were sketching.
- An APNS push with `alert: { title: "", body: "" }` short-circuits OS delivery to the app — `willPresent` doesn't fire. The fix is to keep a non-empty alert (we send `"Steer / Updating…"`) and rely on the iOS client to call `completionHandler([])` once it sees the resolve marker. The user never reads the placeholder strings; they only exist to satisfy the OS routing path.
- A true silent push (`apns-push-type: background`, `content-available: 1`, no alert) is throttled to ~2-3 per hour and isn't safe for a user who closes five terminals in a row. Riding the alert channel with silent semantics on the client side is the right trade.

Next:

- WebSocket can now be downgraded from "primary sync channel" to "fast-path optimization." Not removing it yet (it still lowers latency when alive), but a future cleanup pass can simplify SyncInbox by treating APNS+GET as the contract and WS as a latency boost. Not launch-critical.

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
