# Steer

Steer is a macOS-first AI operations room for CLI coding agents.

The goal is to keep multiple AI coding sessions moving: capture reports from Claude Code, Codex, and other CLI agents; show them in a lightweight DM-like room interface; and inject user replies or proactive instructions back into the correct session.

## Current Status

This repository is in the planning and early execution stage. It currently contains product, technical, design, and contributor guidance documents. Implementation has not started yet.

## Core Documents

- `EXECUTION_PLAN.md`: master execution plan, task board, decision log, and progress notes.
- `DESIGN.md`: product design system and interaction direction.
- `AGENTS.md`: contributor and agent workflow guide.
- `docs/PRD.md`: product requirements export.
- `docs/TECH_SPEC.md`: technical specification export.
- `docs/HAPPY_WRAPPER_RESEARCH.md`: notes from studying Happy's current provider-control architecture.

## Product Direction

Steer is not a full chat mirror. It is an AI operations room:

- Reports from multiple CLI sessions appear in one default room.
- Users can answer questions or send proactive instructions.
- The system tracks session states such as `running`, `waiting`, `blocked`, `idle`, and `done`.
- The design borrows messaging ergonomics from Instagram DM, multi-room flexibility from Telegram, and technical status clarity from Linear.

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

No build system is committed yet. Do not invent local commands until the implementation stack is chosen.

Expected future structure:

```text
apps/mac/
packages/agent/
packages/cli/
docs/
```

See `EXECUTION_PLAN.md` for the current backlog and implementation phases.
