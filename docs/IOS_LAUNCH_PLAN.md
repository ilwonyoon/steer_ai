# iPhone Launch Design And Plan

Last updated: 2026-05-10

## Current Implementation Note

This document still contains the original CloudKit launch plan for historical context. The current checked-in iOS/Mac sync implementation has pivoted to:

```text
Steer for Mac / Steer for iOS
  -> Sign in with Apple
  -> Cloudflare Workers relay
  -> D1 users/cards/instructions/sessions
  -> Durable Objects WebSocket fanout
```

For App Store privacy, Terms, account deletion, and review-submission work, use `docs/legal/` as the current source of truth. For the signed-out, demo, empty, offline, and pre-Mac-connection product experience, use `docs/IOS_PRE_CONNECTION_ONBOARDING.md`.

## Purpose

Steer의 iPhone 출시는 단순한 부가 기능이 아니라 제품의 핵심 확장이다. 사용자는 Mac 앞에 없을 때도 여러 CLI coding agent의 멈춤, 질문, 결정 요청을 확인하고 바로 답할 수 있어야 한다.

이 문서는 iPhone 출시를 위해 필요한 제품 설계, sync/control architecture, App Store review 전략, 구현 단계, 검증 항목을 정리한다.

## Core Positioning

Steer iPhone은 remote terminal app이 아니다. 포지셔닝은 다음이 맞다.

> iCloud 기반 AI action inbox for local Mac coding agents.

iPhone 앱은 Mac의 Claude/Codex CLI 세션을 직접 실행하거나 터미널을 미러링하지 않는다. Mac Steer Agent가 세션 capture와 instruction injection을 소유하고, iPhone은 action card 확인, reply 작성, delivery 상태 확인을 담당한다.

이 포지셔닝이 중요한 이유:

- App Store review에서 remote shell/terminal control처럼 보이는 리스크를 줄인다.
- iPhone 단독으로도 최근 카드, 샘플 워크스페이스, offline reply queue 같은 유틸리티를 제공할 수 있다.
- transcript 전체 동기화보다 카드 스냅샷 중심으로 privacy surface를 줄인다.

## Launch Architecture Decision

### Recommended Path

```text
Mac Steer.app / SteerAgent
  - owns local CLI wrapper sessions
  - reads local SQLite/action cards
  - writes safe card snapshots to CloudKit private DB
  - watches CloudKit instructions
  - injects instructions into local wrappers
  - updates delivery status

iPhone Steer
  - reads CloudKit card snapshots
  - receives CloudKit subscription pushes
  - shows native card stack and detail
  - writes instruction records
  - shows queued / delivered / failed status
```

Use **CloudKit private database** for v1 iPhone sync.

Why CloudKit:

- Steer is Apple-platform-first.
- User identity can be the user's Apple Account instead of a new Steer account.
- Private database is a better default for sensitive local coding context.
- CloudKit subscriptions can notify the user's devices when records change.
- Developer ID Mac apps can use advanced capabilities such as CloudKit and push notifications when correctly signed/provisioned.

Why not Supabase first:

- Requires account/auth decisions now.
- Requires RLS and server-side operational responsibility.
- Creates a larger privacy and breach surface for transcripts/code/context.
- Better fit later if Steer becomes team/cross-platform.

Why not local Mac relay first:

- Best privacy, but weak product value away from the Mac.
- Requires same network, VPN, tunneling, or custom relay.
- Does not solve push/reply-from-anywhere cleanly.

## App Store Strategy

The iPhone app must not be a blank companion that only says "install the Mac app." Apple App Review guideline 4.2.3 says an app should work on its own without requiring installation of another app to function.

Therefore, Steer iPhone needs a useful standalone mode:

- Demo workspace with sample cards and sample delivery states.
- Offline card cache from the user's last sync.
- Offline reply drafting and queued instruction records.
- Settings, privacy controls, and sync scope inspection.
- Clear "Mac online required for delivery" status.

App Store copy should avoid:

- "Control your Mac terminal from iPhone"
- "Remote shell"
- "Run commands on your Mac"
- "Full terminal mirror"

App Store copy should emphasize:

- "Review AI coding agent action cards"
- "Reply to waiting coding sessions"
- "Keep local Mac agents moving"
- "iCloud sync for your own devices"

