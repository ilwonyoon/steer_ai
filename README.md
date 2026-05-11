<p align="center">
  <img src="./docs/assets/app-icon.png" alt="Steer" width="160" />
</p>

<h1 align="center">Steer</h1>
<p align="center">An action queue for your Mac AI coding agents — answer them from your phone.</p>

<p align="center">
  <a href="https://github.com/ilwonyoon/steer_ai/releases/latest/download/Steer-0.1.1.dmg">
    <img src="./docs/assets/download-macos-badge.svg" alt="Download Steer for macOS" width="200" />
  </a>
</p>

<p align="center">
  <a href="https://github.com/ilwonyoon/steer_ai/releases/latest"><img src="https://img.shields.io/github/v/release/ilwonyoon/steer_ai?label=release&color=4c71f2" alt="Latest release" /></a>
  <a href="https://github.com/ilwonyoon/steer_ai/stargazers"><img src="https://img.shields.io/github/stars/ilwonyoon/steer_ai?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-555?logo=apple" alt="macOS 26+" />
  <img src="https://img.shields.io/badge/iOS-17%2B-555?logo=apple" alt="iOS 17+" />
</p>

<p align="center">
  <img src="./docs/assets/hero.png" alt="Mac card stack and iPhone card mirroring the same paused session" width="900" />
</p>

<p align="center">
  <a href="https://github.com/ilwonyoon/steer_ai/releases/latest">Download</a> · <a href="EXECUTION_PLAN.md">Roadmap</a> · <a href="AGENTS.md">Contribute</a>
</p>

---

You run three Claude Code sessions in three folders, walk away from your desk, and the AI pings you when it needs you. No window juggling, no terminal hunting, no shoulder-surfing your own scrollback.

Steer wraps any CLI coding agent — Claude Code, Codex, Gemini, anything that talks through a terminal — and turns the moments it pauses for input into cards on your Mac and your iPhone. Type a reply on whichever device you're on, and the answer goes straight back into the wrapped session's stdin.

## Features

<table>
<tr>
<td width="40%" valign="middle">
<h3>Card stack, not a chat log</h3>
The Mac app stays quiet while your agents are working. The instant one stops — waiting, asking, blocked, deciding — it surfaces as a card with the last few lines of terminal output. Quiet states never bother you.
</td>
<td width="60%">
<img src="./docs/assets/mac-card-stack.png" alt="Mac card stack" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Approve from your phone</h3>
Open Steer for iPhone, see every actionable session, tap a card, type a reply. The terminal on your Mac receives it through the same wrapper that owns the session.
</td>
<td width="60%">
<img src="./docs/assets/iphone-reply.png" alt="iPhone card with reply dock" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Push the second the agent stops</h3>
APNS notifications land on your phone the moment the wrapper sees Claude's <code>Stop</code> hook or a Codex <code>turn/completed</code>. Tap to jump straight into the right card.
</td>
<td width="60%">
<img src="./docs/assets/push-notification.png" alt="iOS push notification banner" width="100%" />
</td>
</tr>
</table>

- **Wraps anything with a stdin** — `steer claude`, `steer codex`, or `steer wrap -- <any-command>`. Provider-specific adapters light up where they exist (Claude stream-json, Codex app-server JSON-RPC); raw PTY for the rest.
- **No Accessibility permission** — The wrapper owns the PTY, so injection is just stdin, not synthetic keystrokes against another app's window.
- **Local-first** — Transcripts and the SQLite store at `~/.steer/steer.sqlite` never leave your Mac. Only card titles, summaries, and the last few terminal lines reach the relay so iPhone can mirror them.
- **Hooks-aware** — `steer install-claude-hooks` wires Claude Code's Stop/Notification/StopFailure so cards open the instant Claude stops talking, not on polling.
- **Liquid Glass on Tahoe** — The Mac menu bar uses the system glass material introduced in macOS 26.
- **Notarized direct distribution** — Gatekeeper trusts the signed `.dmg` directly. No App Store sandbox, no manual override.

## Install

### DMG (recommended)

