# Steer iOS App Store Submission Marketing Pack

Last updated: 2026-05-13  
Audience: App Store Connect submission, App Review, screenshot production, launch copy  
Primary localization: English (U.S.)

This is the product-marketing source of truth for launching Steer on the iPhone App Store. It is written to answer four practical questions:

1. What is this app?
2. How should it be positioned so App Review understands it?
3. What exactly should be pasted into App Store Connect?
4. What screenshots should be uploaded, and what overlay text should each one use?

## Launch Positioning

### One-Line Positioning

Steer is an action inbox for AI coding agents: when a local Mac agent stops, asks, or finishes, Steer turns that moment into an iPhone card you can review and reply to.

### Short Product Story

AI coding agents are useful only when they keep moving. The problem is not starting an agent; the problem is noticing when it stops. Steer watches user-started CLI coding sessions on the Mac and surfaces only the moments that need attention. The iPhone app is the mobile action queue: notifications, cards, context, suggested replies, and a reply composer.

The iPhone app is not a remote terminal. It does not mirror a shell, expose a prompt, stream the screen, browse the Mac, or launch arbitrary commands. The Mac app owns local capture and local delivery. The iPhone app reviews cards and queues replies back to the user's own Steer-managed sessions.

### App Review Framing

Use this framing everywhere:

- **Say:** AI action queue, action inbox, waiting agent cards, queue replies, Mac handles local delivery.
- **Avoid:** remote terminal, remote shell, remote desktop, screen mirror, control your Mac, run commands from iPhone.
- **Clarify when needed:** Steer syncs small action cards and replies, not full transcripts or a live terminal.

### Target User

Primary user: developers using CLI coding agents while they are away from the terminal, context-switching, commuting, or working across rooms.

Secondary user: early adopters of agentic coding workflows who already understand Claude Code, Codex CLI, Gemini CLI, and terminal-first development.

### Launch Promise

Never let a coding agent sit idle because you missed the moment it needed you.

## App Store Connect Fields

### App Information

| Field | Value |
|---|---|
| App Name | `Steer - AI Action Queue` |
| Subtitle | `Never let AI sit idle` |
| Bundle ID | `ai.steer.ios` |
| SKU | `STEER_IOS_001` |
| Primary Category | Developer Tools |
| Secondary Category | Productivity |
| Price | Free |
| Availability | All territories |
| Age Rating | Expected 4+ |
| Copyright | `© 2026 Superwedge Labs` |

Notes:

- Use the hyphenated App Name if App Store Connect rejects the typographic dash. Both fit the 30-character name limit.
- Keep the subtitle generic. The app name already carries the product name, and Apple advises not duplicating searchable app/company names in keywords.

### URLs

| Field | Value |
|---|---|
| Marketing URL | `https://ilwonyoon.github.io/steer_ai/` |
| Support URL | `https://ilwonyoon.github.io/steer_ai/support/` |
| Privacy Policy URL | `https://ilwonyoon.github.io/steer_ai/privacy/` |
| Terms URL | `https://ilwonyoon.github.io/steer_ai/terms/` |
| Support Email | `superwedge.labs@gmail.com` |

### Promotional Text

Limit: 170 characters. Paste this:

```text
Steer turns waiting AI coding agents into iPhone action cards, so you can review context, send a reply, and keep work moving from anywhere.
```

Backup variant:

```text
When a local coding agent stops, Steer sends a focused iPhone card with the context and reply box you need to keep it moving.
```

### Keywords

Limit: 100 bytes. Paste this:

```text
ai coding,agent inbox,cli,dev tools,workflow,notifications,async coding,terminal,productivity
```

Rationale:

- Avoids third-party app/company names in the keyword field.
- Covers the actual search intent: AI coding, CLI workflows, developer tools, notifications, async productivity.
- Does not duplicate the app name.

### Description

Limit: 4,000 characters. Paste this:

