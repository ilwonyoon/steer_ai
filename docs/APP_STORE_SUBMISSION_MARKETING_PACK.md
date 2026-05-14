# Steer iOS App Store Submission Marketing Pack

Last updated: 2026-05-14
Audience: App Store Connect submission, App Review, screenshot production, launch copy  
Primary localization: English (U.S.)

This is the product-marketing source of truth for launching Steer on the iPhone App Store. It is written to answer four practical questions:

1. What is this app?
2. How should it be positioned so App Review understands it?
3. What exactly should be pasted into App Store Connect?
4. What screenshots should be uploaded, and what overlay text should each one use?

## Launch Positioning

### One-Line Positioning

Your AI codes. You answer when it asks. Steer is the small iPhone inbox where Mac coding agents bring their questions, and where you tap a suggestion (or type one line) to keep them moving.

### Differentiation In One Sentence

Other apps in this space — CC Pocket, Happy, Mobile IDE — give working developers a way to control coding agents from anywhere. Steer is for the other side: the user who set the agents loose, doesn't intend to read every diff, and only wants to step in when an agent actually has a question.

### Short Product Story

If you can read and review every line your AI codes, you already have a hundred apps for that. Steer is for the user who delegates the work and only wants to see the AI when it actually has a question to ask.

The codex and claude sessions stay on your Mac and keep working. The iPhone surface stays empty until one of them stops with a decision worth your attention. A card appears with the question in plain language and a few suggested answers. Tap one of them, or type one short reply. The card disappears, the agent picks up where it stopped, and the inbox goes quiet again.

You do not have to open a terminal. You do not have to read the code. You do not have to remember which session was which. The agent walks up to you with the smallest possible ask.

### App Review Framing

Use this framing everywhere:

- **Say:** quiet agent inbox, decision card, the agent stops and asks, suggested reply, your Mac runs the agent locally.
- **Avoid:** remote terminal, remote shell, remote desktop, screen mirror, control your Mac, run commands from iPhone, mobile IDE.
- **Clarify when needed:** Steer carries the agent's question and your short reply. The terminal, the code, and the full output never leave the Mac.
- **Be honest about smallness:** the iPhone surface is deliberately small. There is no live terminal, no log feed, no command palette, no agent sidebar. That is the design.

### Target User

Primary user: people who let AI handle most of the coding (vibe coders, non-engineers running coding agents, busy operators who delegate to codex/claude). They are not opening a phone IDE — they want to be left alone unless the agent has an actual question.

Secondary user: developers who run long agent sessions while away from the terminal and want a quieter mobile companion than the existing remote-control apps.

Not the target: power users who want to drive a mobile IDE, scroll live logs, or manage many sessions from the phone. Steer trades those features for a much smaller, quieter inbox surface, and that tradeoff is intentional.

### Launch Promise

Get back to your day. Your agents will come find you when they actually need a decision.

## App Store Connect Fields

### App Information

| Field | Value |
|---|---|
| App Name | `Steer - Agent Inbox` |
| Subtitle | `Your AI codes. You answer.` |
| Bundle ID | `ai.steer.ios` |
| SKU | `STEER_IOS_001` |
| Primary Category | Developer Tools |
| Secondary Category | Productivity |
| Price | Free |
| Availability | All territories |
| Age Rating | Expected 4+ |
| Copyright | `© 2026 Superwedge Labs` |

Notes:

- Use `Steer - Agent Inbox` consistently across App Store Connect and launch materials.
- Subtitle `Your AI codes. You answer.` carries the differentiation directly: the user's role is to answer, not to write. Avoids duplicating the searchable app/company name and avoids any phrasing that suggests phone-driven code execution.

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
Your AI keeps coding on your Mac. When it stops with a question, Steer turns the moment into a card — tap a suggestion or send a short reply. No code reading required.
```

Backup variant (slightly shorter, more neutral phrasing):

```text
When your Mac coding agent has a question, Steer brings it to your phone as a small card with a few suggested answers. Tap one, get back to your day.
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
Your AI codes. You answer when it asks.

Steer is the quiet inbox where coding agents running on your Mac come to ask questions. When codex or claude stops with a decision it needs from you, Steer turns the moment into a focused iPhone card — usually with a few suggested answers you can tap. When they don't need anything, the inbox stays empty and you get back to your day.

