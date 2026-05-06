# Steer Execution Plan

Last updated: 2026-05-06

## Purpose

This is the master execution document for Steer. Use it to track what we are building, why the current architecture exists, what is in scope for each phase, and which decisions have already been made.

Steer is a macOS-first AI operations room for CLI coding agents. The core loop is simple: capture reports from multiple AI CLI sessions, show them in a DM-like room interface, and inject user replies or proactive instructions back into the correct session so work does not stall.

## Source Documents

- `DESIGN.md`: visual system and interaction direction.
- `AGENTS.md`: contributor and agent workflow guide.
- Backtick Memory `Steer / prd`: product requirements and positioning.
- Backtick Memory `Steer / tech-spec`: technical architecture and implementation notes.

Keep this document focused on execution. Durable product or architecture changes should also be reflected in the source documents above.

## Current Product Decisions

- Steer is an AI operations room, not a full chat mirror.
- The default UX is a unified room, but users may later create multiple rooms.
- Room membership and session invitation/routing are follow-up specs.
- v1 is Mac-first and local-first.
- The core loop requires bidirectional control: report capture plus instruction injection.
- Hook-only mode is not sufficient for the product. It can only be a read-only fallback.
- Happy is a reference implementation and possible source for wrapper/pty learnings, not the product architecture to fork wholesale.
- Design direction: Instagram DM for messaging ergonomics, Telegram for multi-room flexibility, Linear for technical status and metadata.

## Target v1 Architecture

```text
Steer.app
  - SwiftUI/AppKit shell
  - Menu bar and room UI
  - Notifications
  - Local API client

SteerAgent
  - Per-user background agent / Login Item
  - Session registry
  - SQLite single writer
  - Message and instruction store
  - Classification orchestration
  - Instruction delivery queue

steer CLI wrapper
  - User launches: steer claude / steer codex
  - Owns child process pty
  - Streams transcript and state to SteerAgent
  - Injects pending instructions into target stdin
```

Prototype may use TypeScript/Node for the wrapper and agent to move quickly. Production should evaluate a signed Swift or Rust `SteerAgent`, XPC for app-to-agent communication, and a minimal signed wrapper.

## Execution Phases

### Phase 0: Repository Foundation

Goal: make the repository useful for future implementation.

- [x] Create `DESIGN.md`.
- [x] Create `AGENTS.md`.
- [x] Push initial docs to GitHub.
- [x] Add `README.md` with product summary and local setup notes.
- [x] Add `docs/` directory for PRD, tech spec exports, and research notes.
- [x] Decide initial source layout: `apps/mac`, `packages/agent`, `packages/cli`, `docs`.

### Phase 1: Wrapper Spike

Goal: prove we can own a CLI session and safely inject input.

- [x] Study current `slopus/happy` wrapper/session code.
- [ ] Build minimal `steer claude` wrapper.
- [ ] Build minimal `steer codex` wrapper.
- [ ] Capture stdout/stderr transcript chunks.
- [ ] Detect prompt-ready / waiting states.
- [ ] Inject single-line instruction only when prompt-ready.
- [ ] Test multiline injection behavior.
- [ ] Document failure cases and edge cases.

Exit criteria:
- A wrapped Claude or Codex session can receive an instruction from another local process.
- Injection does not corrupt output during normal waiting states.

### Phase 2: Local Agent And Storage

Goal: centralize session state, messages, and instruction delivery.

- [ ] Define SQLite schema for `Room`, `Session`, `Message`, `Instruction`, and `MetricEvent`.
- [ ] Implement `SteerAgent` as the single writer.
- [ ] Add Unix domain socket or local IPC API.
- [ ] Stream wrapper events into the agent.
- [ ] Persist session state transitions.
- [ ] Persist pending/injected/failed instruction status.
- [ ] Add crash/reconnect behavior for wrapper processes.

Exit criteria:
- Multiple wrapped sessions can stream into one local store.
- Instructions are queued, delivered, and status-tracked.

### Phase 3: Mac App Prototype

Goal: make the core loop usable from a native Mac UI.

- [ ] Create SwiftUI macOS app shell.
- [ ] Add menu bar status item.
- [ ] Build default unified room view.
- [ ] Show session badges and state pills.
- [ ] Render report, decision, blocker, completion, and idle messages.
- [ ] Add quick reply / quick instruction chips.
- [ ] Add composer with target session selection.
- [ ] Add macOS notifications for waiting/blocker states.

