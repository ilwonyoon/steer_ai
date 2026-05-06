# PRD: Steer

> **One-liner**: 여러 AI CLI 세션 중 지금 멈춰 있거나 답이 필요한 작업을 카드 스택으로 빠르게 처리하고, 필요한 순간 바로 지시해서 AI 작업이 멈추지 않게 하는 개인용 AI action queue.

> **Core metaphor**: 차의 부품들(엔진, 변속기 등)은 다 갖춰져 있다. 하지만 운전(steer)을 안 하면 못 간다. AI 에이전트들이 부품이라면, 사용자는 운전자. Steer는 사용자가 여러 AI 세션을 계속 운전하게 해주는 운전대다.

## Problem

AI 코딩 에이전트가 24시간 돌 수 있는 시대인데, 사용자(=사람)가 여러 세션의 진행상황을 보고 받고, 막힌 곳에 지시하고, 다음 일을 계속 굴리는 운영자가 되었다. 병목은 단순히 "질문에 늦게 답하는 것"이 아니라 여러 CLI 세션이 각자 터미널에 흩어져 있어 현재 무엇이 진행 중인지, 무엇이 멈췄는지, 어디에 지시해야 하는지 한눈에 알기 어렵다는 점이다.

에이전트가 작업하다 결정 포인트, blocker, 완료 보고, 추가 지시 필요 상태에 도달하면 사용자가 즉시 개입해야 한다. 책상 앞에 없으면 세션은 idle하고, 책상 앞에 있어도 여러 터미널/프로젝트/에이전트 사이를 오가느라 관리 비용이 커진다. 결과: 비싼 AI throughput이 사람의 운영 latency 때문에 낭비된다.

**가설**: 여러 AI 작업 세션 중 지금 사용자의 판단이 필요한 항목을 카드 스택으로 우선순위화하고, 상세 화면에서 바로 답변/지시할 수 있으면, 사용자의 운영 latency가 줄고 AI idle time이 감소한다. 이 효과는 answer latency, instruction latency, idle time reduction, active session continuation rate로 측정 가능하다.

## Why Now

Claude Code, Codex, Gemini CLI 등 에이전트 CLI가 mainstream화 (25-26). "Vibe coding" = 여러 에이전트를 병렬로 돌리는 문화 정착. Anthropic Remote Control, Happy 등 모바일/원격 컨트롤러 시장 검증. 그러나 대부분 풀 챗 미러링 모델이라, 여러 실제 CLI 세션을 한 곳에서 보고 받고 지시하는 personal AI operations room은 비어 있다.

## Target User

**Primary**: AI-native builder / vibe coder. Claude Code/Codex/Gemini CLI 매일 사용. 동시에 여러 세션(3-10개) 돌림. 책상에서 떠나도 작업 진행시키고 싶음. 지시 인풋은 대부분 짧음: 승인, 선택, 다음 작업, blocker 해소. AI에 월 $20-200 지출 의향.

**Secondary**: 일반 indie hacker, AI 워크플로우 운영자.

## Core Insight

기존 솔루션 = "데스크톱 챗/터미널 환경 -> 폰으로 옮김" (mirroring). Steer = "여러 AI 작업 세션 -> action queue로 운영" (AI operations room).

제품의 핵심은 "결정만 빨리 답하기"가 아니라, 사용자가 여러 CLI 세션의 보고를 받고, 막힌 세션에 지시하고, 완료된 세션에 다음 작업을 이어붙여 AI가 멈추지 않게 하는 것이다.

비유: Tinder-style card stack의 one-at-a-time triage + Claude/Codex-style session detail + Instagram DM의 가벼운 답변 감각 + Linear의 작업 상태/우선순위. 사용자는 기본 화면에서 urgent card를 빠르게 처리하고, 필요할 때 상세로 들어가 전체 맥락을 본다.

데이터 모델은 사용자-에이전트 세션의 1:1 대화 N개와, 그 위에 쌓이는 action item queue다. UX 모델은 기본적으로 하나의 action card stack이지만, 반드시 하나의 대화방이어야 하는 것은 아니다. 사용자는 원하면 여러 room으로 나눠 관리할 수 있다. 어떤 CLI session을 어떤 room에 초대할지는 후속 스펙으로 둔다.

## Differentiation