WHY STEER

If you can read and review every line your AI codes, you already have a hundred apps for that. Steer is for the other side: you set the AI loose on the work, it goes off and codes on your Mac, and you only want to step in when it actually has a question.

The category trend is "control your Mac agents from anywhere." Steer is intentionally the opposite shape — most of the time the phone is empty. The point of the product is being undisturbed except for the small moments when an answer from you actually matters.

WHAT YOU CAN DO

• Get notified the moment a codex or claude session on your Mac stops with a question
• Review the question as a plain-language card with project, branch, and a short context excerpt
• Reply with one tap on a suggested answer, or type one line yourself
• Let the agent pick up where it stopped — without going back to your desk
• Track replies you've already sent and any that need a retry
• Use Try Demo to walk the full card → reply → empty → next-card loop before connecting a Mac
• Manage Sign in with Apple, notifications, support links, and account deletion from Settings

HOW IT WORKS

You run codex or claude in your Mac terminal the way you normally would. Wrap each session with the local `steer` companion (one command at the start of the session). When the agent stops with a question or finishes a task, the question shows up on iPhone as a card. Your reply is queued back into the same Mac terminal session — the agent picks up where it stopped and keeps going.

WHAT THIS APP DOES NOT DO

Steer is deliberately small. It is not a remote terminal, remote desktop client, screen mirror, or mobile IDE. It does not run code on your phone, does not show a live terminal, does not stream your Mac screen, and does not let your phone browse your Mac. The agent itself stays in the Mac terminal where you started it. Steer only carries the agent's question to your phone and your short reply back. Everything else — the codebase, the full output, the file system — never leaves your Mac.

PRIVACY

Steer uses Sign in with Apple. There are no third-party advertising or tracking SDKs. Full transcripts, source files, and shell access stay on your Mac. Only the small action-card context you need to make a decision is synced through the Steer relay when you enable iPhone Sync. Account and data deletion are available in Settings.

REQUIREMENTS

• A Mac with macOS 15 or later
• The local `steer` companion installed on the Mac (instructions at the marketing link)
• codex or claude CLI installed on the Mac

This app is not affiliated with, endorsed by, or associated with Anthropic or OpenAI. Codex and Claude Code are trademarks of their respective owners.

Made by a small team. Feedback: superwedge.labs@gmail.com
```

### What's New

For version 1.0:

```text
First public release.

Your codex and claude agents keep coding on your Mac. Steer shows up on your phone only when one of them stops with a question worth your time. Answer with a tap or a short line, then get back to your day.
```

### Review Information

Sign-in required: **Yes**  
Demo account: **Not required**  
Explanation: built-in Try Demo mode provides reviewable functionality without a prepared Mac or private credentials.

Paste this into Notes for Review:

```text
Hello App Review team,

Steer is a deliberately small iPhone inbox for AI coding agents that run on the user's own Mac (codex CLI and Claude Code CLI). When one of those Mac sessions stops with a question, Steer surfaces the moment as a card on iPhone; the user taps a suggested answer or types one short line. The reply is queued back to the Mac terminal session that asked, and the agent picks up where it left off.

The intentional product shape: the iPhone surface stays empty by default. There is no terminal, no live shell, no log feed, no command palette, no remote desktop, no Mac browser. The iPhone never runs code. All execution stays in the Mac terminal where the user started the agent.

Target user note: Steer is positioned for users who delegate most coding to AI agents and only step in to answer questions (often called "vibe coders" / non-engineers running coding agents, but also developers who simply prefer a quieter mobile surface). The design tradeoff is fewer power-user features in exchange for a much smaller, calmer inbox. If the reviewer is comparing to other apps in the category (CC Pocket, Happy, mobile IDE listings), the absence of those power features is intentional — they belong on the Mac, not the phone.

No demo account or prepared Mac is required for review.

Reviewer flow:
1. Install and open Steer.
2. On the signed-out screen, tap Try Demo.
3. Walk through the sample cards in the demo carousel.
4. Tap into the reply field on a card, type a short line, tap Send. Confirm the card resolves and the inbox returns to its empty state.
5. Open Settings from the top-left gear icon.
6. Verify Support, Privacy Policy, Terms, Sign Out, and Delete Account are all reachable.