## Comparable App Store Precedents

There are already successful App Store products that depend on a Mac/desktop companion, server, hardware device, or desktop workflow. The useful lesson is not that dependency is risk-free. The lesson is that dependency is acceptable when the iPhone/iPad app has a clear native utility, honest onboarding, and reviewable functionality.

### Elgato Stream Deck Mobile

Pattern: iPhone/iPad as a desktop control surface. The mobile app connects to the Stream Deck desktop app and gives the user programmable controls for apps, tools, plugins, and multi-action workflows.

Relevance to Steer:

- Strong precedent for "mobile control surface for desktop productivity workflows."
- Steer can position iPhone as an AI agent action control surface, not a terminal mirror.
- The product value is fast triage and action, not full desktop replication.

### BTT Remote Control

Pattern: iPhone/iPad remote control for BetterTouchTool on Mac. It requires BetterTouchTool running on the Mac and same-network connectivity.

Relevance to Steer:

- Shows that "requires a Mac companion" can be acceptable when disclosed.
- Steer should be equally explicit: live delivery requires Steer for Mac.
- BTT is broad remote control; Steer should stay narrower and safer: reply to agent action cards.

### Remote Mouse

Pattern: iPhone/iPad as mouse, keyboard, touchpad, media remote, and control panel for Mac/PC/Linux via desktop server software.

Relevance to Steer:

- Another precedent for installing a desktop server/helper.
- These apps usually survive by making setup instructions clear and by giving the mobile app a concrete, app-like control surface.
- Steer should avoid presenting itself as arbitrary computer control; it should present a constrained action inbox.

### Duet Display

Pattern: iPad/iPhone becomes an extra display for Mac/PC and requires a desktop app.

Relevance to Steer:

- Companion dependency is acceptable when the value proposition is concrete and immediate.
- Duet makes the dependency part of the setup story, not a hidden requirement.
- Steer should use the same clarity: Mac helper owns local agents; iPhone owns triage and replies.

### Luna Display

Pattern: iPad/Mac as second display and requires Luna desktop apps plus hardware.

Relevance to Steer:

- Even stronger dependency case: mobile app + desktop app + hardware can still be App Store viable.
- The key is that the mobile/iPad app is a real native surface with a clear role.
- Steer does not need hardware, but does need a trustworthy Mac availability/status model.

### Camo Camera

Pattern: iPhone camera becomes a Mac/PC webcam through a companion desktop app.

Relevance to Steer:

- Good precedent for iPhone as the lightweight, always-near input/output surface for a desktop workflow.
- Camo's value is not "remote control"; it is improving a desktop workflow using the iPhone's strengths.
- Steer should frame iPhone as the always-near decision/reply surface for local AI coding agents.

### Strategic Takeaway

Steer should not launch as "remote terminal for Mac." It should launch as:

> Stream Deck Mobile + Raycast iOS + AI coding action inbox.

That framing gives the iPhone app independent shape while keeping the Mac dependency honest. The App Store risk is lower if the app includes:

- demo/sample workspace,
- offline card cache,
- queued replies,
- visible Mac online/offline state,
- clear privacy/sync controls,
- and review notes explaining the companion architecture.

## Product Scope

### iPhone v1 Must Have

- Card stack using the current Mac card model.
- Session header: provider, project, branch, state.
- Terminal excerpt as primary trust surface.
- Suggested reply chips.
- Reply composer.
- Queued/delivered/failed status.
- Push notification on new actionable card.
- Offline cache of recent cards.
- Demo mode for App Review and first-run education.
- Pairing/onboarding flow for Mac Steer.
- Privacy screen that explains exactly what syncs.

### iPhone v1 Should Not Have

- Full terminal mirror.
- Live raw transcript streaming.
- Starting arbitrary Mac commands from iPhone.
- Team sharing.
- Multi-user rooms.
- Supabase/account system.
- Cross-platform web app.

### Sync Scope For v1

Sync only:

- `CardSnapshot`
- `SessionSnapshot`
- `InstructionRequest`
- `DeliveryStatus`
- minimal device/pairing metadata

Do not sync by default:

- raw transcript logs
- full terminal history
- environment variables
- local file paths beyond project display/cwd-derived label
- attachments unless explicitly added later with user consent

