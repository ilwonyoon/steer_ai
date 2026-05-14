# App Store Connect — Copy/Paste Submission Sheet

This file is intentionally minimal. Every field below maps to a
single text input in App Store Connect. The longer rationale,
backup variants, and rejection-risk controls live in
`docs/APP_STORE_SUBMISSION_MARKETING_PACK.md`. Use this file only
when filling in the App Store Connect form.

All copy here is current as of v1.0.0 (build 1). Update both files
together; they are intentionally redundant so a future submission
does not drift between the rationale doc and the literal paste.

## App Information

| App Store Connect field | Value |
|---|---|
| Name | `Steer - Agent Inbox` |
| Subtitle | `Your AI codes. You answer.` |
| Bundle ID | `ai.steer.ios` |
| SKU | `STEER_IOS_001` |
| Primary Category | Developer Tools |
| Secondary Category | Productivity |
| Price | Free |
| Availability | All territories |
| Age Rating | 4+ |
| Copyright | `© 2026 Superwedge Labs` |

## URLs

| App Store Connect field | URL |
|---|---|
| Marketing URL | `https://ilwonyoon.github.io/steer_ai/` |
| Support URL | `https://ilwonyoon.github.io/steer_ai/support/` |
| Privacy Policy URL | `https://ilwonyoon.github.io/steer_ai/privacy/` |
| Terms URL | `https://ilwonyoon.github.io/steer_ai/terms/` |

## Promotional Text (170 char limit)

```text
Your AI keeps coding on your Mac. When it stops with a question, Steer turns the moment into a card — tap a suggestion or send a short reply. No code reading required.
```

## Keywords (100 byte limit)

```text
ai coding,agent inbox,cli,dev tools,workflow,notifications,async coding,terminal,productivity
```

## Description (4,000 char limit)

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

## What's New (4,000 char limit; v1.0.0)

```text
First public release.

Your codex and claude agents keep coding on your Mac. Steer shows up on your phone only when one of them stops with a question worth your time. Answer with a tap or a short line, then get back to your day.
```

## Review Information

**Sign-in required:** Yes
**Demo account:** Not required
**Explanation:** Try Demo on the signed-out screen provides the full reviewable flow without a prepared Mac or private credentials.

### Notes for Review (paste verbatim)

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

### Contact Information (App Store Connect)

| Field | Value |
|---|---|
| First Name | Ilwon |
| Last Name | Yoon |
| Phone | (use the number on file for the developer account) |
| Email | `superwedge.labs@gmail.com` |
| Sign-in required | Yes |

## Screenshots — 5 Shots, iPhone 6.9"

Capture target: `1320 × 2868` (iPhone 17 Pro Max). Apple scales
down to 6.7" / 6.5" sizes automatically. Overlay copy below the
literal in-app screen; the actual app capture comes from
`scripts/capture-app-store-screenshots.sh`.

| # | File | Overlay headline | Overlay subline |
|---|---|---|---|
| 1 | `01-your-ai-codes-you-answer.png` | `Your AI codes. You answer when it asks.` | `Sign in to connect the codex and claude sessions running on your Mac.` |
| 2 | `02-phone-shows-up-when-agent-stops.png` | `The phone shows up only when your agent stops.` | `One card per moment. No logs to scroll, no live terminal to watch.` |
| 3 | `03-answer-like-text.png` | `Answer like you'd answer a text.` | `Tap a suggested answer, or send one short line. The agent picks up where it stopped.` |
| 4 | `04-back-to-empty.png` | `Back to empty.` | `Your AI is still building on your Mac. The inbox stays quiet until it has another question.` |
| 5 | `05-no-code-no-terminal.png` | `You don't need to read the code.` | `Steer turns agent questions into plain-language cards. The terminal stays on your Mac, where it belongs.` |

## App Privacy Answers

Use the literal values in `docs/legal/APP_STORE_PRIVACY_LABELS.md`.
Do not re-derive privacy answers from the description text — the
privacy form is more granular than the description and has its own
required exact phrasing.

## Submission Checklist

- [ ] Upload `.ipa` via Xcode Organizer or `xcrun altool`
- [ ] Wait for build processing email (~5–15 min)
- [ ] Paste App Information fields above
- [ ] Paste URLs
- [ ] Paste Promotional Text, Keywords, Description, What's New
- [ ] Paste Review Notes
- [ ] Confirm App Privacy answers match `APP_STORE_PRIVACY_LABELS.md`
- [ ] Upload 5 screenshots to the 6.9" slot
- [ ] Confirm Support, Marketing, Privacy, Terms URLs return 200
- [ ] Add this build to the "1.0.0" version
- [ ] Submit for Review