The demo uses local sample cards and simulated delivery state. Live sync requires the user's own Mac with the local steer companion installed, but live sync is not required to evaluate the iPhone app's core card → reply → empty loop.

Important limits:
- No live terminal mirror.
- No arbitrary command launcher from iPhone.
- No remote desktop streaming.
- No Accessibility, Screen Recording, or Input Monitoring permissions.
- No third-party advertising or tracking SDKs.
- Live delivery only targets agent sessions the user launched themselves on their own Mac with the local steer companion.

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

Five shots. Each one carries a single piece of the product promise and lands one differentiator a "control-your-agent" listing cannot. Together they read as:

1. The user's role is to answer, not to write.
2. The phone is empty by default — it shows up only when an agent stops.
3. Answering is one tap or one short line, not a command palette.
4. After every answer the inbox goes quiet again.
5. There is no terminal, no log feed, no remote shell — that is on purpose.

### 1. Your AI Codes. You Answer When It Asks.

State to capture: signed-out screen. Steer wordmark, Sign in with Apple, Try Demo, legal links. The empty routing field reads as "nothing yet" — that is the point.

Overlay headline:

```text
Your AI codes. You answer when it asks.
```

Overlay subline:

```text
Sign in to connect the codex and claude sessions running on your Mac.
```

Why this shot matters:

- States the role split up front: AI writes, you answer.
- Names codex and claude so App Review knows exactly what is being controlled.
- Shows Sign in with Apple and legal links are reachable before any live data.

Avoid:

- "Connect your Mac" without the role split — that frames Steer as a generic setup app.
- Copy that suggests the user will write or run code from the phone.

### 2. The Phone Shows Up Only When Your Agent Stops.

State to capture: live or demo inbox with one or two waiting cards. Provider glyph, project/branch label, short summary excerpt. If a running-count chip is visible, keep it visible.

Overlay headline:

```text
The phone shows up only when your agent stops.
```

Overlay subline:

```text
One card per moment. No logs to scroll, no live terminal to watch.
```

Why this shot matters:

- Carries the deliberate-quiet differentiator that no remote-control app advertises.
- Shows the card surface is small on purpose.
- Names "no logs, no live terminal" so App Review reads the framing twice.

Avoid:

- A screen that fills the canvas with terminal-shaped output.
- More than two cards on screen — that suggests a feed, not an inbox.

### 3. Answer Like You'd Answer A Text.

State to capture: focused card with the reply field open. Either a suggested-reply chip is highlighted, or a short typed line such as `Use the simpler one.` is present. Do not send.

Overlay headline:

```text
Answer like you'd answer a text.
```

Overlay subline:

```text
Tap a suggested answer, or send one short line. The agent picks up where it stopped.
```

Why this shot matters:

- The reply UI is the actual product — make it look like a messaging surface, not a command palette.
- Shows the "no code reading required" promise without saying it: the user is sending plain English.
- Frames the reply as a queued instruction to the existing Mac session, never as a remote command.

Avoid:

- Phrases like "run command", "control your Mac", "execute".
- A reply that itself looks like a shell command.

### 4. Back To Empty.

State to capture: connected empty state right after the last waiting card has been answered. The N running chip is visible, the checkmark glyph is at its resting frame, and the rest of the canvas is intentionally empty.

Overlay headline:

```text
Back to empty.
```

Overlay subline:

```text
Your AI is still building on your Mac. The inbox stays quiet until it has another question.
```

Why this shot matters:

- This is the clearest UX delta versus every other listing in the category.
- Turns the empty state into a positive product value, not a "feature missing" signal.
- Makes the loop explicit: answer → empty → next question, never a busy dashboard.

Avoid:

- A blank empty state without the running-count chip or checkmark.
- A loading spinner that reads like the app is still fetching.

### 5. You Don't Need To Read The Code.

State to capture: Settings screen with identity row, Notifications, Report an Issue, Support, Privacy Policy, Terms, Sign Out, and Delete Account visible. Keep the layout calm — this slide is a summary, not a feature menu.

Overlay headline:

```text
You don't need to read the code.
```

Overlay subline:

```text
Steer turns agent questions into plain-language cards. The terminal stays on your Mac, where it belongs.
```

