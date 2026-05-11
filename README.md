# Steer

**Approve your Mac AI from your phone.**

Steer is an action queue for CLI coding agents. When Claude Code, Codex, or any wrapped terminal agent pauses for input — a question, a decision, a blocker — it turns into a card on your Mac and your iPhone. You answer from whichever device you're on, and the reply goes straight back into the terminal session.

It's built for the way vibe-coders actually work: you kick off three sessions in three folders, walk away from your desk, and the AI pings you when it needs you. No window juggling, no terminal hunting, no shoulder-surfing your own scrollback.

---

## Quick Start

You need two pieces:

1. **Steer for Mac** — runs in the menu bar, watches your wrapped terminal sessions, and pushes cards to iPhone.
2. **The `steer` CLI** — a tiny wrapper around the AI you already use (`steer claude`, `steer codex`, `steer wrap -- <anything>`).

### 1. Install the Mac app

The signed and notarized `.dmg` is on the [Releases page](https://github.com/ilwonyoon/steer_ai/releases/latest).

- Download `Steer-<version>.dmg`.
- Open it and drag `Steer.app` into `/Applications`.
- Launch it from Spotlight. Gatekeeper trusts the notarized build directly — no right-click bypass.

**Requires macOS 26 (Tahoe) or later.** Steer's chrome uses the system Liquid Glass material, which only exists from macOS 26 onward. Older versions of macOS are not supported in the current release.

### 2. Install the `steer` CLI

The CLI is a Node workspace. You need Node 22.5 or later (it uses the native `node:sqlite` module).

```sh
git clone https://github.com/ilwonyoon/steer_ai.git
cd steer_ai
npm install
```

That gives you a `steer` binary inside `packages/cli/src/index.js`. Symlink it into your path or run it via `npm run steer --`. From Steer for Mac's Settings → Folder access you can also have the app generate the symlink for you.

### 3. Wrap your first session

In any terminal, in any project folder:

```sh
steer claude          # Claude Code
steer codex           # Codex CLI
steer wrap -- node    # Anything else
```

Use the AI as you normally would. When it stops talking — finishes a turn, asks a clarifying question, hits a blocker — Steer notices and a card appears.

### 4. (Optional) Pair iPhone

Open Steer for Mac → Settings → iPhone Sync → **Sign in with Apple**. Then download Steer from the App Store, sign in with the same Apple ID, and allow notifications when prompted.

Your iPhone now mirrors every actionable card. Tap a card, type a reply, and the terminal on your Mac receives it.

---

## What appears as a card

Steer only surfaces sessions you can actually do something with:

| Category   | When it fires |
| ---------- | --- |
| Waiting    | The agent finished a turn and is idle, waiting for your next instruction. |
| Question   | The agent asked a clarifying question. |
| Decision   | The agent wants you to pick between options (yes / no, A / B). |
| Blocker    | The agent hit something it can't proceed past (failing test, missing credential, permission prompt). |

Quiet states — completion, progress reports, idle ping-pong — never push a card. They stay in the terminal where they belong.

---

## Privacy and what syncs

What goes through the Steer relay (Cloudflare Workers + D1, encrypted in transit):

- Card titles, summaries, and the last few lines of terminal output the agent printed.
- Replies you type on iPhone.
- Live session metadata (project name, branch, run state) so the iPhone connection chip stays accurate.

What stays on your Mac:

- The full raw transcript.
- Files, environment variables, secrets — anything the agent wrote but didn't print into the card.
- Local SQLite at `~/.steer/steer.sqlite`.

Delete-account in Settings revokes your Sign in with Apple grant, wipes your relay data, and clears the local Keychain session token. App Store guideline 5.1.1(v) compliant.

---

## Troubleshooting

**"Steer is not signed by an identified developer."** You're on macOS < 26, or you downloaded an old build. Grab the latest `.dmg` from Releases. If Gatekeeper still complains on macOS 26, right-click → Open and confirm — only needed once per build.

**iPhone shows "Mac offline."** The Mac app heartbeats every 15 seconds. If the chip is stale for more than a minute, check:
- Mac Steer.app is running (look for the gear-shift icon in the menu bar).
- iPhone Sync toggle in Mac Settings is on.
- You're signed in to the same Apple ID on both devices.

**Cards stop appearing.** If your terminal session is under `~/Documents`, `~/Desktop`, or `~/Downloads`, macOS may need Full Disk Access. Mac Settings → Folder Access → Open Full Disk Access, then add Steer.

**`steer claude --headless` fails.** The CLI auto-spawns `SteerAgent` when needed. If it gets stuck, delete the stale socket (`rm ~/.steer/steer.sock`) and rerun.

---

## For contributors

If you want to hack on Steer, the codebase layout, contributor workflow, and architectural decisions live in [`AGENTS.md`](AGENTS.md) and [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md). The project is structured as:

```text
apps/mac/             # SwiftUI macOS shell (SwiftPM, macOS 26+)
apps/ios/             # SwiftUI iOS shell (xcodegen, iOS 17+)
apps/prototype/       # Static HTML UX prototype
packages/agent/       # Node SteerAgent: Unix socket server, SQLite store, classifier
packages/cli/         # Node `steer` CLI: wrapper, provider adapters, send/sessions
packages/relay/       # Cloudflare Workers relay (D1 + Durable Objects)
packages/SteerCore/   # Cross-platform Swift package (shared types, backoff helper)
docs/                 # PRD, TECH_SPEC, CLASSIFIER_CONTRACT, REGRESSION_CONTRACT, etc.
scripts/              # build-mac-app.sh, release-mac.sh, verify-steer-regression.sh
```

Run the test suites:

```sh
npm test                                    # Node side: agent + cli
swift test --package-path packages/SteerCore # Cross-platform helpers
swift test --package-path apps/mac           # Mac unit tests (if you wire them in)
xcodebuild test -project apps/ios/Steer.xcodeproj \
  -scheme Steer \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SteerUITests/CardFlowUITests   # iOS smoke
```

Build a local Mac bundle:

```sh
scripts/build-mac-app.sh   # Ad-hoc-signed dogfood build
open .build/SteerMac.app
```

Cut a signed + notarized release (Developer ID cert + notarytool keychain profile required):

```sh
scripts/release-mac.sh
```

---

## Status

Steer is in active early execution. macOS + iOS clients are dogfooding daily and end-to-end APNS push works. The Cloudflare relay is live; see [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md) for the current backlog.
