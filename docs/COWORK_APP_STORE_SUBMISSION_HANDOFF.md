# Steer iOS — App Store Submission 사전 준비 (Claude Cowork 핸드오프)

> 다른 Claude 세션이 처음부터 읽어서 사용자가 직접 가야 하는 단계와 코드에서 미리 박을 수 있는 단계를 즉시 구분할 수 있게 만든 single source of truth.
>
> 작성: 2026-05-13. **상태: 코드 변경 미시작, 메타데이터 수집 중.** 마지막 출시 차단 요소(아이콘, 푸시 알림 끝까지 도달, wrapper-disconnect)는 `docs/EXECUTION_PLAN.md` 5/12-5/13 entry 참고.
>
> Source documents this consolidates:
> - `docs/APP_STORE_LAUNCH_RUNBOOK.md` — 순서 + 명령 (124줄, 신뢰)
> - `docs/IOS_LAUNCH_PLAN.md` — 아키텍처 + 결정 로그 (511줄, 일부 stale)
> - `docs/legal/APP_REVIEW_NOTES.md` — 리뷰어 메모 (57줄)
> - `docs/legal/APP_STORE_PRIVACY_LABELS.md` — 영양 라벨 (87줄)
> - `docs/legal/LAUNCH_LEGAL_CHECKLIST.md` — 법무 (100줄)
> - `docs/legal/PRIVACY_POLICY.md` / `TERMS_OF_SERVICE.md` — 본문

---

## 0. 사용자만 할 수 있는 것 vs Claude가 사전 준비할 수 있는 것

**Claude가 할 수 있는 것 (지금 미리 다 끝낼 수 있음):**

- 마지막 코드 출시 차단 요소 (icon, push, wrapper-disconnect, sign-out presence) 해결
- App Store Connect에 붙여넣을 메타데이터 텍스트 초안 작성 (모든 카피 + 키워드 + 설명)
- App Privacy 영양 라벨 답안 JSON-처럼 정리 (Apple form에 한 번에 옮길 수 있게)
- App Review Notes (reviewer가 시연 시 따라가는 시나리오) 영문 완성
- TestFlight 빌드 만드는 fastlane / xcodebuild archive 스크립트
- 스크린샷 빌드 환경 (시뮬레이터 + 픽셀 정확 캔버스 + golden state) 준비
- 법무 페이지 (Privacy, Terms) 실제 deploy 확인 + 링크 검증
- App Store Connect API 토큰을 통한 자동 업로드 스크립트 (사용자가 토큰 제공 시)

**오직 사용자만 할 수 있는 것 (Claude는 절대 진행 못 함):**

- Apple Developer Portal 로그인 (앱 ID 생성, capability enable, provisioning profile)
- App Store Connect 로그인 (앱 생성, 가격/지역, 빌드 업로드 confirm)
- Apple Sign In capability 활성화 (이거 안 되어 있어서 dogfood DMG 빌드에서도 sign-in error 1000 났던 적 있음 — `docs/IOS_LAUNCH_PLAN.md` 참고)
- App Store 스크린샷 최종 컨펌 + 업로드
- 법적 동의 (Terms 수락, 세금 양식, payout 계좌)
- TestFlight external testing 그룹 베타 테스터 초대
- "Submit for Review" 버튼 누르기
- Reviewer 피드백에 대답하기

---

## 1. 코드 측 출시 차단 요소 (Claude가 끝낼 수 있음)

순서대로 그린이 떨어져야 submit 가능.

### 1.1 푸시 알림 끝까지 도달 — **상태: relay-side fix 완료, deploy 대기**

문제: SteerAgent가 `card-${sessionId}`을 카드 id로 재사용해서 같은 세션의 두번째 카드부턴 INSERT 아니라 UPDATE. relay가 `inserted` 게이트만 봐서 두번째 카드부터 영원히 알림 안 옴. 첫 카드만 알림.