```text
Steer is an action inbox for AI coding agents running on your Mac.

When a local coding agent stops to ask a question, hits a blocker, or finishes a task, Steer turns that moment into a focused iPhone card. Review the context, type a reply, and send it back to the right Mac session without returning to your desk.

WHY STEER

AI agents are most useful when they keep moving. Steer helps you catch the exact moments that need your input, so long-running coding sessions do not sit idle while you are away from the terminal.

WHAT YOU CAN DO

• Get notified when a Mac coding session needs attention
• Review action cards with provider, project, branch, summary, and short output excerpt
• Send replies back to the matching Steer-managed session
• Track queued, delivered, failed, and offline states
• Use Try Demo to explore the full card workflow without setting up a Mac
• Manage Sign in with Apple, notifications, support links, and account deletion from Settings

HOW IT WORKS

Steer for Mac wraps coding-agent sessions that you explicitly start. The iPhone app receives small action cards and sends replies through the Steer relay. Your Mac handles local session capture and local instruction delivery.

Steer is not a remote terminal, remote desktop client, or screen mirror. It does not expose a live shell prompt, stream your Mac screen, or let your iPhone browse or launch arbitrary Mac commands.

PRIVACY

Steer uses Sign in with Apple and has no third-party advertising or tracking SDKs. Full transcripts and files stay on your Mac. Only the action-card context needed for review and reply is synced when you enable iPhone Sync.

Steer for Mac is required for live cards. The iPhone app includes Try Demo so you can understand the workflow before connecting your own Mac.
```

### What's New

For version 1.0:

```text
Initial release.

Steer brings iPhone action cards to local Mac coding agents, with push notifications, focused review context, reply delivery, Try Demo, Sign in with Apple, and account deletion.
```

### Review Information

Sign-in required: **Yes**  
Demo account: **Not required**  
Explanation: built-in Try Demo mode provides reviewable functionality without a prepared Mac or private credentials.

Paste this into Notes for Review:

```text
Hello App Review team,

Steer is an action inbox for local Mac coding agents. The iPhone app lets a user review synced action cards from their own Mac and send replies that are queued through the Steer relay and delivered by Steer for Mac.

Steer is not a remote terminal, remote desktop client, live shell mirror, or arbitrary command launcher. The iPhone app does not execute commands directly and does not provide a terminal prompt. The Mac app owns local session capture and local instruction delivery.

No demo account or prepared Mac is required for review.

Reviewer flow:
1. Install and open Steer.
2. On the signed-out screen, tap Try Demo.
3. Review the sample action cards.
4. Type a reply and tap Send.
5. Open Settings from the top-right gear.
6. Verify Support, Privacy Policy, Terms, Sign Out, and Delete Account surfaces.

The demo uses local sample cards and simulated delivery state. Live sync requires the user's own Steer for Mac setup, but live sync is not required to evaluate the iPhone app's core card review and reply workflow.

Important limits:
- No live terminal mirror.
- No arbitrary command launcher from iPhone.
- No remote desktop streaming.
- No Accessibility, Screen Recording, or Input Monitoring permissions.
- No third-party advertising or tracking SDKs.
- Live delivery only targets sessions launched and owned by the user's own Steer for Mac setup.

Privacy Policy:
https://ilwonyoon.github.io/steer_ai/privacy/

Support:
https://ilwonyoon.github.io/steer_ai/support/

Contact:
superwedge.labs@gmail.com
```

## App Privacy Answers

Use `docs/legal/APP_STORE_PRIVACY_LABELS.md` as the implementation source of truth. Marketing summary:

| Data Type | Collected | Linked to User | Tracking | Purpose |
|---|---:|---:|---:|---|
| Contact Info - Email Address | Yes | Yes | No | App Functionality |
| Identifiers - User ID | Yes | Yes | No | App Functionality |
| Identifiers - Device ID | Yes | Yes | No | App Functionality, push routing |
| User Content - Other User Content | Yes | Yes | No | Action cards and replies |
| Diagnostics - Crash Data | Yes, if App Store diagnostics enabled | No | No | App Functionality |

Answer **No** for tracking. There are no third-party advertising or tracking SDKs.

Account deletion is available in-app from Settings -> Account -> Delete Account. It signs the user out, clears local auth, and deletes server-side account data.

## Screenshot Strategy

Apple accepts 1-10 screenshots per device size. For launch, use **six** screenshots. Six is enough to tell the complete story without making the product feel complicated.

Current screenshot sizing guidance:

- Upload an iPhone **6.9-inch** set first. Accepted portrait sizes include `1260 x 2736`, `1290 x 2796`, and `1320 x 2868`.
- A 6.5-inch set is optional if the 6.9-inch set is provided; App Store Connect can scale down where supported.
- iPad screenshots are not required because the App Store build is iPhone-only (`UIDeviceFamily = 1`).
- Screenshots must show the app in use. Text overlays are acceptable, but do not use abstract title cards as the whole screenshot.

