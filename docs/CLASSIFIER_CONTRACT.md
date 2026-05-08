# Classifier Contract

Steer classification turns recent session output into one action card at most. The classifier must favor precision: if output is not clearly asking for user action, it should return a silent/done card rather than an active card.

## Input

```json
{
  "session": {
    "id": "codex-...",
    "provider": "codex",
    "adapterKind": "codex-app-server",
    "command": "codex",
    "cwd": "/Users/name/project",
    "runState": "running"
  },
  "entries": [
    {
      "stream": "report",
      "timestamp": "2026-05-06T23:00:00.000Z",
      "chunk": "Need answer?\\n"
    }
  ],
  "recentUserInstruction": "optional latest user text"
}
```

## Output

```json
{
  "requiresAction": true,
  "needsInput": true,
  "category": "question",
  "priority": "normal",
  "cardTitle": "Codex CLI · codex has a question",
  "summary": "Need answer?",
  "terminalExcerpt": ["Need answer?"],
  "highlightedLineIndexes": [0],
  "actionPrompt": "Answer the question or give a direct next instruction.",
  "options": ["Yes, continue", "Use your judgment", "Explain first"],
  "state": "active"
}
```

## Categories

- `blocker`: error, failed command, permission/approval issue, or explicit blocked state. Active, usually urgent.
- `disconnected`: wrapper socket is gone. Done/silent because the user cannot inject an instruction into that session.
- `decision`: explicit choice, option set, confirmation request, or architectural/product decision. Active.
- `question`: direct question or request for input. Active.
- `waiting`: the provider stopped and returned control to the user. Active by default, even when the text looks like completion or progress, because the user must decide the next instruction.
- `completion`: completed work or successful result while the session is not waiting. Done/silent unless notifications later opt in.
- `progress`: non-actionable running output. Done/silent.
- `answered`: latest user instruction has been delivered and no newer actionable AI output exists. Done/silent.

## Filtering Rules

The classifier must not treat terminal chrome as actionable content. Filter provider startup boilerplate, prompt/status lines, user echo, Steer ack lines, cursor repaint artifacts, and setup warnings that do not require a product decision.

Interactive PTY output (`stream = pty`) is not an authoritative action source. It may be stored for debugging and terminal mirroring, but active cards should come from provider-native reports (`stream = report`) or semantic provider streams such as headless stdout/stderr. If a PTY session has no trusted report after the latest user instruction, the classifier should prefer a silent/done card over guessing from TUI repaint bytes.

Examples to filter:

- `Tip: Try the Codex App...`
- `Under-development features enabled...`
- `MCP startup incomplete (failed: pencil)`
- `gpt-5.5 high fast · ~/project`
- `› user prompt echo`
- `[user] ...`
- `[steer] instruction ... injected`

## Lifecycle Rules

- Only one active card per session.
- **Terminal-running invariant**: while the user is interacting with the wrapped terminal directly, no card is shown. Cards only surface when the AI is stopped (`waiting`/`blocked`) OR the session has just been registered with no traffic yet. This is enforced at the Mac SQL fetch gate, not by mutating the card row, so the same card naturally re-appears once the AI returns to a stopped state.
- After a reply, old pre-reply questions must not resurrect. Classification should inspect AI output after the latest user instruction.
- Active cards should only appear for `blocker`, `decision`, `question`, or `waiting`.
- A freshly registered session (`run_state="running"`, no traffic in `report/stdout/stderr/pty/user`) surfaces a `waiting` "ready" card with a canned summary so the user sees something to act on right away. The card's body must NOT be sourced from raw PTY (no leaking "Need answer?" etc.). Once any traffic arrives the card is hidden by the gate; if the user cancels (Esc / Ctrl-C) before sending, the wrapper sends `state=waiting` to restore visibility.
- Wrapper stdin contract: first keystroke after a stopped state → `state=running`. Esc (`0x1B`) or Ctrl-C (`0x03`) → `state=waiting`. The agent no longer maintains a fake `[user] (typed in terminal)` transcript entry; visibility is decided purely from `run_state` + traffic existence.
