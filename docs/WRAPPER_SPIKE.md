# Wrapper Spike

Date: 2026-05-06

## Goal

Prove Steer can own a local command session, capture its transcript, and inject a user instruction from another local process.

This is a minimal control-loop spike, not the final Claude/Codex adapter.

## Commands

The CLI auto-starts the local agent when needed. To run it manually for debugging:

```sh
node packages/agent/src/agent.js
```

Wrap any command:

```sh
steer wrap -- node -i
```

List sessions:

```sh
steer sessions
```

Inject one instruction:

```sh
steer send <sessionId> "console.log('steer injection ok')"
```

Provider shims exist for the next smoke tests:

```sh
steer claude
steer claude --raw
steer codex --headless
```

`steer claude` uses the interactive PTY bridge by default. The previous Claude Code headless stream-json path is still available:

```sh
steer claude --headless
```

Use `steer claude --raw` only as the generic stdin/stdout fallback.

## What Works

- `SteerAgent` listens on a Unix domain socket at `~/.steer/steer.sock`.
- A wrapper registers a session with provider, command, cwd, pid, and run state.
- stdout/stderr are streamed to the terminal and appended to `~/.steer/sessions/<sessionId>.log`.
- `steer send <sessionId> <instruction>` routes text to the active wrapper.
- The PTY wrapper writes the instruction text, then sends a submit key. For Claude/Codex multiline text, it uses bracketed paste before submit so embedded newlines do not execute partial prompts.
- The wrapper reports injected status and exit state back to the agent.
- `steer claude` and `steer codex` start provider CLIs through a PTY bridge so they look like normal terminal sessions.
- `steer claude --headless` starts Claude Code through stream-json headless mode and sends user messages as JSON lines.
- Claude adapter marks the session `running` when an instruction is injected and `waiting` when Claude emits a `result`.

Smoke test result:

```text
steer send -> wrapped node -i -> console.log('steer injection ok')
```

The wrapped REPL printed `steer injection ok`, confirming the bidirectional local loop.

Claude smoke test result:

```text
steer claude --headless --max-budget-usd 0.02
steer send <sessionId> "Reply exactly STEER_CLAUDE_OK and nothing else."
```

Claude Code returned `STEER_CLAUDE_OK`, confirming the stream-json adapter can receive a Steer instruction and return output.

Codex smoke test result:

```text
steer codex --headless
steer send <sessionId> "Reply exactly STEER_CODEX_WAIT_OK and nothing else."
```

Codex returned `STEER_CODEX_WAIT_OK` through `codex app-server` JSON-RPC. The headless adapter starts a thread, sends instructions through `turn/start`, streams `item/agentMessage/delta`, and marks the session `waiting` after `turn/completed`.

Interactive PTY multiline smoke:

```text
steer codex
steer send <sessionId> $'Spell the count of non-empty lines below in English lowercase. Answer with only that word.\napple\nbanana'
```

Codex returned `two`, proving multiline text can be pasted into the interactive TUI and submitted as one prompt.

## Failure Cases And Edge Cases

- Provider TUIs can repaint prompts/status lines into stdout. Card extraction must filter prompt chrome, status lines, and setup warnings before classification.
- Codex startup can emit prompt-looking lines before MCP startup finishes. The PTY wrapper queues pending instructions until Codex reports MCP startup complete/incomplete, with a timeout fallback.
- Multiline PTY input must not be written as raw newline-separated keystrokes for Claude/Codex. Use bracketed paste plus a final submit key.
- Generic `steer wrap -- <command>` cannot assume bracketed paste support, so it preserves raw multiline text.
- If the agent process restarts, existing wrapper sockets are not durable yet. Active terminal sessions may keep running, but Steer delivery requires launching a new wrapped session.
- Provider-native headless adapters avoid terminal repaint noise but still need approval/interruption handling.

## Known Limits

- The generic `steer wrap -- <command>` path now uses the PTY bridge, but resize handling is still basic.
- `--raw` provider paths still use child stdin/stdout pipes and are only fallback/debug modes.
- Active sockets are still in memory, but durable session, message, instruction, transcript, and metric rows are persisted in SQLite.
- Claude headless uses CLI stream-json, not the TypeScript SDK package yet.
- Codex headless uses app-server, but same-turn steering and approval flows need real dogfood testing.

## Next

1. Add prompt-ready/waiting detection hardening for Claude and Codex.
2. Add provider-native approval/request handling for Codex app-server events.
3. Add transcript excerpt extraction and classifier-generated action card rows.
4. Replace the Python PTY bridge with a packaged Swift/Rust helper if dogfooding shows bridge limits.