PR #40에 commit `664518c` (`relay(apns): push on becameActive, not just first insert`)로 fix. 회귀 테스트 5개 추가 (`packages/relay/test/store_upsert_dedupe.test.ts`).

남은 액션 (사용자): `cd packages/relay && npx wrangler deploy`.

이게 안 되면 iPhone push 자체가 무가치 → App Review에서 "notification claim하는데 안 옴" reject 가능.

### 1.2 App icon — **상태: 진단 완료, 누락 변경 복원 대기**

문제 1: `apps/ios/SteerIOS/Assets.xcassets/AppIcon.appiconset/`에 1024 한 장만 있고, iOS는 universal 1x로 처리하지만 일부 디바이스 (홈스크린 long-press, 알림 큰 자산)에서 fallback 일어남.

문제 2: `claude.imageset` / `codex-color.imageset` 의 Contents.json이 @2x/@3x slot 선언했지만 실제 PNG 없음. 3x 디바이스에서 카드 헤더 ProviderMark가 1x 강제 업스케일로 흐림.

문제 3: `ActionNotificationService.swift` (Mac 측)가 `content.attachments` 비워둠 → notification banner에 generic icon mask.

진단 doc: `docs/ICON_FIX_DIAGNOSIS_2026-05-13.md`, `docs/ICON_FIX_PLAN.md` (sips 명령 line 60-72).

남은 액션 (Claude): @2x/@3x PNG 생성 + ActionNotificationService 첨부 코드. 시각 검증은 사용자 손에.

### 1.3 Wrapper disconnect-after-reply — **상태: 진단 doc만, fix 미시작**

문제: `packages/cli/src/index.js:253-268` `submitPtyInstruction`이 ack=injected를 무조건 emit, ptyProcess.write backpressure 무시, 50ms 후 carriage return 무조건 emit. iPhone reply가 Codex/Claude의 긴 turn 중에 떨어지면 paste bytes 손실. agent는 "injected" 기록, 활성 카드 resolve, 세션은 영원히 `running` → iPhone "1 running" stuck.

진단 doc: `docs/WRAPPER_DISCONNECT_DIAGNOSIS_2026-05-13.md` (root cause + reproduction approach + 12줄 fix sketch).

남은 액션 (Claude): reproduction test 먼저, fix 후 wrapper invariant suite 다시 그린.

App Review 측 영향: iPhone reply가 "delivered"로 표시되는데 답이 안 옴 → 사용자 불만 → 1성 review 폭주. 차단 요소.

### 1.4 Sign-out 시 presence stale — **fix 완료**

PR #40 commit `3649bfd`로 Mac signOut에서 DELETE /v1/sync/devices. iOS는 이미 했음. wrangler deploy 안 해도 됨 (기존 endpoint).

### 1.5 Empty-state CTA cleanup — **fix 완료**

PR #40 commit `afcab30`. `.offline` / `.error` 분기에서 hollow "Mac Status" 버튼 제거. App Review 시각 polish.

---

## 2. 메타데이터 — App Store Connect 입력란 단위

다른 Claude가 사용자 옆에서 App Store Connect 폼 채울 때 그대로 copy-paste 할 수 있는 형태로 준비.

### 2.1 앱 이름 / 부제

- **App Name (30자 한도)**: `Steer — AI Action Queue`
- **Subtitle (30자 한도)**: `Never let your AI sit idle`
- **Category (Primary)**: `Developer Tools`
- **Category (Secondary)**: `Productivity`

### 2.2 키워드 (100자, 콤마 구분)

```
claude code,codex,cli,ai coding,coding agent,terminal,wrapper,inbox,notification,dev tools
```

### 2.3 Promotional Text (170자, 언제든 수정 가능)

```
Steer turns Claude Code, Codex, and Gemini CLI into background workers. When your AI stops, your phone alerts you with one swipe to reply.
```

### 2.4 Description (4000자 한도, draft)

