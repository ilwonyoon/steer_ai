<p align="center">
  <img src="./docs/assets/app-icon.png" alt="Steer" width="160" />
</p>

<h1 align="center">Steer</h1>
<p align="center">Inbox for your CLI coding agents on macOS.</p>

<p align="center">
  <a href="https://github.com/ilwonyoon/steer_ai/releases/latest/download/Steer-0.1.1.dmg">
    <img src="./docs/assets/download-macos-badge.svg" alt="Download Steer for macOS" width="200" />
  </a>
</p>

<p align="center">
  <a href="https://github.com/ilwonyoon/steer_ai/releases/latest"><img src="https://img.shields.io/github/v/release/ilwonyoon/steer_ai?label=release&color=4c71f2" alt="Latest release" /></a>
  <a href="https://github.com/ilwonyoon/steer_ai/stargazers"><img src="https://img.shields.io/github/stars/ilwonyoon/steer_ai?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-555?logo=apple" alt="macOS 26+" />
</p>

<p align="center">
  <img src="./docs/assets/hero.png" alt="Steer for Mac — card stack of paused coding agent sessions" width="900" />
</p>

---

**Who it's for.** People running multiple CLI coding agents in parallel — Claude Code in one repo, Codex in another, maybe a third doing something with Gemini.

**What it does.** Wraps each session, watches when it stops talking, and surfaces only the stopped ones as a card stack in your menu bar. Type a reply on the card; it goes straight into the wrapped session's stdin.

**Why.** Multiple terminals across spaces means you stop noticing when an agent pauses. A queue of "needs you" cards beats hunting through tabs.

## Features

<table>
<tr>
<td width="40%" valign="middle">
<h3>Quiet stack of stopped sessions</h3>
Running agents stay silent. The moment one stops — waiting, asking, blocked — it shows up as a card with the last few lines of terminal output. One active card per session.
</td>
<td width="60%">
<img src="./docs/assets/mac-card-stack.png" alt="Mac card stack" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Reply is stdin, not synthetic keys</h3>
The wrapper owns the PTY, so your reply on the card is just stdin to the wrapped agent. No Accessibility permission, no synthetic keystrokes, no fragile UI scripting.
</td>
<td width="60%">
<img src="./docs/assets/mac-reply.png" alt="Replying to a card" width="100%" />
</td>
</tr>
</table>

- **Wraps anything** — `steer claude`, `steer codex`, or `steer wrap -- <any-command>`. Provider-specific adapters (Claude stream-json, Codex app-server JSON-RPC) where they exist; raw PTY otherwise.
- **Hooks-aware** — `steer install-claude-hooks` wires Claude Code's Stop/Notification so cards open the instant Claude stops, not on polling.
- **Local-only** — Transcripts and the SQLite store at `~/.steer/steer.sqlite` never leave your Mac.
- **Notarized** — Gatekeeper trusts the signed `.dmg` directly. No App Store sandbox, no manual override.

## Install

<a href="https://github.com/ilwonyoon/steer_ai/releases/latest/download/Steer-0.1.1.dmg">
  <img src="./docs/assets/download-macos-badge.svg" alt="Download Steer for macOS" width="200" />
</a>

Open the `.dmg`, drag **Steer** into `/Applications`, launch from Spotlight.

**Requires macOS 26 (Tahoe) or later.** The menu bar uses the system Liquid Glass material introduced in macOS 26.

### The `steer` CLI

You also need the CLI to wrap sessions. It's a Node workspace (Node 22.5+ for `node:sqlite`).

```sh
git clone https://github.com/ilwonyoon/steer_ai.git
cd steer_ai
npm install
```

Then:

```sh
steer claude          # wrap Claude Code
steer codex           # wrap Codex CLI
steer wrap -- node    # wrap anything else
```

## Troubleshooting

**"Steer is not signed by an identified developer."** You're on macOS < 26, or it's an old build. Grab the latest `.dmg` from Releases.

**Cards stop appearing.** If your session is under `~/Documents`, `~/Desktop`, or `~/Downloads`, macOS may need Full Disk Access. Mac Settings → Folder Access → Open Full Disk Access, add Steer.

**`steer claude --headless` hangs.** Delete the stale socket (`rm ~/.steer/steer.sock`) and rerun.

## Status

Early dogfooding. iPhone companion is in progress; today's [`v0.1.1` release](https://github.com/ilwonyoon/steer_ai/releases/tag/v0.1.1) is Mac-only. See [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md) for the active backlog.

## For contributors

Layout, workflow, and architectural decisions live in [`AGENTS.md`](AGENTS.md) and [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md).

```text
apps/mac/             # SwiftUI macOS shell (SwiftPM, macOS 26+)
apps/ios/             # SwiftUI iOS shell (in progress)
packages/agent/       # Node SteerAgent: socket server, SQLite, classifier
packages/cli/         # Node `steer` CLI: wrapper + provider adapters
packages/relay/       # Cloudflare Workers relay (for the iOS companion)
packages/SteerCore/   # Cross-platform Swift types
docs/                 # PRD, TECH_SPEC, classifier + regression contracts
scripts/              # build-mac-app.sh, release-mac.sh, verify-steer-regression.sh
```

Run tests:

```sh
npm test                                       # Node side
swift test --package-path packages/SteerCore   # Cross-platform helpers
swift build --package-path apps/mac            # Mac compile gate
```

Build local + release:

```sh
scripts/build-mac-app.sh         # Ad-hoc-signed dogfood build
scripts/release-mac.sh           # Developer ID + notarytool required
```