## CloudKit Record Sketch

Use a custom private zone, for example `SteerPrivateZone`.

### `Device`

- `deviceId`
- `platform`: `mac` / `iphone`
- `displayName`
- `lastSeenAt`
- `appVersion`

### `SessionSnapshot`

- `sessionId`
- `provider`
- `projectName`
- `branchLabel`
- `runState`
- `lastActivityAt`
- `macDeviceId`
- `isDeliverable`

### `CardSnapshot`

- `cardId`
- `sessionId`
- `category`
- `priority`
- `title`
- `summary`
- `actionPrompt`
- `terminalLinesJSON`
- `optionsJSON`
- `state`
- `createdAt`
- `updatedAt`
- `sourceFingerprint`

### `InstructionRequest`

- `instructionId`
- `targetSessionId`
- `text`
- `createdAt`
- `createdByDeviceId`
- `status`: `queued` / `claimed` / `injected` / `failed` / `expired`
- `claimedByMacDeviceId`
- `claimedAt`
- `injectedAt`
- `failureReason`

### `SyncSettings`

- `syncCardsEnabled`
- `syncTerminalExcerptEnabled`
- `syncFullTranscriptEnabled`: default false and likely not shipped in v1
- `notificationsEnabled`
- `updatedAt`

## Instruction Delivery Flow

```text
1. Mac Agent publishes active CardSnapshot.
2. CloudKit subscription notifies iPhone.
3. User opens card and sends a reply.
4. iPhone creates InstructionRequest(status=queued).
5. Mac Agent receives CloudKit change.
6. Mac Agent validates target session is live and deliverable.
7. Mac Agent marks request claimed.
8. Mac Agent calls local instruction delivery path.
9. Mac Agent updates status injected or failed.
10. iPhone observes status update and updates UI.
```

Important delivery rules:

- Mac remains the only process that can inject into wrappers.
- iPhone never writes directly to local SQLite or socket.
- Instruction records should be idempotent by `instructionId`.
- Mac should ignore requests for ended/disconnected sessions and mark them failed with a clear reason.
- Instructions should expire if unclaimed after a configured window, for example 24 hours.

## Pairing And Onboarding

Recommended v1 onboarding:

1. iPhone launches into demo workspace if no CloudKit data exists.
2. User signs into iCloud automatically through system account.
3. Mac app shows "Enable iPhone Sync."
4. User confirms sync scope on Mac.
5. Mac writes `Device` and first snapshots to CloudKit.
6. iPhone sees Mac device and switches from demo to real workspace.

QR pairing is optional if the product uses the same iCloud account and private database. Keep QR/code pairing as a fallback only if multiple Macs or multi-account cases become confusing.

## Mac App Changes Needed

- Add CloudKit capability to the Mac app distribution profile.
- Add a sync publisher from local SQLite/action card rows to CloudKit snapshots.
- Add a CloudKit instruction watcher.
- Add delivery status updates after `steer send`/agent injection.
- Add settings:
  - iPhone sync on/off
  - sync terminal excerpts on/off
  - full transcript sync unavailable or disabled by default
  - clear cloud data
  - connected devices
- Add conflict/idempotency handling.
- Add retry queue for offline CloudKit writes.

## iPhone App Build Plan

### Phase A: Launch Feasibility Spike

Goal: prove the release-critical path before polishing UI.

- Create iOS target or separate `apps/ios`.
- Create shared Swift package for models and reusable views.
- Add CloudKit private zone.
- Mac writes one sample `CardSnapshot`.
- iPhone reads it.
- iPhone writes one `InstructionRequest`.
- Mac receives it and logs a mock delivery.
- Verify Developer ID Mac build can use CloudKit in a signed/provisioned build.
- Verify CloudKit subscription push behavior on device.

Exit criteria:

- Real iPhone receives card updates from real signed Mac app.
- Real Mac sees iPhone instruction record.
- No local network dependency.

### Phase B: iPhone UI MVP

Goal: ship a TestFlight build that demonstrates the product loop.

- Port card stack, header, terminal excerpt, reply dock.
- Replace AppKit-only image/drop/clipboard code.
- Add iOS notification registration.
- Add offline cache.
- Add demo workspace.
- Add delivery status UI.
- Add onboarding and privacy copy.

