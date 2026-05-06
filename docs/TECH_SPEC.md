# Tech Spec: Steer

> **Goal**: Mac 앱이 여러 AI CLI 세션의 output을 보고로 캡처하고, 사용자의 답변/지시를 정확한 target session에 주입한다. v1은 Mac 단독으로 bidirectional report/instruct loop를 검증하고, v2에 iOS 동기화를 추가한다.

## High-Level Architecture

```text
[Mac]
  Claude/Codex/Gemini sessions (spawned through Steer wrapper/control adapter)
       ↓ stdout/stderr + state signals
  Steer Control Adapters
    - provider-native control when available
    - pty fallback when needed
    - transcript capture
    - stdin injection
    - session heartbeat/status
       ↓ SQLite / local socket
  SteerAgent
    - session registry
    - room/message/instruction store
    - stop/waiting/block detection
    - report/decision/blocker/completion classification
    - terminal tail extraction for actionable cards
    - quick reply / quick instruction generation
    - pending instruction delivery to target session
       ↓
  Steer Mac App
    - prioritized action card stack
    - terminal-tail action cards
    - Claude/Codex-style session detail
    - Linear-style session status
    - quick reply chips above input
    - proactive detail composer with target routing
    - notifications
```

v1의 core loop는 bidirectional이다: provider output을 보고로 캡처하고, 사용자 답변/지시를 같은 target session에 주입한다. Hook-only는 이 core loop를 만족하지 못하므로 read-only reporting fallback일 뿐이다.

## v1 Core Decisions

### Control Adapter vs Hook

Steer의 core loop는 보고 받기 + 지시하기다. Hook은 output/event 감지에는 유용하지만, 사용자의 답변/지시를 해당 session에 안정적으로 주입하는 bidirectional channel이 아니다. 따라서 v1은 Steer-owned bidirectional control channel이 필수다.

사용자는 `claude` 대신 `steer claude`, `codex` 대신 `steer codex` 같은 명령어를 실행한다. Steer control adapter가 provider process/protocol을 시작하고, report stream과 instruction delivery를 소유한다.

Happy는 provider control reference로 연구하되, Steer의 product architecture를 통째로 fork하지 않는다. 최신 Happy는 Claude에 Agent SDK/hook/session scanner를, Codex에 `codex app-server` JSON-RPC를 사용한다. Steer도 raw pty만 고집하지 않고 provider-native protocol을 우선 검토한다.

### Queue And Room Model

v1은 기본 action queue를 제공한다. 사용자는 모든 session 중 `requiresAction`, `waiting`, `blocked`, `decision`, `question`, `completion`, `idle` 상태를 우선순위 카드로 본다.

room은 후속 확장 포인트로 모델에 포함하되, v1 UI에서는 기본 queue + session filter만 구현해도 된다. 사용자가 원하면 나중에 여러 room을 만들고 어떤 CLI session을 어떤 room에 포함할지 결정할 수 있다.

### Synchronization

**v1: 로컬만.** App ↔ Agent는 Unix domain socket, local IPC, 또는 XPC. 데이터는 SQLite. wrapper process들은 공통 SQLite에 직접 쓰기보다 agent API를 통해 단일 write path를 사용하는 것이 안전하다.

**v2: CloudKit 또는 Supabase.** iOS 동기화와 push 알림이 검증된 뒤 도입한다.

## Data Model

**Room**: id, name, createdAt, updatedAt, sortOrder, isDefault, notificationPolicy.

**Session**: id, agent (`claude`/`codex`/`gemini`), cwd, projectName, displayName, startedAt, endedAt, runState (`running`/`waiting`/`blocked`/`idle`/`done`/`ended`), pid, wrapperProcessId, lastActivityAt, currentRoomId.

**RoomSession**: roomId, sessionId, joinedAt, muted, pinned. v1은 default room에 모든 session을 자동 포함해도 된다.

**Provider**: id (`claude`/`codex`/`gemini`/custom), displayName, iconAssetName nullable, adapterKind, supportedCapabilities.

**Message**: id, roomId, sessionId, timestamp, direction (`agent_to_user`/`user_to_agent`/`system`), rawContent, displayContent, summary, category, priority, requiresAction, needsInput, options, suggestedInstructions, replyToMessageId, answeredAt, source.

**Instruction**: id, roomId, targetSessionId, sourceMessageId nullable, text, isQuickReply, status (`pending`/`injecting`/`injected`/`failed`), createdAt, injectedAt, failureReason.

