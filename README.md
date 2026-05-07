# Steer

Steer is a macOS-first action queue for CLI coding agents.

The goal is to keep multiple AI coding sessions moving: capture reports from Claude Code, Codex, and other CLI agents; surface stuck or waiting sessions as a fast card stack; and inject user replies or proactive instructions back into the correct session.

## Current Status

This repository is in the planning and early execution stage. It contains product, technical, design, and contributor guidance documents plus an initial SwiftUI Mac app shell and static UX prototype.

## Core Documents

- `EXECUTION_PLAN.md`: master execution plan, task board, decision log, and progress notes.
- `DESIGN.md`: product design system and interaction direction.
- `AGENTS.md`: contributor and agent workflow guide.
- `docs/PRD.md`: product requirements export.
- `docs/TECH_SPEC.md`: technical specification export.
- `docs/HAPPY_WRAPPER_RESEARCH.md`: notes from studying Happy's current provider-control architecture.

## Product Direction

Steer is not a full chat mirror. It is an AI action queue:

- Waiting, blocked, decision, completion, and idle states appear as prioritized cards.
- Each card shows where the CLI session came from, such as Claude Code, Codex CLI, or Gemini CLI.
- Opening a card shows full Claude/Codex-style session context and transcript.
- Users answer through an input field with suggested chips directly above it.
- The system tracks session states such as `running`, `waiting`, `blocked`, `idle`, and `done`.
- The design uses a Tinder-style stack for one-at-a-time triage, iOS-native Liquid Glass reply surfaces, Claude/Codex-style detail for context, Instagram DM-like reply lightness, and Linear-style technical status clarity.

## Technical Direction

The v1 core loop requires bidirectional control:

```text
steer CLI wrapper -> SteerAgent -> Steer.app
       ^                 |
       |                 v
  instruction injection <- user reply / instruction
```

Hook-only mode is not sufficient because it cannot deliver user instructions. v1 requires a Steer-owned bidirectional control channel. Use provider-native control where stable, such as Claude Agent SDK or Codex app-server, and keep raw pty as a fallback.

## Development

The first clickable UX preview is a static prototype:

```text
apps/prototype/index.html
```

The first native Mac shell is a Swift Package:

```sh
cd apps/mac
swift build
swift run SteerMac
```

For notification testing, run the bundled app build instead of the raw SwiftPM executable:

```sh
./scripts/build-mac-app.sh
open .build/SteerMac.app
```

The Mac app reads live action cards from `~/.steer/steer.sqlite` and sends replies through `steer send`. The current card generator is heuristic: it watches transcript tails for blockers, questions, decisions, completions, and progress.

Current structure:

```text
apps/mac/
apps/prototype/
packages/agent/
packages/cli/
docs/
```

The first wrapper/control-loop spike is Node-based:

```sh
steer wrap -- node -i
steer sessions
steer send <sessionId> "console.log('steer injection ok')"
```

The CLI auto-starts `SteerAgent` in the background when needed. Use `steer agent` only when you want to run the agent manually for debugging.

The agent writes local state to `~/.steer/steer.sqlite` and transcript logs to `~/.steer/sessions/`. Set `STEER_HOME` for isolated local tests.

Claude Code can run in the normal interactive terminal wrapper:

```sh
steer claude
steer send <sessionId> "your instruction"
```

The Claude headless stream-json adapter remains available for controlled smoke tests:

```sh
steer claude --headless --max-budget-usd 0.02
steer send <sessionId> "Reply exactly STEER_CLAUDE_OK and nothing else."
```

Codex can also run in the normal interactive terminal wrapper:

```sh
steer codex
steer send <sessionId> "your instruction"
```

The Codex provider-native app-server adapter remains available in headless mode:

```sh
steer codex --headless
steer send <sessionId> "Reply exactly STEER_CODEX_OK and nothing else."
```

See `docs/WRAPPER_SPIKE.md` for scope and limitations.

See `EXECUTION_PLAN.md` for the current backlog and implementation phases.