Exit criteria:
- User can monitor multiple sessions and send a reply/instruction from the Mac UI.

### Phase 4: Classification And Triage

Goal: make reports actionable without becoming noisy.

- [ ] Define classifier JSON contract.
- [ ] Add categories: `progress`, `completion`, `decision`, `blocker`, `question`, `idle`.
- [ ] Add `requiresAction`, `needsInput`, `priority`, `summary`, `options`, `suggestedInstructions`.
- [ ] Run classifier against real transcript samples.
- [ ] Track false positive and false negative notifications.
- [ ] Tune prompts for high precision on `requiresAction`.

Exit criteria:
- Classifier reliably separates silent progress from user-action-needed items.

### Phase 5: Dogfooding

Goal: prove Steer reduces operational latency.

- [ ] Use Steer for real coding sessions for one week.
- [ ] Track average answer latency.
- [ ] Track average instruction latency.
- [ ] Track waiting/block duration.
- [ ] Track quick action usage.
- [ ] Track session continuation after intervention.
- [ ] Write dogfooding findings and next-phase decision.

Exit criteria:
- Clear evidence that Steer helps keep multiple AI sessions moving.

## Current Backlog

- [x] Create `README.md`.
- [x] Export Backtick PRD and Tech Spec into `docs/`.
- [x] Write Happy wrapper research note.
- [ ] Choose prototype stack: Node agent first vs Swift/Rust agent first.
- [ ] Define v1 SQLite schema.
- [ ] Define local IPC protocol.
- [ ] Create first wrapper spike.
- [ ] Create Mac app skeleton.

## Decision Log

### 2026-05-06: Product Framing

Steer is framed as an AI operations room, not just a decision triage tool. The user should be able to receive reports, answer questions, and proactively instruct sessions.

### 2026-05-06: Room Model

The default room is unified, but the system should allow multiple rooms later. Session invitation and room routing are follow-up specs.

### 2026-05-06: Wrapper Required

Hook-only mode cannot satisfy the product loop because it does not own stdin. v1 requires wrapper-owned pty for bidirectional control.

### 2026-05-06: Happy Strategy

Happy should be studied and possibly used for wrapper learnings or minimal vendored code. Steer should not become a wholesale Happy fork because the product model is different.

### 2026-05-06: Provider Control Adapter Strategy

Happy research showed that current Happy is not simply a raw pty wrapper. Claude uses Agent SDK/hooks/session scanning, and Codex uses `codex app-server` JSON-RPC. Steer should define provider control adapters and use provider-native control channels where stable, with raw pty as fallback.

### 2026-05-06: macOS Strategy

v1 should be a notarized direct-distribution Mac app, not App Store-first. Avoid Accessibility/Input Monitoring by owning the pty through the wrapper.

## Open Questions

- Should the prototype agent be TypeScript/Node for speed or Swift/Rust for production shape?
- Should app-to-agent communication start with Unix domain sockets or XPC?
- Should Claude v1 use Agent SDK control first, or raw pty first?
- Should Codex v1 use `codex app-server` only, with pty fallback later?
- How should prompt-ready detection work for Claude Code and Codex?
- What is the minimum safe injection policy for multiline instructions?
- How much transcript should be stored locally by default?
- When should iOS sync begin: after Mac dogfooding or earlier?

## Operating Rules

- Do not add App Store sandbox constraints to v1 unless explicitly chosen.
- Do not require Accessibility permissions for core input injection.
- Do not attach to arbitrary existing terminal sessions in v1.
- Do not send raw transcripts to any remote service without an explicit user-controlled setting.
- Keep UI message-first. Avoid turning the first version into a terminal dashboard.
- Keep wrapper, agent, and app responsibilities separate.

## Progress Notes

Use this format for future updates:

```md
### YYYY-MM-DD

Completed:
- ...

Learned:
- ...

Next:
- ...

Risks:
- ...
```

### 2026-05-06

Completed:
- Created initial GitHub repository.
- Added `DESIGN.md`.
- Added `AGENTS.md`.
- Added this execution plan.
- Added `README.md`.
- Exported PRD and Tech Spec into `docs/`.
- Created initial source layout placeholders: `apps/mac`, `packages/agent`, `packages/cli`.

Learned:
- The original `Documents/Steer_ai` folder had macOS privacy restrictions that blocked normal git operations.
- A working clone now exists at `/Users/ilwonyoon/Developer/steer_ai`.

Next:
- Start Happy wrapper research.
- Decide prototype stack, IPC approach, and first provider adapter target.
