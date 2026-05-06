# Classifier Contract

Steer classification turns recent session output into one action card at most. The classifier must favor precision: if output is not clearly asking for user action, it should return a silent/done card rather than an active card.

## Input

```json
{
  "session": {
    "id": "codex-...",
    "provider": "codex",
    "command": "codex",
    "cwd": "/Users/name/project",
    "runState": "running"
  },
  "entries": [
    {
      "stream": "stdout",
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

- `blocker`: error, failed command, permission/approval issue, disconnected session, or explicit blocked state. Active, usually urgent.
- `decision`: explicit choice, option set, confirmation request, or architectural/product decision. Active.
- `question`: direct question or request for input. Active.
- `completion`: completed work or successful result. Done/silent unless notifications later opt in.
- `progress`: non-actionable running output. Done/silent.
- `answered`: latest user instruction has been delivered and no newer actionable AI output exists. Done/silent.

## Filtering Rules

The classifier must not treat terminal chrome as actionable content. Filter provider startup boilerplate, prompt/status lines, user echo, Steer ack lines, cursor repaint artifacts, and setup warnings that do not require a product decision.

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
- When a user reply is injected, the current active card is resolved.
- After a reply, old pre-reply questions must not resurrect. Classification should inspect AI output after the latest user instruction.
- Active cards should only appear for `blocker`, `decision`, or `question`.
