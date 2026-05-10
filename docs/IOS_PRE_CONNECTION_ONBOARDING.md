# iOS Pre-Connection Onboarding UX

Last updated: 2026-05-10

## Purpose

The iPhone app must feel useful before it has a live Mac connection. This is both a product requirement and an App Store review requirement. A reviewer or first-time user should be able to understand and exercise Steer's core workflow through Demo Mode without installing or pairing Steer for Mac.

This onboarding is not a marketing landing page. It is a usable app state that leads into either Demo Mode or the Mac-first live setup path.

## Product Principle

Before connection, Steer should answer three questions quickly:

1. What is this? An AI coding action inbox.
2. What can I do now? Try sample action cards and replies.
3. What changes when I connect my Mac? Live cards and reply delivery to my own local sessions.

Avoid wording that implies remote terminal control. The user is reviewing action cards and queueing replies; the Mac owns local delivery.

Live setup is Mac-first. The iPhone app should never imply that it can enable Mac sync, install the CLI, configure providers, or start local terminal sessions by itself. The normal user path is:

1. Install and open Steer for Mac.
2. Complete Mac first-run setup.
3. Sign in with Apple on Mac.
4. Enable iPhone Sync on Mac after reviewing What Syncs.
5. Start `steer codex` or `steer claude`.
6. Install/open iPhone app and sign in with the same Apple account.

See `docs/CROSS_DEVICE_ONBOARDING_PLAN.md` for the full cross-device setup plan.

## iPhone Onboarding Role

The iPhone app has three onboarding jobs:

1. Let App Review and first-time users try the real card/reply interaction through Demo Mode.
2. Help users who installed iPhone first understand that live use starts on Mac.
3. Diagnose whether the user's signed-in Mac is online, sync-enabled, and able to receive queued replies.

The iPhone app is not the primary installer. It should point users to the Mac app setup checklist and release/download page, then confirm the Mac connection once setup is complete.

## App Review Pass Strategy

The onboarding must be designed so App Review can approve the iPhone app even if the reviewer never installs Steer for Mac.

Review-facing requirements:

- Demo Mode must be available before sign-in and must exercise the real native product loop: card stack, card detail, terminal excerpt, suggested replies, reply composer, and queued/delivered/failed status.
- The signed-out screen must include Privacy Policy, Terms, and Support links without requiring authentication.
- Sign in with Apple must use Apple's native button style and must not be the only way to inspect the app's core interaction.
- Account settings must expose Sign Out and Delete Account. Delete Account must remove relay data and revoke Sign in with Apple tokens according to Apple's current account-deletion guidance.
- The app must explain why Mac setup is needed for live data while still remaining useful through Demo Mode.
- App Review notes must include a short script: open app, tap Try Demo, open a sample card, send a sample reply, inspect simulated delivery status, then open Privacy/Terms.
- App Review notes should also say that live delivery requires the user's own Mac running Steer, iPhone Sync enabled on Mac, and a session launched through `steer codex` or `steer claude`.

Reviewer confusion to avoid:

- Do not make the first screen a blocker that only says to install Mac.
- Do not describe Steer as a remote shell, remote terminal, terminal mirror, or arbitrary command launcher.
- Do not show screenshots that look like full terminal mirroring from iPhone.
- Do not hide privacy or deletion controls behind a successful Mac connection.
- Do not imply iPhone can enable Mac sync or inject commands unless the Mac app has explicitly opted in and is handling local delivery.

## Persistent Mac Connection Indicator

The iPhone app should always show Mac connection state in the top-right app chrome when the user is in live or signed-in flows. This is not only onboarding; it is the user's delivery-confidence indicator.

Required placement:

- Top-right of the main stack header, near Account.
- Tap opens `Mac Sync Status`.
- Must be visible in signed-in empty, live cards, cached/offline cards, and Mac-offline states.
- In signed-out Demo Mode, show `Sample workspace` instead of a Mac connection badge.

Visual format:

- Use a compact chip, not a full-width banner, for normal app chrome.
- Shape: small rounded capsule with status dot + Mac display name.
- Examples:
  - `● MacBook Air`
  - `● Mac mini`
  - `● Mac Studio`
  - `● No Mac`
  - `● Sample`
- Color belongs only in the dot. Keep the chip surface neutral so it does not compete with the active card.
- If the display name is too long, truncate the middle or tail, for example `Ilwon's Mac...`.
- If more than one Mac exists later, show the active/deliverable Mac in the chip and list all Macs in the status sheet.

