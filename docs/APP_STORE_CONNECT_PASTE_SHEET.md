# App Store Connect — Steer iOS 제출 붙여넣기 시트

> **iOS App Store 제출 전용.** Steer Mac은 direct DMG 배포.
> 각 섹션을 App Store Connect 해당 필드에 그대로 붙여넣기.
>
> Final launch source of truth: `docs/APP_STORE_SUBMISSION_MARKETING_PACK.md`.
> 이 파일은 quick paste sheet이고, 스크린샷/포지셔닝/리뷰 방어 논리는 marketing pack을 우선한다.

---

## App Information

| 필드 | 값 |
|---|---|
| **App Name** | `Steer - Agent Inbox` |
| **Subtitle** | `Never let AI sit idle` |
| **Bundle ID** | `ai.steer.ios` |
| **SKU** | `ai.steer.ios` |
| **Primary Category** | Developer Tools |
| **Secondary Category** | Productivity |
| **Age Rating** | 4+ (설문: 모두 None/No) |
| **Price** | Free |
| **Availability** | All territories |

---

## App Store Version — Description Tab

### Promotional Text (170자 이내, 언제든 수정 가능)
```
Steer turns waiting AI coding agents into iPhone action cards, so you can review context, send a reply, and keep work moving from anywhere.
```

### Description (4,000자 이내)
```
Steer is an action inbox for AI coding agents running on your Mac.

When a local coding agent stops to ask a question, hits a blocker, or finishes a task, Steer turns that moment into a focused iPhone card. Review the context, type a reply, and send it back to the right Mac session without returning to your desk.

WHY STEER

AI agents are most useful when they keep moving. Steer helps you catch the exact moments that need your input, so long-running coding sessions do not sit idle while you are away from the terminal.

WHAT YOU CAN DO

• Get notified when a Mac coding session needs attention
• Review action cards with provider, project, branch, summary, and short output excerpt
• Send replies back to the matching Steer-managed session
• Track queued, delivered, failed, and offline states
• Use Try Demo to explore the full card workflow without setting up a Mac
• Manage Sign in with Apple, notifications, support links, and account deletion from Settings

HOW IT WORKS

Steer for Mac wraps coding-agent sessions that you explicitly start. The iPhone app receives small action cards and sends replies through the Steer relay. Your Mac handles local session capture and local instruction delivery.

Steer is not a remote terminal, remote desktop client, or screen mirror. It does not expose a live shell prompt, stream your Mac screen, or let your iPhone browse or launch arbitrary Mac commands.

PRIVACY

Steer uses Sign in with Apple and has no third-party advertising or tracking SDKs. Full transcripts and files stay on your Mac. Only the action-card context needed for review and reply is synced when you enable iPhone Sync.

Steer for Mac is required for live cards. The iPhone app includes Try Demo so you can understand the workflow before connecting your own Mac.
```

### Keywords (100자, 콤마 구분)
```
ai coding,agent inbox,cli,dev tools,workflow,notifications,async coding,terminal,productivity
```

### What's New (첫 버전)
```
Initial release.

Steer brings iPhone action cards to local Mac coding agents, with push notifications, focused review context, reply delivery, Try Demo, Sign in with Apple, and account deletion.
```

---

## App Information Tab

| 필드 | 값 |
|---|---|
| **Support URL** | `https://ilwonyoon.github.io/steer_ai/support/` |
| **Marketing URL** | `https://ilwonyoon.github.io/steer_ai/` |
| **Privacy Policy URL** | `https://ilwonyoon.github.io/steer_ai/privacy/` |

> **steer.ai 도메인이 준비되면** 위 URL을 `https://steer.ai/support/` 등으로 교체.

---

## App Privacy (Data Types)

App Store Connect → App Privacy → Data Types 순서대로 입력.

### ✅ Data Linked to the User

**Contact Info → Email Address**
- Collected: Yes
- Purpose: App Functionality
- Linked to user: Yes
- Used for tracking: No

**Identifiers → User ID**
- Collected: Yes
- Purpose: App Functionality
- Linked to user: Yes
- Used for tracking: No

**Identifiers → Device ID**
- Collected: Yes
- Purpose: App Functionality (push notification routing)
- Linked to user: Yes
- Used for tracking: No

**User Content → Other User Content**
- Collected: Yes
- Purpose: App Functionality (action card text + reply text sync)
- Linked to user: Yes
- Used for tracking: No

### ❌ Not Collected (선택 안 해도 됨, 확인용)
Location, Health & Fitness, Financial Info, Contacts, Photos/Videos,
Audio, Browsing History, Search History, Sensitive Info, Purchases,
Usage Data (except Device ID above), Diagnostics.

### Tracking
**Does Steer use data to track users? → No**

---

## App Review Information

### Sign-in Required
- Sign-in required: **Yes** (Sign in with Apple)
- Demo account: 별도 제공 불필요 (Try Demo 버튼으로 리뷰 가능)

### Notes for Reviewer (아래 영문 그대로 붙여넣기)
```
HELLO REVIEWER,

Steer is a companion to Steer for Mac, which wraps CLI coding agents on the user's Mac. The iPhone app is a mobile action inbox and reply surface — it is NOT a remote terminal, remote shell, or screen mirror.

YOU DO NOT NEED A DEMO ACCOUNT OR A LIVE MAC.

FLOW TO REVIEW:
1. Launch the app — SignInPrompt screen with animated background appears.
2. Tap "Sign in with Apple" with any Apple ID.
3. A 3-step tutorial card appears. Tap Send or Skip.
4. The inbox shows an empty state with a "Try Demo" button (no Mac is paired to the review Apple ID).
5. Tap "Try Demo" to see mock action cards without any network or Mac setup.
6. Open a card → see provider icon, summary, terminal excerpt, and reply composer.
7. Type a reply and tap Send — it queues locally and shows queued status.
8. Tap Settings (top-right) → verify Sign Out, Delete Account, Privacy Policy, Terms.

WHAT THIS APP DOES NOT DO:
- Does not mirror a live terminal or shell prompt.
- Does not let the user run arbitrary commands on the Mac.
- Does not use Accessibility, Screen Recording, or Input Monitoring permissions.
- Does not include any third-party advertising or tracking SDK.

SIGN IN WITH APPLE:
Steer requests fullName and email scopes. Email is used only for account identification. No email is sent to the user.

If you have questions, contact superwedge.labs@gmail.com.
```

---

## GitHub Pages 활성화 확인 (한 번만)

GitHub repo → Settings → Pages → Source: `Deploy from a branch` → Branch: `main` → Folder: `/docs`

활성화하면 아래 URL이 live:
- `https://ilwonyoon.github.io/steer_ai/` (랜딩)
- `https://ilwonyoon.github.io/steer_ai/privacy/` (개인정보처리방침)
- `https://ilwonyoon.github.io/steer_ai/terms/` (이용약관)
- `https://ilwonyoon.github.io/steer_ai/support/` (지원)

---

## 제출 전 최종 체크리스트

- [ ] GitHub Pages 활성화 + 4개 URL 브라우저에서 직접 확인
- [ ] App Store Connect에 앱 레코드 생성 (Bundle ID: `ai.steer.ios`)
- [ ] 위 시트 내용 App Store Connect 폼에 붙여넣기
- [ ] App Privacy 라벨 위 내용대로 입력
- [ ] Xcode에서 MARKETING_VERSION `1.0.0`으로 변경 (현재 `0.0.1`)
- [ ] Xcode → Product → Archive → Distribute → App Store Connect
- [ ] TestFlight 빌드 확인 후 Submit for Review
