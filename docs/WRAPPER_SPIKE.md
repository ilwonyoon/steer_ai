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
node packages/cli/src/index.js claude --raw
node packages/cli/src/index.js codex
```

`steer claude` uses Claude Code's headless stream-json path by default:

```sh
claude -p --input-format stream-json --output-format stream-json --replay-user-messages
```

Use `steer claude --raw` only as the generic stdin/stdout fallback.

## What Works

- `SteerAgent` listens on a Unix domain socket at `~/.steer/steer.sock`.
- A wrapper registers a session with provider, command, cwd, pid, and run state.
- stdout/stderr are streamed to the terminal and appended to `~/.steer/sessions/<sessionId>.log`.
- `steer send <sessionId> <instruction>` routes text to the active wrapper.
- The wrapper writes the instruction to child stdin with a trailing newline.
- The wrapper reports injected status and exit state back to the agent.
- `steer claude` starts Claude Code through stream-json headless mode and sends user messages as JSON lines.
- Claude adapter marks the session `running` when an instruction is injected and `waiting` when Claude emits a `result`.

Smoke test result:

```text
steer send -> wrapped node -i -> console.log('steer injection ok')
```

The wrapped REPL printed `steer injection ok`, confirming the bidirectional local loop.

Claude smoke test result:

```text
steer claude --max-budget-usd 0.02
steer send <sessionId> "Reply exactly STEER_CLAUDE_OK and nothing else."
```

Claude Code returned `STEER_CLAUDE_OK`, confirming the stream-json adapter can receive a Steer instruction and return output.

## Known Limits

- This spike uses child stdin/stdout pipes, not a pty.
- Some interactive CLIs, including AI coding tools, may require TTY behavior.
- No prompt-ready detection yet; instructions are sent immediately.
- No SQLite persistence yet; session registry is in memory, transcript logs are file-backed.
- No multiline injection policy yet.
- Claude uses CLI headless stream-json, not the TypeScript SDK package yet.
- No Codex app-server integration yet.

## Next

1. Smoke test Claude stream-json with a low-cost prompt.
2. Add prompt-ready/waiting detection for Claude stream-json events.
3. Add pty fallback only if provider-native control is not enough.
4. Move session/message/instruction persistence into SQLite.
