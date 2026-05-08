# Settings & Remaining Mac UX Plan

목적: dogfood 시작 전·중에 사용자 워크플로우에 맞게 조정 가능한 설정 항목과,
아직 Mac 앱에서 마무리 못 한 UX 다듬기 항목을 한 곳에 정리.

## Phase 1 — 즉시 만들 것 (dogfood 시작 막기 항목)

### 1.1 알림 (가장 거슬리는 영역)
- [x] 알림 on/off 전역 토글
- [x] 사운드 on/off
- [x] 카테고리별 알림 (blocker / question / decision / waiting 각각 토글)
- [x] 방해금지 시간대 (22:00–08:00 같은 범위)

UserDefaults 키 예시:
- `steer.notifications.enabled` (Bool, default true)
- `steer.notifications.sound` (Bool, default true)
- `steer.notifications.categories` ([String], default 모든 카테고리)
- `steer.notifications.dndStart` / `steer.notifications.dndEnd` (TimeOfDay)

### 1.2 윈도우 동작
- [x] Always on top (NSWindow.level = .floating)
- [x] Run at login (SMAppService.mainApp)

### 1.3 Settings UI ✅
- macOS 표준 Settings scene + Cmd+, 단축키 ✓
- 그룹: General / Notifications / About ✓
- About: 버전, 빌드 번호, ~/.steer 경로, "Open log" 버튼 ✓
- 메뉴바 메뉴에 Settings… / Open agent log 항목 ✓

## Phase 2 — Dogfood 1주 후 결정할 것

이 항목들은 1주일 써본 뒤 진짜 필요한지 판단:
- [ ] 윈도우 크기 조절 가능 (현재 fixed 375×812)
- [ ] 카드 본문 폰트 크기 슬라이더
- [ ] cwd 색상 강도 / 색상 비활성화
- [ ] 다크/라이트 강제 (시스템 따르지 않기)
- [ ] PTY idle heuristic on/off (codex는 reader가 우선, fallback)
- [ ] Claude hook 자동 설치 동작 끄기
- [ ] 데이터 보관 기간 (30/60/90일)
- [ ] stats 자동 export to DOGFOOD_NOTES.md
- [ ] Reset DB 버튼

## Phase 3 — iOS 페어링 작업 시작 시 정해야 할 것

핸드폰 앱 만들기 시작하기 전 결정 필요:
- [ ] 동기화 백엔드: CloudKit vs Mac helper + 자체 sync vs 클라우드 함수
- [ ] 무엇이 동기화되는가: 카드 + 응답만 / transcript 전체 / instruction
- [ ] Mac helper 백그라운드 상시 실행 vs 앱 켜져있을 때만
- [ ] iPhone → Mac instruction 주입 경로 (CloudKit notification → Mac이 wrapper에 forward?)
- [ ] 페어링 UX (QR / 코드 / iCloud 자동)
- [ ] 어떤 데이터가 클라우드에 올라가는지 사용자 동의

이건 별도 RFC 문서 (`docs/SYNC_RFC.md`) 후보. 지금 미리 결정하지 말고
dogfood 결과로 "iOS 가는 게 맞다"는 신호가 분명해진 뒤 시작.

## 미해결 Mac UX (Phase 1과 함께 마무리)

dogfood 가기 전 정리해두면 좋은 것:
- [ ] reply 박스가 multi-line 시 위로 자라는 동작 검증
- [ ] 권한 팝업 영구 해결 검증 (Info.plist + tccutil)
- [ ] EmptyState에서도 RunningBadge 보이는지 검증 (방금 수정)
- [ ] 캐러셀 carousel scroll snap (compact 카드 사이 미세 정렬)
- [ ] Notification 클릭 시 해당 sessionId 카드로 점프 (지금은 앱 활성화만)
- [ ] codex_session_reader가 절대 다른 codex jsonl 잡지 않는지 stress test
- [ ] wrapper 강제 종료(Ctrl+C/SIGKILL) 시 카드/세션 cleanup 통합 테스트
- [ ] "최신 카드 점프" 단축키 (Cmd+Shift+Home 같은)
- [ ] 메뉴바 메뉴에 "Open Settings" / "Open log" 추가

## Out of scope (지금 넣지 말 것)

명확히 v1 아님:
- 카드 검색 / 필터
- 다중 사용자 / 계정
- 외부 LLM 통합 (gemini는 PRD에 나왔지만 v1.5)
- 세션 export / share
- 카드 thread (대화 history, 지금은 메시지 1개만)
- 통계 대시보드 (steer stats CLI로 충분)

## 진행 원칙

- Settings는 **있으면 좋은 것**이지 **dogfood 막는 것**이 아님 → Phase 1만 먼저, 나머지 거품
- 모든 설정은 UserDefaults 기반 + 코드에서 reasonable default. 설정 파일 직접 편집 안 시킴
- iOS 가기 전엔 Mac이 단독으로 깨지지 않게. 그게 sync 신뢰성의 기반