**TerminalExcerpt**: id, sessionId, sourceMessageId, startOffset nullable, endOffset nullable, rawText, displayLines, highlightedLineIndexes, createdAt. Stores the last actionable CLI block used by an action card.

**ActionCard**: derived view over `Message`/`Session`/`TerminalExcerpt`, id, sourceMessageId, sessionId, terminalExcerptId nullable, category, priority, title, summary, actionPrompt, options, state (`active`/`skipped`/`snoozed`/`done`/`answered`), createdAt, snoozedUntil nullable.

**MetricEvent**: id, sessionId, roomId, type, timestamp, metadataJson.

## Components

### Steer Control Adapters

- CLI wrapper mode: `steer claude [args]`, `steer codex [args]`.
- Claude adapter: evaluate Agent SDK + hooks/session scanner before raw pty.
- Codex adapter: evaluate `codex app-server` JSON-RPC before raw pty.
- Fallback adapter: use pty ownership when no provider-native protocol is viable.
- Streams transcript/event chunks and heartbeat/state to SteerAgent.
- Receives delivery commands and injects/sends `Instruction` to the target session.
- Updates session state on child/protocol exit.

### SteerAgent

- Per-user background agent / Login Item.
- Manages session registry, local store, classifier orchestration, notification policy, and instruction delivery.
- Owns SQLite writes.
- Provides local API to wrapper and Mac app.
- Prototype may use TypeScript/Node; production should evaluate Swift or Rust plus XPC.

### Steer Mac App

- SwiftUI/AppKit shell.
- Menu bar status item.
- Default window size: focused mobile-width utility window, 375px wide x 812px tall.
- iOS-native visual system; use Liquid Glass APIs where available, with material fallback.
- Action card stack as the default surface.
- Card body renders a terminal tail excerpt as the primary context, with AI summary as secondary text.
- Session filter and optional room list as secondary surfaces.
- Claude/Codex-style session detail opened from a card.
- Cards for progress, completion, decision, blocker, question, and idle.
- Quick reply / quick instruction chips above the card/detail input field.
- Detail composer with target session selection or `@session` mention routing.
- Provider icons, agent badges, and Linear-style state pills.

SwiftUI implementation note: use native Liquid Glass APIs for app chrome, navigation controls, sheets, and larger floating surfaces where distortion will not affect typing. Do not apply Liquid Glass to the card reply chips or input field; keep those as minimal white pill controls to avoid stretching during card swipe.

## Classification

Classifier input: recent transcript window + session metadata + recent user instruction.

Classifier output JSON:

- `requiresAction`
- `needsInput`
- `category`: `progress`, `completion`, `decision`, `blocker`, `question`, `idle`
- `priority`: `silent`, `normal`, `urgent`
- `summary`
- `terminalExcerpt`
- `highlightedLineIndexes`
- `actionPrompt`
- `options`
- `suggestedInstructions`
- `cardTitle`

`requiresAction=false` should be the default. Precision matters more than recall for urgent notifications.

The classifier should not invent terminal output. `terminalExcerpt` must be copied or losslessly trimmed from captured transcript data. The summary can explain the excerpt, but the excerpt is the user's primary source of truth.

## Security And Privacy

- v1 is local-only.
- Do not send raw transcripts to a remote service without explicit user control.
- Treat transcripts as sensitive: they may contain secrets, paths, customer data, or local environment details.
- Avoid Accessibility/Input Monitoring by owning pty through the wrapper.
- v1 should target notarized direct distribution, not Mac App Store sandboxing.

## Key Risks

1. **Instruction injection stability**: provider protocol limits, raw pty handling, prompt focus, multiline input, interrupted generation.
2. **State detection accuracy**: false waiting/blocker states create noisy UX.
3. **Classifier quality**: bad summaries or bad quick actions reduce trust.
4. **macOS packaging**: helper registration, signing, notarization, and update flow.
5. **Scope creep**: full remote chat mirror and team collaboration are not v1.

## Week 1 Milestones

- Day 1: Happy wrapper research and wrapper/injection smoke test.
- Day 2: Minimal `steer claude` wrapper and transcript stream.
- Day 3: SQLite model and classification contract.
- Day 4: Mac app action card stack skeleton.
- Day 5: Composer, target routing, notification, and instruction delivery.
- Day 6-7: Dogfooding and metrics.
