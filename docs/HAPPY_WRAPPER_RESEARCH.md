# Happy Wrapper Research

Date: 2026-05-06

Source: `slopus/happy` shallow clone inspected locally from GitHub.

## Summary

Happy is useful as a reference, but the current codebase is not simply a `node-pty` wrapper around Claude/Codex. It uses provider-specific control paths:

- Claude: `@anthropic-ai/claude-agent-sdk`, hook settings, session scanners, and mode switching between local and remote.
- Codex: `codex app-server` JSON-RPC over stdio, with explicit approval and event handling.
- Daemon: local Fastify HTTP control server on `127.0.0.1` plus cloud sync and encrypted session protocol.

For Steer, the key lesson is: use the most stable provider-native control channel where available, and keep raw pty as a fallback for providers without a structured protocol.

## Files Worth Studying

- `packages/happy-cli/src/index.ts`: CLI routing for `happy claude`, `happy codex`, `gemini`, daemon commands, and auth.
- `packages/happy-cli/src/claude/runClaude.ts`: Claude session creation, metadata, hook server, Happy MCP server, and daemon reporting.
- `packages/happy-cli/src/claude/loop.ts`: local/remote mode loop.
- `packages/happy-cli/src/claude/claudeLocal.ts`: local Claude launch, hook settings, session id handling, thinking detection via fd 3.
- `packages/happy-cli/src/claude/claudeRemote.ts`: Claude Agent SDK query loop and user message queue.
- `packages/happy-cli/src/codex/runCodex.ts`: Codex session loop, message queue, event mapping, and permission handling.
- `packages/happy-cli/src/codex/codexAppServerClient.ts`: Codex JSON-RPC app-server client.
- `packages/happy-cli/src/daemon/controlServer.ts`: local daemon control surface.
- `packages/happy-cli/src/utils/MessageQueue2.ts`: mode-aware message batching and queue semantics.
- `docs/session-protocol.md`: provider-agnostic event stream.
- `docs/cli-architecture.md`: overall Happy CLI and daemon architecture.

## What Steer Should Borrow

- Provider adapter boundary: Claude, Codex, Gemini should not leak into the app UI.
- Session state and lifecycle metadata.
- Message queue semantics: queue user instructions and deliver them only when the backend can accept input.
- Codex app-server approach for structured events and approvals.
- Claude Agent SDK approach for structured Claude control, if it satisfies Steer's report/instruct loop.
- Hook/session scanner ideas for session identity and transcript correlation.
- Local control process pattern, but tighten it for local-first Steer.

## What Steer Should Not Borrow Wholesale

- Happy's product architecture: it is a full remote-control/mirror product, while Steer is an AI operations room.
- Cloud-first sync requirements for v1.
- Expo/mobile/web app structure for the Mac-first prototype.
- Server-centric encrypted session protocol as the v1 source of truth.
- Local HTTP control server as-is. Steer should prefer Unix domain socket or XPC for local-only IPC.
- Local/remote mode switching as the primary UX. Steer should keep a steady control-room loop.

## Architecture Implication

The old phrasing "wrapper-owned pty" is directionally right because Steer needs bidirectional control, but it is too narrow.

Better model:

```text
Provider Control Adapter
  - Claude: Agent SDK + hooks/session scanner if viable
  - Codex: codex app-server JSON-RPC
  - Gemini/other: provider protocol if available, pty fallback otherwise
```

The invariant is not "must use pty"; the invariant is "Steer must own a reliable bidirectional control channel for each session."

## Open Follow-Ups

- Verify Claude Agent SDK can support Steer's proactive instruction flow without restarting local sessions.
- Verify Codex app-server availability and version requirements on the target machine.
- Decide whether `steer claude` should start in SDK-controlled mode immediately or offer a terminal-local mode.
- Define a common `ProviderSessionAdapter` interface before writing the first wrapper.
- Revisit Tech Spec language to say "control adapter" instead of only "pty wrapper."