```
Steer is an AI action queue for CLI coding agents. Run Claude Code, Codex,
and Gemini CLI in the background; let Steer surface only the moments that
need your attention.

When your AI agent stops to ask a question, hit a blocker, or finish a
task, Steer shows it on your Mac and iPhone. Reply from anywhere — Steer
delivers your message back to the right session.

KEY FEATURES

• Card stack, not chat — only stopped sessions appear, never live
  scrolling output.
• iPhone companion — get a notification when your AI is waiting; type a
  one-line reply and send.
• Multi-provider — works with Claude Code (Stop/Notification hooks),
  Codex CLI (turn/completed events), and any command via `steer wrap`.
• Local-first — your terminal stays on your Mac. Only the small cards
  (provider name + project + last lines of output) sync to your iPhone.
• Privacy by default — no third-party analytics. Your AI conversations
  never leave your Mac unless you explicitly turn on iPhone Sync.

GETTING STARTED

1. Install Steer on your Mac (steer.ai/download).
2. In a terminal, run `steer claude` or `steer codex` instead of the
   raw command.
3. Sign in with Apple on both Mac and iPhone using the same Apple ID.

This iPhone companion app is free. Steer for Mac is required and is
also free during the beta.

PRIVACY

Steer never reads your screen and never asks for Accessibility,
Screen Recording, or Input Monitoring permissions. Your terminal
sessions are wrapped explicitly when you launch them with the `steer`
command. Read the full Privacy Policy in Settings.
```

### 2.5 What's New (4000자)

초기 출시 버전 (v1.0):

```
Welcome to Steer. This is the first public release.

• AI action queue for Claude Code, Codex CLI, and Gemini CLI
• iPhone push notifications when your AI is waiting on you
• Card-based reply flow synced across Mac and iPhone
• Sign in with Apple
• Privacy-first: local-only by default, your conversations stay on
  your Mac unless you turn on iPhone Sync
```

### 2.6 Support URL / Marketing URL / Privacy Policy URL

- Support URL: `mailto:superwedge.labs@gmail.com?subject=Steer%20Support` (Steer.ai 마케팅 페이지 부재 동안 임시)
- Marketing URL: `https://steer.ai` (도메인 살아있으나 페이지 미배포 — 출시 전 최소 lander 필요)
- Privacy Policy URL: `https://steer-legal.pages.dev/privacy/` (legal-site worktree에서 deploy 후 확인)

### 2.7 Age Rating

- Profanity / Sex / Violence: 모두 None
- Unrestricted Web Access: **No** (in-app browser 없음, mailto + 외부 링크만 — 사용자 브라우저로 jump)
- User-Generated Content: **Yes (with moderation)** — 사용자가 입력하는 reply text가 다른 사용자에게 노출되진 않지만, 자기 디바이스 간 동기화. Apple 가이드는 "다른 사용자에게 안 보이면 No로 답해도 됨"이지만 보수적으로 Yes 후 "사용자는 자기 디바이스만 본다" 명시.
- Predicted Rating: `4+`

---

## 3. App Privacy 영양 라벨 (Apple form 그대로)

### 3.1 Data Collected

| Category | Type | Purpose | Linked to user | Tracking |
|---|---|---|---|---|
| Contact Info | Email Address | App Functionality (Sign in with Apple) | Yes | No |
| Identifiers | User ID (server-assigned) | App Functionality | Yes | No |
| Identifiers | Device ID (per-install UUID) | App Functionality (push routing) | Yes | No |
| Diagnostics | Crash data | App Functionality | No | No |
| User Content | Other User Content (action card text + reply text) | App Functionality | Yes | No |

### 3.2 Data NOT Collected

- 위치 / Health / Financial / Browsing History / Search History / Sensitive Info — 모두 Not Collected
- Tracking: **No tracking, no third-party SDKs, no ad networks**

### 3.3 Privacy Practices