### Visual Rules

- Use the real app UI, not mock screens.
- Use the simulator status bar override: 9:41, full battery, full Wi-Fi/cellular.
- Keep overlays short: one clear headline plus one supporting line at most.
- Do not show a full terminal prompt or anything that reads like remote shell control.
- Do not fake push notification banners unless the banner is captured from a real simulator/device notification.
- Redact any real project path, secret, customer data, token, or private repo name.
- Prefer dark mode if the current UI looks more premium and legible there; keep all screenshots in one appearance.

## Screenshot Set

### 1. Signed-Out Entry

State to capture: signed-out SignInPrompt with wordmark, value prop, Sign in with Apple, Try Demo, and legal links visible.

Overlay headline:

```text
Never let AI sit idle
```

Overlay subline:

```text
Review waiting coding agents from iPhone
```

Why this shot matters:

- Establishes the app promise in the first screenshot.
- Shows Try Demo before sign-in, which helps App Review and first-time users.
- Shows legal links are accessible without authentication.

Avoid:

- Cropping out Try Demo.
- Showing only the logo/login screen without product context.

### 2. Action Card Inbox

State to capture: demo or live inbox with one card focused, provider icon visible, project/branch metadata visible, and short terminal excerpt visible.

Overlay headline:

```text
One card for every waiting agent
```

Overlay subline:

```text
See the context without opening a terminal
```

Why this shot matters:

- Explains the core product shape: card stack, not chat and not screen mirroring.
- Shows that the iPhone app is useful and native.

Avoid:

- Dense terminal-like output filling the screen.
- Raw logs that look like a live shell.

### 3. Reply Composer

State to capture: reply field focused with keyboard open and a short draft typed, such as `Use the simpler endpoint.` Do not send yet.

Overlay headline:

```text
Reply from anywhere
```

Overlay subline:

```text
Send the next instruction back to your Mac session
```

Why this shot matters:

- Demonstrates the primary action.
- Makes it clear the iPhone app queues a reply rather than exposing a remote prompt.

Avoid:

- Phrases like "run command" or "control your Mac."

### 4. Delivery State

State to capture: a card or chip showing queued/delivered/running/offline state. If using demo mode, capture the simulated queued/delivered state after tapping Send.

Overlay headline:

```text
Know what happened next
```

Overlay subline:

```text
Queued, delivered, failed, and offline states stay visible
```

Why this shot matters:

- Shows trust and reliability.
- Reduces reviewer confusion about what happens after a reply is sent.

Avoid:

- Showing an ambiguous spinner with no status text.

### 5. No Waiting Actions

State to capture: connected empty state: `No waiting actions` with the Mac connection chip visible.

Overlay headline:

```text
Quiet when nothing needs you
```

Overlay subline:

```text
Steer only surfaces moments that need attention
```

Why this shot matters:

- Communicates restraint and avoids "always-on terminal monitor" framing.
- Shows the app has a complete empty state.

Avoid:

- Empty state copy that implies the iPhone can start Mac setup by itself.

### 6. Settings And Privacy

State to capture: Settings screen with identity row, Notifications, Report an Issue, Support, Privacy Policy, Terms, and Sign Out visible.

Overlay headline:

```text
Private by default
```

Overlay subline:

```text
No ads, no tracking, account controls built in
```

Why this shot matters:

- Supports App Review privacy expectations.
- Shows support/legal/account controls are easy to find.

Avoid:

- Cropping out Support or Privacy Policy.

## Optional Seventh Screenshot

Use only if the first six feel too abstract.

State to capture: Mac Sync Status sheet in demo or no-Mac mode.

Overlay headline:

```text
Built for your own Mac
```

Overlay subline:

```text
Live cards appear after you enable iPhone Sync
```

Why this shot matters:

- Makes the companion-app dependency transparent.
- Helps prevent rejection for unclear external requirements.

## Screenshot Filename Plan

Use this structure:

```text
apps/ios/build/screenshots/app-store/6.9/
  01-signed-out-entry.png
  02-action-card-inbox.png
  03-reply-composer.png
  04-delivery-state.png
  05-no-waiting-actions.png
  06-settings-privacy.png

apps/ios/build/screenshots/app-store/6.5/
  optional, only if manually produced
```

## App Preview Recommendation