Required states:

| State | Chip label | Visual | Meaning |
| --- | --- | --- | --- |
| `demo` | `Sample` | neutral dot | Demo data, no real Mac involved |
| `neverConnected` | `No Mac` | gray dot | Signed in, but no Mac has enabled iPhone Sync |
| `connected` | Mac display name, e.g. `MacBook Air` | green dot | A signed-in Mac heartbeat is fresh and can receive queued replies |
| `stale` | Mac display name, e.g. `Mac mini` | yellow dot | A Mac was seen recently, but heartbeat is old; replies may queue |
| `offline` | Mac display name, e.g. `Mac Studio` | gray or warning dot | Known Mac is not currently reachable; replies will wait |
| `error` | `Sync issue` | red dot | Relay or auth problem prevents reliable sync |

Suggested heartbeat thresholds:

- `connected`: last Mac heartbeat within 90 seconds.
- `stale`: last Mac heartbeat between 90 seconds and 10 minutes.
- `offline`: no heartbeat for more than 10 minutes, or socket/recent poll confirms no Mac listener.

Device naming requirement:

- Use the user-visible Mac computer name when available, such as `Ilwon's MacBook Air`.
- Also store a short device class label when possible: `MacBook Air`, `MacBook Pro`, `Mac mini`, `Mac Studio`, `iMac`, or `Mac`.
- Default chip label should prefer a recognizable short name:
  - user-renamed display name if concise,
  - otherwise device class label,
  - fallback `Mac`.
- The Mac app should let the user rename the device label later if the system name is unclear.

Backend/data requirement:

- Mac must publish minimal device presence to the relay: `deviceId`, `platform=mac`, `displayName`, `deviceClass`, `appVersion`, `lastSeenAt`, and `syncEnabled`.
- iPhone must be able to fetch presence through a small authenticated endpoint, for example `GET /v1/sync/devices` or `GET /v1/sync/status`.
- The status endpoint must not expose terminal content.

`Mac Sync Status` sheet should show:

- Current state.
- Last seen time.
- Mac display name, if available.
- Device class, such as `MacBook Air` or `Mac mini`.
- Whether iPhone Sync is enabled on that Mac.
- What happens to replies in this state.
- Links to `Set Up Mac First` and `What Syncs?`.

Offline recovery content:

- If state is `neverConnected`, show:
  1. Open Steer for Mac.
  2. Sign in with the same Apple account.
  3. Go to Settings -> iPhone Sync.
  4. Review What Syncs and enable sync.
  5. Start or resume a Steer-managed coding session.
- If state is `offline` or `stale`, show:
  1. Wake or unlock the Mac.
  2. Open Steer for Mac.
  3. Confirm iPhone Sync is still enabled.
  4. Check that the Mac has internet access.
  5. Leave Steer for Mac running so it can deliver queued replies.
- If state is `error`, show the last sync error and offer:
  - `Retry`
  - `Sign Out`
  - `Contact Support`

The recovery sheet must be instructional, not alarming. It should make clear that replies are queued until the Mac returns.

## Entry States

### State A: First Launch, Signed Out

Primary goals:

- Let the user try the product immediately.
- Offer Sign in with Apple for live sync.
- Keep Privacy Policy and Terms reachable without authentication.

Required UI:

- Product title: `Steer`
- One-line positioning: `AI coding action inbox`
- Short body copy: `Review waiting moments from your own Mac coding agents and queue replies from iPhone.`
- Primary CTA: `Try Demo`
- Secondary CTA: native `SignInWithAppleButton`
- Setup link: `Set Up Mac First`
- Footer links: `Privacy Policy`, `Terms`, `Support`

CTA behavior:

- `Try Demo` opens the sample card stack immediately.
- `SignInWithAppleButton` is for users who already completed or are ready to complete Mac setup with the same Apple account.
- `Set Up Mac First` opens a concise setup checklist and a Mac download/release link.

Do not show a blank inbox as the first signed-out experience. Do not make `Open Steer for Mac` the only path, because App Review must be able to exercise the app without a Mac.

### State B: Signed In, No Mac Connected

Primary goals:

- Explain that live delivery starts with Mac setup.
- Keep the user in the product with demo/sample cards.
- Give clear next steps without implying iPhone can configure the Mac.

Required UI:

- Empty-state title: `Set up Steer for Mac`
- Detail copy: `Live cards appear after Steer for Mac is installed, signed in, iPhone Sync is enabled, and a Steer-managed session is running.`
- Primary CTA: `Set Up Mac First`
- Secondary CTA: `Try Demo`
- Tertiary: `What Syncs?`
- Account button remains visible.
- Top-right connection chip: `No Mac`.
- Tapping `No Mac` opens setup instructions.

Do not treat this as an error.

### State C: Signed In, Mac Connected, No Cards Yet

Primary goals:

- Confirm that the Mac path is working.
- Explain why the inbox can still be empty.
- Point the user to the next Mac action.

Required UI:

- Empty-state title: `No live cards yet`
- Detail copy: `Your Mac is connected. Start or resume a session with steer codex or steer claude, then waiting moments will appear here.`
- Primary CTA: `How to Start a Session`
- Secondary CTA: `Try Demo`
- Tertiary: `What Syncs?`
- Top-right connection chip: Mac label, for example `MacBook Air`, with connected dot.

### State D: Signed In, Mac Offline

Primary goals:

- Preserve cached/offline value.
- Make queued replies understandable.

Required UI:

- Offline banner: `Mac offline - replies will wait`
- Top-right connection chip: last known Mac label, for example `MacBook Air`, with offline dot.
- Tapping the chip opens recovery instructions.
- Cached card stack remains visible.
- Reply send status becomes `Queued for Mac`.
- Primary recovery CTA: `Open Steer for Mac`
- Account/settings and What Syncs remain reachable.

### State E: Demo Mode

Primary goals:

- Demonstrate full product loop without relay account or Mac.
- Make App Review possible.
- Teach the user what a real card will look like.

Required UI and behavior:

- Uses the same card stack UI as live mode.
- Displays sample cards with provider, project, branch, status, terminal excerpt, title, summary, suggested reply chips.
- Card detail opens normally.
- Reply composer accepts text.
- Sending a reply creates a simulated status sequence:
  - `Queued`
  - `Delivered by sample Mac`
  - at least one sample card should demonstrate `Failed` with a clear reason.
- Demo status label: `Sample workspace`
- Exit control: `Use Live Sync`

Demo copy must not imply it is controlling a real terminal.

## Demo Sample Content

Use realistic but fictional project names and terminal excerpts. Avoid any real user paths, secrets, customer names, or proprietary code.

Recommended sample cards:

1. Decision card
   - Provider: `Codex CLI`
   - Project: `demo/shop-app`
   - Branch: `checkout-refactor`
   - Title: `Choose checkout error handling`
   - Terminal excerpt: validation output and two options.
   - Suggested replies: `Use the typed error enum`, `Keep current fallback`, `Explain tradeoffs`

2. Blocker card
   - Provider: `Claude Code`
   - Project: `demo/mobile-ui`
   - Branch: `settings-sheet`
   - Title: `Tests need permission`
   - Terminal excerpt: simulator or file permission failure.
   - Suggested replies: `Retry with simulator reset`, `Skip UI test for now`, `Show exact command`

3. Waiting card
   - Provider: `Codex CLI`
   - Project: `demo/relay`
   - Branch: `account-delete`
   - Title: `Ready to apply migration`
   - Terminal excerpt: migration summary and pending confirmation.
   - Suggested replies: `Apply migration`, `Generate rollback first`, `Stop here`

4. Failed-delivery sample
   - Provider: `Claude Code`
   - Project: `demo/docs`
   - Branch: `launch-notes`
   - Title: `Sample Mac disconnected`
   - Terminal excerpt: completed draft awaiting review.
   - Suggested replies: `Polish the summary`, `Add risk section`
   - Simulated result: `Failed - sample Mac went offline`

## Onboarding Flow

```text
First launch
  -> Try Demo
    -> Sample card stack
    -> Detail
    -> Send sample reply
    -> Status changes
    -> Use Live Sync
  -> Sign in with Apple
    -> If no Mac has enabled sync
      -> Set up Steer for Mac
      -> Set Up Mac First OR Try Demo
    -> If Mac is connected but no cards exist
      -> No live cards yet
      -> How to Start a Session OR Try Demo
    -> If Mac is offline
      -> Cached cards / queued replies
      -> Open Steer for Mac
  -> Set Up Mac First
    -> Mac checklist
    -> Mac release/download link
    -> Return after Mac setup and sign in
```

## Set Up Mac First Flow