- Data minimization: 카드는 본문 마지막 라인 + 카테고리 + 세션 메타 (no full transcript).
- Retention: 24h 후 stale device row 자동 삭제. 카드는 사용자 reply 후 done state로 7-day 이내 purge.
- User access: 사용자가 Settings → Delete Account으로 server data 즉시 삭제 (Apple guideline 5.1.1(v) 준수).

### 3.4 Apple Sign In 관련 추가 답안

- "Hide My Email" 지원 — yes
- Email 사용 목적 — 계정 식별, 사용자 메일 발송 안 함 (transactional 포함)
- Auth code 저장 — 30일 (Apple revoke endpoint 호출 위해서만 유지)

---

## 4. App Review Notes (`docs/legal/APP_REVIEW_NOTES.md` 기반 갱신본)

리뷰어가 시연 시 따라가는 시나리오. App Store Connect의 "App Review Information" 폼에 paste.

```
HELLO REVIEWER,

Steer is a companion to a separate Mac app (Steer for Mac) that wraps
CLI coding agents like Claude Code and Codex CLI. The iPhone app shown
to you is a remote inbox + reply surface.

DEMO ACCOUNT

You do not need a demo account to evaluate the app. The empty-state
inbox and the "Try Demo" button (which appears when no Mac is paired
to your Apple ID) are sufficient to evaluate the core UX without
installing the companion.

FLOW TO REVIEW

1. Launch the app — you'll see the SignInPrompt with an animated
   dot-grid background. Tap "Sign in with Apple".
2. Use any Apple ID. On first sign-in we receive fullName + email
   (or Hide-My-Email relay) from Apple's system sheet.
3. You'll see a 3-card tutorial. Type "next" or just hit send to
   advance. Tap Skip to bypass.
4. After the tutorial, the inbox appears with a "Set Up Mac" /
   "Try Demo" empty state because no Mac is paired to your Apple ID.
5. Tap "Try Demo". You'll see two mock cards — tap one to see the
   reply flow.
6. Open Settings (top-left) to see your Apple ID, the Notifications
   toggle, the GitHub Issues link, and the legal links.

ABOUT THE COMPANION MAC APP

The Mac app is direct-distribution (not on the App Store) and is
required for the iPhone app to display real cards. Steer is fully
functional in demo mode without it. The Mac app uses no
Accessibility / Screen Recording / Input Monitoring permissions; it
wraps CLI processes explicitly by user invocation.

DATA / PRIVACY

We collect minimal data — see the App Privacy nutrition label. The
iPhone app sends pushes via APNS only when the user has a paired
Mac AND a card lands. There is no tracking, no third-party SDKs,
and no analytics.

QUESTIONS

Email: superwedge.labs@gmail.com
```

---

## 5. 빌드 + 업로드 워크플로 (`docs/APP_STORE_LAUNCH_RUNBOOK.md` 기반)

### 5.1 사전 — Apple Developer Portal

- [ ] App ID `ai.steer.ios` 생성, capabilities: Sign in with Apple, Push Notifications
- [ ] Provisioning Profile: App Store Distribution용 새로 생성 (`Steer iOS Distribution`)
- [ ] APNS Auth Key (`.p8`) 발급, Team ID + Key ID 기록 — 이미 relay env (`APNS_PRIVATE_KEY` / `APNS_KEY_ID` / `APNS_TEAM_ID`) 박힘. submission 후에도 동일 키 사용 가능.

### 5.2 App Store Connect 앱 생성

- [ ] My Apps → + → New iOS App
- [ ] Bundle ID: `ai.steer.ios`
- [ ] SKU: `STEER_IOS_001`
- [ ] User Access: Full Access
- [ ] Pricing: Free, all territories

### 5.3 빌드 archive + upload