<a href="https://github.com/ilwonyoon/steer_ai/releases/latest/download/Steer-0.1.1.dmg">
  <img src="./docs/assets/download-macos-badge.svg" alt="Download Steer for macOS" width="200" />
</a>

Open the `.dmg`, drag **Steer** into `/Applications`, launch it from Spotlight.

**Requires macOS 26 (Tahoe) or later.** The menu bar uses the system Liquid Glass material, which only exists from macOS 26 onward.

### The `steer` CLI

The CLI is a Node workspace. You need Node 22.5 or later (the agent uses native `node:sqlite`).

```sh
git clone https://github.com/ilwonyoon/steer_ai.git
cd steer_ai
npm install
```

That gives you a `steer` binary at `packages/cli/src/index.js`. Symlink it into your `$PATH`, or let Steer for Mac generate the symlink from **Settings → Folder Access**.

Then wrap any session:

```sh
steer claude          # Claude Code
steer codex           # Codex CLI
steer wrap -- node    # Anything else
```

### Pair your iPhone (optional)

1. Open Steer for Mac → **Settings → iPhone Sync** → **Sign in with Apple**.
2. Download Steer from the App Store, sign in with the same Apple ID, allow notifications when prompted.

Every actionable card now mirrors to your phone, and replies you type there land in the wrapped session on your Mac.

## Why Steer?

I keep multiple coding agents running in parallel — Claude Code in one repo, Codex in another, sometimes a third doing something silly with Gemini. The thing that breaks the flow is not the agents being slow. It's the moment one of them stops talking and I don't notice because I'm in a different terminal, a different window, or another room.

The fix isn't another chat UI. I have plenty of those. The fix is a **queue**: every paused session shows up exactly once, you answer it, it disappears. The wrapped CLI session is the source of truth, the card is the in-tray, and replies are just stdin to that session. No transcripts shipped to the cloud, no Accessibility permission, no synthetic keystrokes. You can be on the couch, type a `lgtm` or `try the staging URL instead`, and the terminal on your Mac picks up where it left off.

The iPhone half is the part that took the longest, because it has to look right while staying honest about what it actually does. It's not a remote shell. It's not "Claude on iPhone." It's an inbox of *your* Mac's coding agents — one row per session that needs you, with just enough terminal context to answer in one tap.

## Status

Steer is in early dogfooding. The Mac + iOS clients run daily, APNS push works end-to-end, the Cloudflare relay is live. Today's [`v0.1.1` release](https://github.com/ilwonyoon/steer_ai/releases/tag/v0.1.1) is the first signed and notarized DMG; see [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md) for the active backlog and decision log.

## Troubleshooting

**"Steer is not signed by an identified developer."** You're on macOS < 26, or you downloaded an old build. Grab the latest `.dmg` from Releases.

**iPhone shows "Mac offline."** Mac heartbeats every 15 seconds. If the chip stays stale longer than a minute, confirm Steer.app is running (gear-shift icon in menu bar), iPhone Sync is on in Mac Settings, and both devices use the same Apple ID.

**Cards stop appearing.** If your session is under `~/Documents`, `~/Desktop`, or `~/Downloads`, macOS may need Full Disk Access. Mac Settings → Folder Access → Open Full Disk Access, then add Steer.

**`steer claude --headless` hangs.** Delete the stale socket (`rm ~/.steer/steer.sock`) and rerun. The CLI re-spawns `SteerAgent` automatically.

## For contributors

Layout, contributor workflow, and architectural decisions live in [`AGENTS.md`](AGENTS.md) and [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md).

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
npm test                                              # Node side: agent + cli
swift test --package-path packages/SteerCore          # Cross-platform helpers
swift build --package-path apps/mac                   # Mac compile gate
xcodebuild test -project apps/ios/Steer.xcodeproj \
  -scheme Steer \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SteerUITests/CardFlowUITests          # iOS smoke
```

Build a local Mac bundle:

```sh
scripts/build-mac-app.sh         # Ad-hoc-signed dogfood build
open .build/SteerMac.app
```

Cut a signed + notarized release (Developer ID cert + notarytool keychain profile required):

```sh
scripts/release-mac.sh
```

---

<p align="center"><sub>Built for the way vibe-coders actually work.</sub></p>