- **vs Anthropic Remote Control**: RC는 Claude 세션을 폰에 mirror하는 모델. Steer는 여러 CLI 세션을 action queue로 운영하고, 보고/지시/상태 관리를 한 흐름으로 묶는다.
- **vs Happy**: Happy는 풀 챗을 폰으로 옮기는 검증된 wrapper/remote-control 인프라. Steer는 그 위에 "stuck AI action queue" UX를 얹는다.
- **vs Slack/Discord/Telegram에 직접 붙이기**: 범용 메시징 도구는 CLI 세션의 stdin/stdout ownership, 상태 추적, 답 주입, AI idle 메트릭을 first-class로 갖지 않는다.
- **vs 멀티 에이전트 챗/오케스트레이션**: 그들은 에이전트 간 협업/동기적 Q&A 모델에 가깝다. Steer는 사용자가 여러 실제 CLI 세션을 비동기적으로 운영하는 personal control room이다.

핵심 차별화: AI action queue, card-stack 기반 multi-session triage, wrapper/provider-control을 통한 실제 답/지시 주입, 빠른 답/빠른 지시 버튼, idle/block/running 상태와 throughput 메트릭.

## Core Experience

**Onboarding**: Mac 앱 설치 -> wrapper command 설치 (`steer claude`, `steer codex`) -> 로컬 권한/notification 설정 -> 기본 action queue 생성 -> 첫 CLI session 연결.

**Main loop**:

1. 사용자가 데스크톱에서 `steer claude` 등으로 AI CLI 세션을 시작한다.
2. Steer가 세션 출력과 상태를 캡처한다.
3. 세션이 완료, blocker, decision, question, idle 상태에 도달하면 action card로 올라온다.
4. 분류 AI가 메시지를 요약하고, 필요한 경우 quick reply/quick instruction 옵션을 만든다.
5. 사용자는 카드에서 바로 버튼을 탭하거나, 카드를 열어 전체 맥락을 본 뒤 짧은 텍스트로 응답한다.
6. 답변 또는 지시가 해당 CLI session에 주입되고, 세션은 즉시 작업을 계속한다.
7. 사용자는 기존 질문에 답하는 것뿐 아니라, 상세 composer에서 먼저 특정 session에 새 지시를 보낼 수 있다.

## Design Direction

- **Primary interaction**: Tinder-style card stack. 한 번에 하나의 stuck/waiting card를 보고 빠르게 처리.
- **Triage workflow**: Gmail + Smart Reply. 빠른 분류, quick chip, snooze/done/skip.
- **Detail view**: Claude/Codex-style session. 전체 transcript/context, metadata, composer.
- **Visual tone**: Instagram DM. 가볍고 즉각적인 reply surface, compact bubbles, approachable interaction.
- **Technical layer**: Linear. `running`, `waiting`, `blocked`, `done` 같은 세션 상태, priority, project grouping, dense-but-clean metadata.
- **Optional Mac interaction**: Raycast. command palette, `@session` routing, 빠른 card/session 전환.

## Out Of Scope (v1)

Android, Linux, Windows. 팀/협업 기능. 에이전트끼리 서로 communicate하거나 자동으로 작업을 넘겨주는 orchestration. 사용자가 room에 어떤 CLI session을 초대할지 정교하게 관리하는 기능. 음성 답변. LLM 자체 호스팅. 결제 시스템.

## Success Metrics

- Activation: 설치 후 24시간 내 wrapper session 1개 이상 캡처.
- Engagement: answer latency, instruction latency, reports reviewed, instructions sent, active sessions per day.
- Throughput: AI idle time reduction, waiting/block 상태 평균 지속 시간, session continuation rate.
- Quality: quick action 사용률, 분류 정확도, 잘못된 알림률, 사용자 지시 후 에이전트 성공률.

## Roadmap

- **Week 1**: Mac 단독 prototype. Wrapper로 stdout/stderr 캡처 + stdin 주입 검증. 기본 action card stack, session status, report/instruct loop.
- **Week 2**: Mac UX 다듬기. card detail, session filter, composer target routing, notification, idle/block 상태 메트릭.
- **Week 3-4**: iOS 앱 + 동기화. iOS card stack + detail reply UI + 푸시 알림. 5명 베타.
- **Beyond**: Android/PWA, 음성 답변, 팀 기능, 고급 room/session routing, Backtick 통합, 자동 handoff/orchestration.