```sh
# 1. archive
xcodebuild -project apps/ios/Steer.xcodeproj \
  -scheme Steer \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath apps/ios/build/Steer.xcarchive \
  archive

# 2. export for App Store
xcodebuild -exportArchive \
  -archivePath apps/ios/build/Steer.xcarchive \
  -exportPath apps/ios/build/Steer-AppStore \
  -exportOptionsPlist apps/ios/ExportOptions-AppStore.plist

# 3. upload (App Store Connect API key 필요)
xcrun altool --upload-app \
  -f apps/ios/build/Steer-AppStore/Steer.ipa \
  -t ios \
  --apiKey "$ASC_API_KEY_ID" \
  --apiIssuer "$ASC_API_ISSUER_ID"
```

`ExportOptions-AppStore.plist` 작성 필요 (없으면 1회만 만들면 됨):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>TEAM_ID_FROM_APPLE</string>
    <key>uploadSymbols</key>
    <true/>
    <key>uploadBitcode</key>
    <false/>
</dict>
</plist>
```

### 5.4 TestFlight

- [ ] App Store Connect → TestFlight 탭 → 빌드가 processing 끝날 때까지 대기 (보통 5-30분)
- [ ] Internal testers: 사용자 본인 Apple ID 추가 (10명 limit, instant)
- [ ] Test Information: email + Privacy Policy URL 필수
- [ ] 빌드 install → 모든 screen pass 확인 (체크리스트는 §6)

### 5.5 Screenshots (필수 사이즈)

| Display | Resolution | 필요 매수 |
|---|---|---|
| iPhone 6.7" (Pro Max) | 1290 × 2796 | 3-10 |
| iPhone 6.5" (older Max) | 1284 × 2778 또는 1242 × 2688 | 3-10 |
| iPad 13" | 2064 × 2752 | optional (iPad 미지원 시 skip) |

촬영 대상 (사용자 골든 셋):
1. SignInPrompt (앱 아이콘 + 워드마크 + Apple 버튼 + RoutingFieldView 애니메이션 한 프레임)
2. Onboarding 1번 카드 (text streaming 중간 프레임)
3. Inbox에 카드 하나 (`.connected` 상태, claude/codex 아이콘)
4. 카드 reply flow (ReplyDock open + 사용자 입력 일부)
5. Empty state `.connected` ("No waiting actions")
6. Settings (Notifications toggle ON + GitHub mark + Privacy/Terms 표시)

---

## 6. 마지막 골든 셋 (submission 직전)

사용자가 손수 돌리는 시각 검증. App Review reject 막는 거.

- [ ] Launch → SignInPrompt 화면 안에 Steer 앱 아이콘 (84pt) 보임
- [ ] Sign in with Apple → Onboarding 1번 카드 → 텍스트 character-streaming 잘 흐름
- [ ] Send 누르면 그 카드가 carousel에서 빠짐 (PR #40 commit `64bccbb` 검증)
- [ ] 마지막 (3번) 카드 send → carousel 자체 사라짐 → Inbox 진입
- [ ] Mac 미페어링 상태에서 "Set Up Mac" + "Try Demo" 둘 다 보임
- [ ] `.offline` / `.error` empty state엔 버튼 없음 (PR #40 commit `afcab30` 검증)
- [ ] Settings → Identity 행에 `displayName` 표시 (재인증 dev 사용자는 nil인 게 정상; 신규 유저는 채워짐)
- [ ] Settings → Notifications toggle 토글 가능, granted 상태에서 끄면 시스템 Settings deeplink
- [ ] Settings → Report an Issue → GitHub Octicons 마크 보임
- [ ] Settings → Privacy → `steer-legal.pages.dev/privacy/` 200 응답 (legal-site worktree deploy 후)
- [ ] Settings → Support → Mail composer 자동 채워짐
- [ ] Sign out → Mac 측 iPhone presence dot 60s 안에 사라짐
- [ ] 새 카드 만들기 (Mac에서 codex 세션 → stop) → iPhone lock screen에 banner + badge (PR #40 commit `664518c` deploy 후)
- [ ] 두번째 카드 동일 → 알림 다시 옴 (regression 검증)
- [ ] Delete Account → 즉시 sign out + 다음 launch 시 SignInPrompt

---

## 7. 알려진 위험 + reject 가능성

1. **Apple Sign In capability가 진짜 활성화됐는지** — dev 빌드에서 error 1000 났던 적 있음 (`docs/IOS_LAUNCH_PLAN.md` 5/11 entry). Distribution profile 새로 만들 때 같이 검증.
2. **"Try Demo" CTA가 자동으로 들어간 게 아니라 manual entry** — 사용자 직접 enterDemoMode() 호출하므로 App Review 5.1.1(iii) "사용자 동의 없이 데이터 demo 흐름 진입" 우려 없음. 그래도 reviewer note에 "demo는 사용자가 명시적 탭 후 진입"이라고 적어둘 가치 있음.
3. **`mailto:` Support URL** — Apple 가이드는 "support URL은 웹페이지여야 함" 권장. 마케팅 도메인 (steer.ai) 미배포 상태에서 임시 mailto만 쓰면 reviewer가 reject할 수 있음. 최소 lander 페이지 (`steer.ai` 또는 `steer-legal.pages.dev/support/`) 필요.
4. **Push notification screenshot에 진짜 알림 떠 있어야** — 시뮬레이터에서 push 시뮬 가능 (`xcrun simctl push`). 사용자가 진짜 카드 만들고 캡처하든, 시뮬 알림 캡처하든 OK. 가짜 mockup은 reject 사유 (App Store Review 2.3.3).
5. **위 1.3 (wrapper disconnect) 해결 안 되면 출시 후 사용자 review 별점 폭락** — 출시 차단이라기보다 출시 후 ROI 차단. 강력히 권장: 출시 전에 fix.

---

## 8. 다음 Claude (cowork)에게 부탁할 일 (순서대로)

1. **출시 전 코드 차단 요소 (§1) 모두 그린 만들기** — 1.2 + 1.3가 남음. 1.1은 wrangler deploy만 남음.
2. **App Store Connect 폼 채우기 driver** — §2-§4의 모든 텍스트를 사용자 옆에서 같이 보면서 폼에 paste. 사용자가 키 입력 + Submit 버튼 누름.
3. **빌드 + 업로드** — §5.3 명령 실행. ASC API key는 사용자 발급 후 환경변수로.
4. **스크린샷 자동화** — `xcrun simctl` + `xcodebuild test` UI test 활용. 골든 셋 (§5.5)의 6장을 픽셀 정확하게 캡처. 시뮬레이터 status bar는 `xcrun simctl status_bar override`로 12:00 / 100% / WiFi full 통일.
5. **TestFlight 베타 → external testing** — 사용자가 invite 보내고 피드백 수집. Claude는 TestFlight 빌드의 새 commit / release note 작성 도움.
6. **Submit for Review** 후 reviewer 피드백 응답.

---

## 9. 이 문서 외에 cowork가 읽어야 하는 것

- `EXECUTION_PLAN.md` (Last updated 2026-05-13) — 무엇이 끝났고 무엇이 남았는지
- `docs/WRAPPER_DISCONNECT_DIAGNOSIS_2026-05-13.md` — wrapper fix root cause
- `docs/ICON_FIX_DIAGNOSIS_2026-05-13.md` — icon 누락 진단
- `docs/SETTINGS_PROFILE_RESEARCH_2026-05-13.md` — 프로필 사진 / 이름 연구 (포스트-출시 polish)
- `CLAUDE.md` — 작업 원칙 (카파시 4룰, 검증 게이트)
- `docs/CLASSIFIER_CONTRACT.md` + `docs/REGRESSION_CONTRACT.md` — 절대 깨면 안 되는 invariant

cowork는 이 문서만 읽어도 사용자 옆에서 즉시 진행 가능해야 한다. 빠진 게 있으면 사용자에게 묻기 전에 위 source documents 먼저 확인.