Do **not** ship an app preview video for v1 unless there is time to produce a polished 15-30 second capture. Static screenshots are safer for launch because:

- The app's value is easy to explain in six screenshots.
- A poor video can make the app look more like terminal streaming.
- App previews add processing time and more review surface.

If producing a v1.1 app preview later, use this sequence:

1. Notification arrives.
2. User opens card.
3. User reads short context.
4. User sends reply.
5. Status changes to delivered.

## Store Page Narrative

The product page should read in this order:

1. Your AI is waiting.
2. Steer turns that waiting moment into an iPhone card.
3. You reply from anywhere.
4. Your Mac delivers the reply locally.
5. Nothing is tracked; full work stays on your Mac.

Do not lead with implementation details, wrappers, relay architecture, or provider-specific names. Mention providers only after the core promise is clear.

## Launch Announcement Copy

### Short Social Post

```text
Launching Steer for iPhone.

It turns waiting AI coding agents on your Mac into focused iPhone action cards, so you can review context, send a reply, and keep work moving without returning to your desk.
```

### Longer Launch Post

```text
Steer for iPhone is live.

The idea is simple: AI coding agents should not sit idle just because you missed the moment they asked a question.

Steer watches the coding-agent sessions you explicitly start on your Mac. When one stops, asks, or finishes, your iPhone gets a focused action card with the context you need and a reply box to keep it moving.

It is not a remote terminal or screen mirror. Your Mac owns the local session. Your iPhone is the action inbox.

No ads. No tracking. Sign in with Apple. Try Demo included.
```

### Press / Directory Blurb

```text
Steer is an iPhone action inbox for AI coding agents running on your Mac. It turns waiting agent moments into focused cards with context, notifications, and reply delivery, helping developers keep long-running CLI coding sessions moving from anywhere.
```

## Rejection Risk Controls

### Risk: Reviewer Thinks It Is A Remote Terminal

Mitigation:

- Store copy says "not a remote terminal" in review notes.
- Screenshots show cards, not a shell.
- Description explains Mac owns local delivery.
- No Accessibility, Screen Recording, or Input Monitoring permissions.

### Risk: Reviewer Cannot Evaluate Without Mac

Mitigation:

- Try Demo is available on the signed-out screen.
- Review notes start with "No demo account or prepared Mac is required."
- Screenshots include demo/card workflow, not only live companion setup.

### Risk: Metadata Overclaims Notification Or Live Sync

Mitigation:

- Description says Steer for Mac is required for live cards.
- Screenshots should not show fake push banners.
- Manual TestFlight verification still required for real APNS before submit.

### Risk: Privacy Label Mismatch

Mitigation:

- Privacy label includes Other User Content for action-card text and replies.
- Privacy label includes identifiers and email address.
- Description does not claim "no data leaves device"; it says full transcripts and files stay on Mac, while action-card context syncs when iPhone Sync is enabled.

### Risk: Account Deletion

Mitigation:

- Settings -> Account -> Delete Account exists.
- Review notes explicitly mention Delete Account.
- Support and Privacy pages are public.

## Final Submission Checklist

- [ ] Confirm App Store Connect app name and subtitle fit character limits.
- [ ] Paste metadata from this file.
- [ ] Use the safe keyword list without third-party names.
- [ ] Paste Review Notes from this file.
- [ ] Enter App Privacy answers from `docs/legal/APP_STORE_PRIVACY_LABELS.md`.
- [ ] Upload six 6.9-inch iPhone screenshots.
- [ ] Confirm Support, Marketing, Privacy, Terms URLs return 200.
- [ ] Confirm `.ipa` uses production APNS and App Store distribution signing.
- [ ] Run TestFlight on a real device.
- [ ] Verify Sign in with Apple, Try Demo, Settings links, Delete Account, APNS, and live Mac reply delivery.
- [ ] Submit for Review.

## Official References

- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- App Store Connect App Information: https://developer.apple.com/help/app-store-connect/reference/app-information
- App Store Connect Platform Version Information: https://developer.apple.com/help/app-store-connect/reference/platform-version-information
- Upload App Previews and Screenshots: https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/
- Screenshot Specifications: https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications
- App Privacy Details: https://developer.apple.com/app-store/app-privacy-details/
- Offering Account Deletion in Your App: https://developer.apple.com/support/offering-account-deletion-in-your-app/