Why this shot matters:

- Final slide states the differentiator a reviewer or new user might still be unsure about: no code reading, no terminal exposure.
- Combines the privacy/account surface with the closing message so support, legal, and the differentiator share a single shot.
- Sets the expectation about what is and is not on the iPhone in one sentence.

Avoid:

- Cropping out Support, Privacy Policy, or Delete Account.
- Adding a separate "Connected to your Mac" shot — the Mac relationship is already covered in shots 1 and 2.

## Optional Sixth Screenshot

Use only if the five-shot set leaves the "what happens after I tap Send" question genuinely open. Most users will not need it.

State to capture: a card or chip showing queued, delivered, or failed state. In demo mode this is the simulated queued/delivered state right after tapping Send.

Overlay headline:

```text
Know what happened to your reply.
```

Overlay subline:

```text
Queued, delivered, failed, offline — every state stays visible.
```

Why this shot matters:

- Shows trust and reliability without claiming live remote control.
- Helps if the reviewer asks "what happens after Send" but the demo flow already covers it.

## Screenshot Filename Plan

Use this structure:

```text
apps/ios/build/screenshots/app-store/6.9/
  01-your-ai-codes-you-answer.png
  02-phone-shows-up-when-agent-stops.png
  03-answer-like-text.png
  04-back-to-empty.png
  05-no-code-no-terminal.png

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

1. Your AI is coding on your Mac.
2. Most of the time you should not have to look at the phone.
3. When the AI hits a question only you can answer, Steer brings the moment to you.
4. You answer in plain language — one tap or one line.
5. The agent picks up. The inbox goes quiet again.

Do not lead with implementation details, wrappers, or relay architecture. Mention codex and claude by name only after the role split (your AI codes / you answer) is clear, so readers anchor on the UX before the integration.

## Launch Announcement Copy

### Short Social Post

```text
Steer for iPhone is out.

Your AI keeps coding on your Mac. Steer is the small phone inbox where it comes to ask questions when it actually needs one. Tap a suggested answer, or send one short line, and the agent picks up where it stopped.

For the people who let the AI write, and just want to answer when it asks.
```

### Longer Launch Post

```text
Steer for iPhone is live today.

There is already a whole category of "control your coding agent from your phone" apps. Steer is built for the other shape on purpose: the user who set the AI loose, doesn't intend to read every diff, and only wants to step in when the agent actually has a question.

Your codex or claude sessions keep running on your Mac. Your phone stays empty until one of them stops with a decision only you can make. A card shows up with the question in plain language and a few suggested replies. Tap one, or type a short line, and the agent picks up where it left off.

It is not a remote terminal. It is not a mobile IDE. It is an inbox that is quiet by design and only shows up when an answer from you actually matters.

No ads. No tracking. Sign in with Apple. Try Demo included.
```

### Press / Directory Blurb

```text
Steer is the quiet iPhone inbox for AI coding agents running on your Mac. When a codex or claude session stops with a question, Steer turns the moment into a plain-language card with suggested replies. Tap one, or send a short line, and the agent picks up where it stopped — no terminal, no remote shell, no log feed.
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

### Risk: Reviewer Compares Against CC Pocket / Happy / Mobile IDE Listings

Reviewers familiar with the category may expect Steer to offer the same "control everything from your phone" surface those apps advertise. Steer's deliberately small surface can read as "missing features" if framed wrong.

Mitigation:

- Description and screenshots lead with the role split: AI codes, user answers. The smallness is the product, not a gap.
- Description includes an explicit "What this app does NOT do" section so reviewers find the framing twice.
- Try Demo flow walks the full card → reply → empty → next-card loop. The empty state is the point, not a bug.
- Review notes include the target-user note (vibe coders / delegators) so the reviewer understands the design tradeoff.

## Final Submission Checklist

- [ ] Confirm App Store Connect app name and subtitle fit character limits.
- [ ] Paste metadata from this file.
- [ ] Use the safe keyword list without third-party names.
- [ ] Paste Review Notes from this file.
- [ ] Enter App Privacy answers from `docs/legal/APP_STORE_PRIVACY_LABELS.md`.
- [ ] Upload five 6.9-inch iPhone screenshots (sixth optional only if the reply-state card is needed).
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
