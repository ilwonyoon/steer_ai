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
node packages/agent/src/agent.js
node packages/cli/src/index.js wrap -- node -i
node packages/cli/src/index.js sessions
node packages/cli/src/index.js send <sessionId> "console.log('steer injection ok')"
```

Claude Code is the first real provider target:

```sh
node packages/cli/src/index.js claude --max-budget-usd 0.02
node packages/cli/src/index.js send <sessionId> "Reply exactly STEER_CLAUDE_OK and nothing else."
```

See `docs/WRAPPER_SPIKE.md` for scope and limitations.

See `EXECUTION_PLAN.md` for the current backlog and implementation phases.