Exit criteria:

- A user can triage and reply from iPhone while Mac is online.
- If Mac is offline, reply is visibly queued.

### Phase C: Real Delivery Beta

Goal: make it useful for daily work.

- Wire `InstructionRequest` to real Mac agent delivery.
- Add retry/expiration behavior.
- Add duplicate prevention.
- Add failed delivery recovery.
- Add metrics:
  - card publish latency
  - push received latency
  - reply queued to injected latency
  - failed instruction rate
  - stale card rate

Exit criteria:

- 20-100 TestFlight users can use it for real coding sessions.
- Delivery failures are understandable and recoverable.

### Phase D: App Store Submission

Goal: reduce review risk and make the app understandable.

- Built-in demo mode.
- App Review notes with sample flow.
- Clear privacy labels.
- Screenshots showing action inbox, not terminal remote control.
- Support URL with Mac install instructions.
- Explanation that Mac helper is required only for live delivery, while iPhone app supports demo/offline/review/queued workflow.

## Suggested Timeline

Realistic estimate if Mac v1 remains stable:

- Feasibility spike: 1 week
- iPhone UI MVP: 1-2 weeks
- Real delivery beta: 1-2 weeks
- TestFlight hardening: 1-2 weeks
- App Store submission prep: 2-4 days

Total: about 4-7 weeks to a credible iPhone-centered beta/release path.

The critical path is not UI. It is CloudKit delivery correctness, Mac background reliability, App Review framing, and privacy clarity.

## Risks

### App Review: Companion App Dependency

Risk: App appears useless without Mac app.

Mitigation:

- Demo mode.
- Offline cache.
- Queued replies.
- Clear App Review notes.
- App Store screenshots that show standalone app UI and value.

### Privacy: Sensitive Coding Context In iCloud

Risk: Terminal output may include secrets, paths, customer data, or code.

Mitigation:

- Sync card snapshots only.
- No raw transcript sync by default.
- Explicit setting before syncing richer context.
- Clear "what syncs" screen.
- Local redaction pass later if dogfood shows need.

### Delivery Reliability

Risk: iPhone says sent, but Mac never injects.

Mitigation:

- Separate `queued`, `claimed`, `injected`, `failed`, `expired`.
- Show Mac online/offline.
- Retry CloudKit fetches and local injection.
- Never hide failure state.

### Mac Background Availability

Risk: Mac app/agent not running, so delivery stalls.

Mitigation:

- Login item.
- Menu bar status.
- iPhone shows "Waiting for Mac."
- Mac publishes heartbeat to `Device.lastSeenAt`.

### Scope Creep

Risk: iPhone becomes remote IDE/chat/terminal.

Mitigation:

- Keep v1 to action cards and replies.
- Do not sync full transcripts.
- Do not start new terminal commands from iPhone in v1.

## Go / No-Go Checklist

Before committing to App Store submission:

- [ ] Developer ID Mac build can write/read CloudKit in a real signed build.
- [ ] iPhone receives card updates via CloudKit on device.
- [ ] iPhone can queue reply while Mac is offline.
- [ ] Mac injects queued reply when online.
- [ ] Delivery state is visible and correct.
- [ ] Demo mode works without Mac.
- [ ] Privacy copy clearly lists synced fields.
- [ ] No raw transcript sync by default.
- [ ] TestFlight beta has acceptable failure rate.
- [ ] Review notes explain the companion architecture.

## References

- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- CloudKit query subscriptions: https://developer.apple.com/documentation/cloudkit/ckquerysubscription
- Developer ID distribution and capabilities: https://developer.apple.com/developer-id/
- TestFlight overview: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- Elgato Stream Deck Mobile: https://apps.apple.com/us/app/elgato-stream-deck-mobile/id1440014184
- BTT Remote Control: https://apps.apple.com/us/app/btt-remote-control/id561676304
- Remote Mouse: https://apps.apple.com/us/app/remote-mouse/id385894596
- Duet Display: https://apps.apple.com/gb/app/duet-display/id935754064
- Luna Display: https://apps.apple.com/us/app/luna-display/id1250259715
- Camo Camera: https://apps.apple.com/us/app/camo-camera/id1514199064