The iPhone app should explain the steps without making setup the only path. This flow is informational and diagnostic; it does not configure the Mac remotely.

1. Install or open Steer for Mac.
2. Complete the Mac first-run checklist, including `steer` CLI install and provider verification.
3. Sign in with the same Apple account on Mac.
4. Open Settings -> iPhone Sync.
5. Review what syncs and enable sync.
6. Start a Steer-managed coding session with `steer codex` or `steer claude`.
7. Keep Steer for Mac running for live reply delivery.

The iPhone app should not claim it can start or control arbitrary Mac terminal sessions.

Required screen sections:

- `Install Steer for Mac`: link to GitHub Release, website, or TestFlight-equivalent Mac distribution page.
- `Finish Mac setup`: CLI install, provider verification, notifications, Apple sign-in.
- `Enable iPhone Sync`: What Syncs review, explicit sync toggle on Mac, device label.
- `Start a session`: `steer codex` or `steer claude`.
- `Come back to iPhone`: sign in with the same Apple account and check the top-right Mac chip.

Suggested compact copy:

`Live cards start on your Mac. Install Steer for Mac, sign in, enable iPhone Sync, then start a session with steer codex or steer claude.`

## What Syncs Screen

This screen is required before App Store submission because Steer syncs sensitive coding context.

Show:

- Account identifier from Sign in with Apple.
- Card title and summary.
- Short terminal excerpt.
- Suggested replies.
- Project/provider/branch labels.
- Replies sent from iPhone.
- Delivery status and failure reason.

Explicitly say:

- Full raw transcript is not synced by default.
- Environment variables and attachments are not synced by default.
- Terminal excerpts can contain sensitive data if the underlying CLI prints it.
- Live delivery requires the user's own Mac to be online.

## Copy Guardrails

Use:

- `AI coding action inbox`
- `Review waiting agent cards`
- `Queue replies to your own Mac sessions`
- `Mac handles local delivery`
- `Sample workspace`

Avoid:

- `Remote terminal`
- `Remote shell`
- `Control your Mac terminal`
- `Run commands from iPhone`
- `Terminal mirror`
- `Remote desktop`

## Visual Direction

- Use the real card stack as the first usable surface.
- Avoid a hero/marketing page.
- Keep onboarding concise and work-focused.
- Use icons for Account, Privacy, Sync, and Demo controls.
- Do not hide Privacy/Terms behind sign-in.
- Do not use giant headings or decorative illustrations.

## Implementation Plan

### P0

- Add signed-out onboarding surface with `Try Demo`, native `SignInWithAppleButton`, Privacy, Terms, Support.
- Add `Set Up Mac First` entry point on signed-out and signed-in no-Mac states.
- Add Mac-first setup checklist screen with Mac release/download link, same-Apple-account requirement, iPhone Sync opt-in, and `steer codex` / `steer claude` instructions.
- Add demo data provider that maps sample cards into the same `ActionCard` UI model as live cards.
- Add demo reply state machine for queued/delivered/failed states.
- Add signed-in no-Mac state with `Set Up Mac First`, `Try Demo`, and `What Syncs?`.
- Add signed-in connected-empty state that tells the user to start or resume `steer codex` / `steer claude` on Mac.
- Add persistent top-right Mac connection indicator and `Mac Sync Status` sheet.
- Add relay-backed Mac device presence/heartbeat endpoint.
- Add What Syncs screen.
- Add Mac offline banner and queued status language.
- Add UI smoke test or manual checklist for signed-out, demo, signed-in-empty, and offline states.

### P1

- Persist whether the user has completed onboarding.
- Add cached last-sync cards for offline mode.
- Add richer Mac setup guidance with support link.
- Add screenshots for App Review notes showing demo flow.

## Acceptance Criteria

- A reviewer can install the iPhone app, tap Try Demo, open a card, send a sample reply, see status feedback, and inspect Privacy/Terms without signing in.
- A signed-in user with no Mac data sees a Mac-first setup checklist, not a dead end.
- A signed-in user with a connected Mac but no cards is told to start or resume `steer codex` / `steer claude`.
- A signed-in user can always tell whether a Mac is connected before sending a reply.
- iPhone setup copy never implies the phone can install Mac components, enable Mac sync, or control terminal sessions by itself.
- All pre-connection copy avoids remote-terminal framing.
- Demo and live modes share the same card/detail components so the demo represents the actual product.
