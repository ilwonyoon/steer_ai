# Wrapper Spike

Date: 2026-05-06

## Goal

Prove Steer can own a local command session, capture its transcript, and inject a user instruction from another local process.

This is a minimal control-loop spike, not the final Claude/Codex adapter.

## Commands

Start the local agent:

```sh
node packages/agent/src/agent.js
```

Wrap any command:

```sh
node packages/cli/src/index.js wrap -- node -i
```

List sessions:

```sh
node packages/cli/src/index.js sessions
```

Inject one instruction:

```sh
node packages/cli/src/index.js send <sessionId> "console.log('steer injection ok')"
```

Provider shims exist for the next smoke tests:

```sh
node packages/cli/src/index.js claude
node packages/cli/src/index.js codex
```

## What Works

- `SteerAgent` listens on a Unix domain socket at `~/.steer/steer.sock`.
- A wrapper registers a session with provider, command, cwd, pid, and run state.
- stdout/stderr are streamed to the terminal and appended to `~/.steer/sessions/<sessionId>.log`.
- `steer send <sessionId> <instruction>` routes text to the active wrapper.
- The wrapper writes the instruction to child stdin with a trailing newline.
- The wrapper reports injected status and exit state back to the agent.

Smoke test result:

```text
steer send -> wrapped node -i -> console.log('steer injection ok')
```

The wrapped REPL printed `steer injection ok`, confirming the bidirectional local loop.

## Known Limits

- This spike uses child stdin/stdout pipes, not a pty.
- Some interactive CLIs, including AI coding tools, may require TTY behavior.
- No prompt-ready detection yet; instructions are sent immediately.
- No SQLite persistence yet; session registry is in memory, transcript logs are file-backed.
- No multiline injection policy yet.
- No provider-native Claude Agent SDK or Codex app-server integration yet.

## Next

1. Decide first real provider target: Codex app-server first or Claude SDK first.
2. Add prompt-ready/waiting detection for the chosen target.
3. Add pty fallback only if provider-native control is not enough.
4. Move session/message/instruction persistence into SQLite.
