# Icon Fix — 진단 결과 (2026-05-13 새벽)

## TL;DR

사용자: "아이콘 안 들어간 것 해결해야지" — 자기 전 부탁.

**자동으로 진행 못함.** 두 가지 위험이 겹쳐 보수적으로 stop:

1. `origin/fix/notification-icons` 브랜치의 마지막 fix commit (`123051c`) 메시지는 4영역 수정을 약속하지만 실제 diff는 `scripts/build-mac-app.sh` 1파일 6줄만 들어있음. iOS @2x/@3x PNG + `ActionNotificationService.swift` attachment + `claude.imageset/codex-color.imageset` Contents.json 변경 모두 누락.
2. 누락된 변경을 추측으로 작성하면 시각 검증 없이 push되어 다음 dogfood build 부서질 위험. 카파시 룰 #1 (think before coding) 위배.

## 무엇이 실제 상태인지

- `apps/ios/SteerIOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` — 1024×1024 PNG, 305KB. 정상.
- `apps/mac/Resources/AppIcon.icns` — 1.9MB icns. 정상.
- `claude.imageset/Contents.json`, `codex-color.imageset/Contents.json` — 1x slot에만 PNG 채움 (`@2x`/`@3x` filename은 선언되었으나 파일은 없음으로 추정). plan doc은 이게 issue라고 명시.
- `ActionNotificationService.swift` — `content.attachments` 안 채움 (plan doc).
- `scripts/build-mac-app.sh` — `CFBundleIconName` 키 누락 (plan doc; 이 변경은 `123051c`에 실제로 들어가있음).

## 깨어난 후 사용자가 할 일 (순서대로)

### Step 1 — 시각 확인

dogfood Mac + iPhone에서 *진짜로* 어디서 icon이 안 보이는지 확인:

- Mac Dock / Finder Get Info / Notification Center
- iPhone Home Screen / Settings 앱 안의 Steer 아이콘 / Notification banner
- iPhone 카드 안의 ProviderMark (claude.png / codex-color.png) — 흐릿한가?

각각이 fail하면 어느 영역(1/2/3/4)인지 정확히 짚어주면 거기만 surgical fix.

### Step 2 — `fix/notification-icons` 보존된 변경 복원

`docs/ICON_FIX_PLAN.md` 의 "재개 시 명령" 참고. plan은 stash에서 복원하라 했는데 현재 stash 비어있음. 즉:

- iOS @2x/@3x PNG 자산: plan doc의 sips 명령 (line 60-72) 그대로 실행하면 재생성됨
- `ActionNotificationService.swift` attachment 코드: plan 문서에 패치 본문이 없으니 직접 작성 필요. 카드 알림 + 임시 디렉토리 복사 + provider 메모이즈 패턴이 spec.

### Step 3 — 검증

```sh
# iOS asset catalog @1x/@2x/@3x 확인
xcrun assetutil --info apps/ios/build/.../Steer.app/Assets.car \
  | grep -A1 '"Name" : "claude"'
# 1x/2x/3x 세 번 등장해야 함

# Mac .app 안 icon embed
plutil -p .build/Steer.app/Contents/Info.plist | grep -i icon
# CFBundleIconName + CFBundleIconFile 둘 다 있어야 함
```

### Step 4 — 사용자 시각 확인 (다시)

빌드 → install → step 1과 같은 위치들 다시 확인.

## 왜 이번에 자동으로 안 함

- icon 자산은 시각 검증 필수 — code path만 들여다봐서는 "보인다 vs 안 보인다" 답 안 나옴
- `fix/notification-icons` 브랜치 자체가 broken commit이라 cherry-pick으로 끝낼 수 없음
- 추측으로 PNG 만들거나 swift 코드 작성하면 다음 dogfood가 부서질 위험
- 사용자가 골든셋 검증 owner — 시각 결과는 사용자만 가능
