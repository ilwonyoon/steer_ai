# Steer iOS — Launch Checklist (Submission Ready)

> **하나의 체크리스트.** 모든 항목 done 처리되면 App Store Connect에 "Submit for Review" 누를 수 있는 상태. 단순한 plain checklist이지 설명서가 아니다. 깊이 있는 reference는 각 항목 옆에 링크.
>
> Track: `fix/mac-chip-reconciliation` (PR #40) + 출시 직전 분리 PR들.
> Last touched: 2026-05-13.
> Owner: 사용자 = `🙋`, Claude = `🤖`.

---

## Phase 0 — Pre-flight (지금 즉시)

작업 시작 전 깨끗한 baseline 확보.

- [x] 🤖 모든 dirty 파일 commit + push (PR #40 상태) — current origin head `2e785dd`
- [x] 🤖 회귀 게이트 그린 — `STEER_INTEGRATION=1 npm test` (130/130)
- [x] 🤖 dogfood Mac.app + iPhone 빌드 install (오늘 변경 반영)
- [ ] 🙋 PR #40 head commit (`5a624b7` + pending local launch-prep commit) squash-merge 또는 cherry-pick으로 main 으로 가져오기. 머지 후 fix branch 정리.
- [ ] 🙋 Cloudflare `wrangler deploy` (push fanout fix `664518c` 반영) — `cd packages/relay && npx wrangler deploy`

---

## Phase 1 — Code Blockers (출시 불가 항목)

### 1A. App icon 누락 부분 복원 — task #277

**진단 doc 재확인 결과: 코드는 이미 모두 정상.** 2026-05-13 새벽 작성한 `docs/ICON_FIX_DIAGNOSIS_2026-05-13.md` 는 stale 정보를 담고 있었다. 실제 상태:
- `claude.imageset` / `codex-color.imageset` — 1x/2x/3x PNG + Contents.json 모두 박혀 있음. sim 빌드 Assets.car는 device-scale 기준으로 stripped (iPhone 17 sim → 1x + 3x 만), 이건 정상.
- `ActionNotificationService.swift:37` — `content.attachments = [attachment]` 이미 호출하며 `providerIconAttachment` 가 NSTemporaryDirectory 복사 + memoize 패턴으로 구현됨.
- AppIcon 1024 single — universal idiom + 1024 master는 Xcode 14+에서 합법적 modern pattern.

남은 일은 시각 검증뿐:

- [x] 🤖 `xcrun assetutil --info Assets.car` 검증 — claude@3x.png 들어가있음 확인
- [ ] 🙋 iPhone 빌드 install 후 카드 헤더 ProviderMark 선명한지 시각 확인
- [ ] 🙋 Mac에서 notification banner 떴을 때 provider icon 보이는지 시각 확인

### 1B. Wrapper disconnect-after-reply 회귀 — task #283 / G14

진단: `docs/WRAPPER_DISCONNECT_DIAGNOSIS_2026-05-13.md`. Root cause: `packages/cli/src/index.js:253-268` `submitPtyInstruction`이 backpressure / drain 무시 + 무조건 ack=injected.

**상태**: 코드 fix + invariant gate 통과. 남은 것은 실제 codex/claude dogfood.

- [x] 🤖 `submitPtyInstruction` atomic write 유지 + send retry가 SIGKILL stale-lock restart window까지 커버
- [x] 🤖 `packages/cli/test/instruction_delivery_invariant.test.js` 2 케이스 그린
- [x] 🤖 `STEER_INTEGRATION=1 npm test` 130/130 통과
- [ ] 🙋 dogfood: 진짜 codex 세션 → 긴 turn → iPhone reply → 답 도착 확인 (10s 이내)
- [ ] 🙋 dogfood: iPhone reply 5회 연속 → 모두 도착

### 1C. Push fanout deploy — relay-side commit `664518c`

- [ ] 🙋 `cd packages/relay && npx wrangler deploy`
- [ ] 🙋 `npx wrangler tail steer-relay --format=pretty | grep apns` 띄워두고 새 카드 만들기 → `[apns] sent ... ok=true` 확인
- [ ] 🙋 두번째 카드 동일 → 또 `ok=true` (regression 방지)

### 1D. Sign-out presence stale — commit `3649bfd` (fix 완료, 검증만)

- [ ] 🙋 Mac sign out → 60s 안에 iPhone "Mac connected" 사라짐 시각 확인

### 1E. SignInPrompt value prop + demo entry — latest local launch-prep

- [x] 🤖 SignInPrompt wordmark 아래 value prop 2줄: `Never let your AI sit idle.` / `Set the course. Steer faster.`
- [x] 🤖 signed-out SignInPrompt에 `Try Demo` 진입 복원
- [ ] 🙋 iOS 사인-아웃 → SignInPrompt 화면에 wordmark/value prop/Try Demo 보이는지 시각 확인

### 1F. Onboarding carousel hide — commit `64bccbb` (fix 완료, 검증만)

- [ ] 🙋 사인 인 → tutorial 첫 카드 send → 그 카드가 하단 carousel에서 사라짐 시각 확인
- [ ] 🙋 마지막 (3번) 카드 send → carousel 자체 사라짐 + Inbox 진입

---

## Phase 2 — Apple Developer Portal 설정

오직 사용자만 가능. Apple Developer Account 로그인 필요.

- [ ] 🙋 App ID `ai.steer.ios` 생성 (또는 기존 확인)
- [ ] 🙋 Capabilities: **Sign in with Apple** 활성화. 이거 빠지면 `error 1000` (`docs/IOS_LAUNCH_PLAN.md` 5/11 entry 참고).
- [ ] 🙋 Capabilities: **Push Notifications** 활성화
- [ ] 🙋 APNS Auth Key `.p8` 발급 — Team ID + Key ID 기록. 이미 relay env에 박혀있으면 재사용 가능.
- [ ] 🙋 App Store Distribution Provisioning Profile 새로 생성 — 이름 `Steer iOS Distribution`
- [ ] 🙋 Distribution Certificate 갱신 확인

---

## Phase 3 — App Store Connect 앱 생성

- [ ] 🙋 App Store Connect → My Apps → New iOS App
  - Bundle ID: `ai.steer.ios`
  - SKU: `STEER_IOS_001`
  - User Access: Full Access
  - Pricing: Free, all territories

---

## Phase 4 — 메타데이터 (App Store Connect 폼 채우기)

모든 텍스트는 `docs/COWORK_APP_STORE_SUBMISSION_HANDOFF.md` §2-§4에 paste-ready 형태로 준비됨. 옆에 cowork Claude 같이 끼고 한 폼씩.

### 4A. App Information

- [ ] 🙋 App Name (30자): `Steer - Agent Inbox`
- [ ] 🙋 Subtitle (30자): `Never let AI sit idle`
- [ ] 🙋 Primary Category: `Developer Tools`
- [ ] 🙋 Secondary Category: `Productivity`
- [ ] 🙋 Content Rights — 모두 본인 소유 / 라이센스 동의

### 4B. Pricing and Availability

- [ ] 🙋 Price: Free
- [ ] 🙋 Availability: All territories

### 4C. App Privacy 영양 라벨

핸드오프 §3 표 그대로:
- [ ] 🙋 Contact Info → Email Address (App Functionality, Linked Yes, Tracking No)
- [ ] 🙋 Identifiers → User ID + Device ID
- [ ] 🙋 Diagnostics → Crash data (Not Linked)
- [ ] 🙋 User Content → Other User Content (카드 텍스트, Linked Yes)
- [ ] 🙋 "Data Used to Track" → **None** (no third-party SDKs)

### 4D. App Review Information

- [ ] 🙋 First Name / Last Name / Phone / Email — 본인
- [ ] 🙋 Demo Account: **Not required** (앱은 데모 모드 내장)
- [ ] 🙋 Review Notes: 핸드오프 §4 영문 그대로 paste

### 4E. Version Information

- [ ] 🙋 Promotional Text (170자) — 핸드오프 §2.3
- [ ] 🙋 Description (4000자) — 핸드오프 §2.4
- [ ] 🙋 Keywords (100자) — 핸드오프 §2.2
- [ ] 🙋 Support URL — **결정 필요**: `mailto:` 단독은 Apple reject 가능. 임시 lander 페이지 deploy.
- [ ] 🙋 Marketing URL — `https://ilwonyoon.github.io/steer_ai/`
- [x] 🤖 Privacy Policy URL live: `https://ilwonyoon.github.io/steer_ai/privacy/`
- [ ] 🙋 Copyright: `© 2026 Superwedge Labs`

### 4F. Age Rating

- [ ] 🙋 Apple 설문 모두 None / No 답변 → Predicted **4+**
- [ ] 🙋 Unrestricted Web Access → **No** (외부 링크는 사용자 브라우저로 jump)

---

## Phase 5 — 빌드 + 업로드

### 5A. Mac에서 빌드 — **App Store .ipa 생성 완료**

- [x] 🤖 `apps/ios/ExportOptions-AppStore.plist` 작성 (method=app-store-connect, automatic signing)
- [x] 🤖 `scripts/release-ios.sh` 작성 — archive + export + 다음 단계 안내까지 한 명령에 묶음
- [x] 🤖 archive 단계 통과 (`xcodebuild archive` ARCHIVE SUCCEEDED)
- [x] 🤖 export 단계 통과 (`xcodebuild -exportArchive -allowProvisioningUpdates` EXPORT SUCCEEDED)
- [x] 🤖 Cloud-managed App Store signing 확인 — certificate `Cloud Managed Apple Distribution`, profile `iOS Team Store Provisioning Profile: ai.steer.ios`, APNS `production`
- [x] 🤖 iOS `MARKETING_VERSION` 1.0.0 설정
- [x] 🤖 iPhone-only target 설정 (`UIDeviceFamily = 1`)으로 iPad screenshot/orientation requirement 제거
- [x] 🤖 `bash scripts/release-ios.sh` → `apps/ios/build/Steer-AppStore/Steer.ipa` 생성

### 5B. App Store Connect로 업로드

- [ ] 🙋 App Store Connect API Key 발급 (Users and Access → Keys → +)
- [ ] 🙋 환경 변수 export — `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, key file `.p8` 위치 (`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`)
- [ ] 🤖 upload 명령:
  ```sh
  xcrun altool --upload-app \
    -f apps/ios/build/Steer-AppStore/Steer.ipa -t ios \
    --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID"
  ```
- [ ] 🙋 App Store Connect → TestFlight 탭 → 빌드 processing 끝 대기 (5-30분)

### 5C. Build metadata

- [ ] 🙋 Build → Test Information → Beta App Review Information 채우기 (Email + Privacy URL)
- [ ] 🙋 Encryption Compliance: 빌드별 답변. Steer는 HTTPS만 쓰므로 "Yes - exempt" (5D2 카테고리)

---

## Phase 6 — Screenshots

핸드오프 §5.5의 6장 골든 셋. 사이즈:

- [ ] 🤖 iPhone 6.9" (1260 × 2736, 1290 × 2796, 또는 1320 × 2868) — 필수, 3-10장. 6장 권장.
- [ ] 🤖 iPhone 6.5" (1284 × 2778 또는 1242 × 2688) — 6.9" 세트 제공 시 선택. 미제공 시 App Store Connect가 6.9" 세트를 scale down.
- [ ] 🙋 iPad 13" — Steer 미지원 시 skip 가능 (App Store가 자동으로 iPhone 스크린샷 사용)

촬영 방법 (자동화 candidate):

- [ ] 🤖 `xcrun simctl status_bar override` — status bar를 9:41 / 100% / WiFi full로 통일
- [ ] 🤖 시뮬레이터 6.9" (`iPhone 17 Pro Max`) 부팅, golden state seed (demo mode + 카드 1장 prefab)
- [ ] 🤖 6장 화면 캡처 — XCUITest로 자동화 또는 `xcrun simctl io booted screenshot`
- [ ] 🙋 캡처 결과 시각 검수 — 픽셀 깨짐, 텍스트 truncate, 알림 mockup 진짜 알림인지 확인 (App Store Review 2.3.3)

촬영 대상 6장:
1. SignInPrompt (앱 아이콘 + 워드마크 + Apple 버튼 + RoutingFieldView)
2. Onboarding 카드 1 (text streaming 중간)
3. Inbox에 카드 (`.connected` 상태)
4. Reply flow (ReplyDock open)
5. Empty state `.connected` ("No waiting actions")
6. Settings (Notifications toggle + GitHub mark + 링크)

---

## Phase 7 — Legal pages

- [ ] 🙋 `chore/legal-site-pages` worktree PR 머지 → Cloudflare Pages auto-deploy
- [x] 🤖 GitHub Pages enabled from `fix/mac-chip-reconciliation` `/docs`
- [x] 🤖 `https://ilwonyoon.github.io/steer_ai/privacy/` 200 응답 확인
- [x] 🤖 `https://ilwonyoon.github.io/steer_ai/terms/` 200 응답 확인
- [x] 🤖 `https://ilwonyoon.github.io/steer_ai/support/` 200 응답 확인
- [ ] 🙋 (선택) `steer.ai` 도메인에 minimal lander deploy

---

## Phase 8 — TestFlight

- [ ] 🙋 Internal Testers: 본인 Apple ID 추가
- [ ] 🙋 빌드 install via TestFlight app → §9 골든 셋 모두 수동 검증
- [ ] (선택) 🙋 External Testing 그룹 만들기 + Beta App Review 통과 → 5-10명 베타 테스터 초대 (Reddit / X / 친구)
- [ ] (선택) 🙋 베타 피드백 수집 1-2주 → critical 수정 → 새 빌드 archive → 반복

---

## Phase 9 — Submission 직전 골든 셋

사용자가 손수 한 번 더. 핸드오프 §6 그대로.

- [ ] 🙋 Launch → SignInPrompt에 Steer 앱 아이콘 (84pt) 보임
- [ ] 🙋 Sign in with Apple (real Apple ID) → Onboarding 카드 character streaming
- [ ] 🙋 Send 시 그 카드가 carousel에서 빠짐
- [ ] 🙋 마지막 카드 send → carousel 사라짐 + Inbox 진입
- [ ] 🙋 Mac 미페어링 상태 → "Set Up Mac" + "Try Demo" 둘 다
- [ ] 🙋 `.offline` / `.error` empty state엔 버튼 없음
- [ ] 🙋 Settings → Identity 행에 displayName 표시
- [ ] 🙋 Settings → Notifications toggle 가능, granted → deeplink
- [ ] 🙋 Settings → Report an Issue → GitHub 마크
- [ ] 🙋 Settings → Privacy → `ilwonyoon.github.io/steer_ai/privacy/` 200
- [ ] 🙋 Settings → Support → `ilwonyoon.github.io/steer_ai/support/` 200
- [ ] 🙋 Sign out → Mac 측 iPhone dot 60s 안에 사라짐
- [ ] 🙋 새 카드 (Mac codex stop) → iPhone lock screen banner + badge
- [ ] 🙋 두번째 카드 동일 → 알림 다시 옴 (Phase 1C regression 검증)
- [ ] 🙋 Delete Account → 즉시 sign out

---

## Phase 10 — Submit for Review

- [ ] 🙋 모든 §9 항목 그린 확인
- [ ] 🙋 App Store Connect → Version 선택 → "Submit for Review"
- [ ] 🙋 Export Compliance / Content Rights / Advertising Identifier 답변
- [ ] 🙋 Submit 클릭

리뷰는 보통 24-72시간. Reject 받으면 핸드오프 §7 (알려진 reject 위험) 참고.

---

## Phase 11 — Post-submission

리뷰 통과 후:

- [ ] 🙋 Phased Release (선택) 또는 Manual Release
- [ ] 🙋 출시 발표 (X, Reddit r/SwiftUI, Hacker News Show HN)
- [ ] 🙋 첫 사용자 피드백 수집 (App Store Connect → Ratings & Reviews)

---

## Open decisions (Submit 전 답해야 함)

핸드오프 §7 / `docs/APP_STORE_LAUNCH_RUNBOOK.md`의 "Decisions waiting on user"에서 그대로 가져온 미결 항목:

- [x] **Demo mode 진입 경로** — signed-out SignInPrompt에 `"Try Demo"` 복원. Mac 페어링 이후 replay/tutorial 진입은 v1.1 후보.
- [ ] **NSE (Notification Service Extension)** — 카드 페이로드의 `cardIcon` 키를 진짜 lock screen 알림에 표시하려면 NSE 필요. 출시 차단은 아니나 polish. task #279. 출시 후 v1.1로?
- [ ] **Custom Terms vs Apple standard EULA** — 현재 `docs/legal/TERMS_OF_SERVICE.md`가 자체 작성. 그대로 가도 OK이나 Apple standard EULA로 대체하면 polish 적게 든다. 결정 후 App Store Connect 폼.
- [x] **Support URL** — `https://ilwonyoon.github.io/steer_ai/support/` 200 확인.

---

## 진행 상태 (자가 확인용 라이브 마커)

이 섹션은 진행하면서 한 줄씩 갱신. 마지막 갱신 시점 = 마지막 작업 끝났을 때.

- 2026-05-13 (latest): App Store `.ipa` created at `apps/ios/build/Steer-AppStore/Steer.ipa`; upload blocked only on App Store Connect API key env/file.
- 2026-05-13: origin head `2e785dd`. G14 integration gate 130/130, iOS simulator build green, GoldenFlowUITests 4/4.
- 2026-05-13: Phase 1A 코드 정상 (시각 검증만 대기), 1B 코드 fix 완료 + dogfood 대기, 1C-1F 코드 fix 완료 + 시각 검증 대기.
- 2026-05-13: Phase 5A archive 단계 smoke-passed. ExportOptions plist + `scripts/release-ios.sh` 준비됨. Distribution profile 만들어지면 export 자동 진행.
- 2026-05-13: Phase 6 `scripts/capture-app-store-screenshots.sh` 작성. iPhone 17 Pro Max / iPhone 17 부팅 + 빌드 + 인스톨까지 smoke-passed. 인터랙티브 캡처 루프 6장.

---

## Quick navigation

- 깊은 메타데이터 / 영문 카피 → `docs/COWORK_APP_STORE_SUBMISSION_HANDOFF.md`
- 아이콘 진단 → `docs/ICON_FIX_DIAGNOSIS_2026-05-13.md` + `docs/ICON_FIX_PLAN.md`
- wrapper disconnect 진단 → `docs/WRAPPER_DISCONNECT_DIAGNOSIS_2026-05-13.md`
- 프로필 / 이름 연구 → `docs/SETTINGS_PROFILE_RESEARCH_2026-05-13.md`
- 법적 검토 → `docs/legal/LAUNCH_LEGAL_CHECKLIST.md`
- App Review notes (영문) → `docs/legal/APP_REVIEW_NOTES.md`
- 영양 라벨 (영문) → `docs/legal/APP_STORE_PRIVACY_LABELS.md`
- 기존 runbook → `docs/APP_STORE_LAUNCH_RUNBOOK.md`
- 기존 launch plan → `docs/IOS_LAUNCH_PLAN.md`
