# Icon Audit — 알림 + UI 아이콘 누락 진단

브랜치: `diag/notification-icons` (main에서 컷)
작성: 2026-05-11

## TL;DR

| 영역 | 상태 | 원인 |
|---|---|---|
| **iOS 푸시 알림 아이콘** | ❌ 안 뜸 | APNS payload에 `mutable-content` + Notification Service Extension 없음. iOS는 *기본적으로 알림에 앱 아이콘을 안 그림* — 첨부로 명시 전달해야 함 |
| **Mac 로컬 알림 아이콘** | ❌ 안 뜸 / 흐릿 | `UNNotificationContent.attachments` 미설정. macOS는 앱 아이콘 fallback을 *최근 빌드에서만* 잘 그림. ad-hoc 서명 + dogfood 빌드에서는 LaunchServices가 아이콘 캐시 못 만들어 누락 가능 |
| **Mac 카드의 provider 아이콘** | ✅ 정상 | `Bundle.module`로 PNG 로드 — claude.png/codex-color.png 둘 다 `SteerMac_SteerMac.bundle`에 포함 |
| **iOS 카드의 provider 아이콘** | ⚠️ Retina 흐릿 | imageset에 1x PNG만 있고 2x/3x slot은 비어있음. iPhone(3x)/iPad(2x)에서 1x를 stretch → 흐림 |
| **iOS AppIcon (홈스크린/Spotlight)** | ⚠️ 부분 누락 | appiconset에 1024×1024 한 장만 있음. Xcode가 "single-size" 모드로 처리하긴 하지만 일부 컨텍스트에서 사이즈가 맞지 않음 |
| **Mac AppIcon (Dock/Finder/알림 fallback)** | ✅ 정상 | `AppIcon.icns`에 모든 사이즈 chunk(ic04~ic14) 다 있음. `CFBundleIconFile = AppIcon` 박혀 있음 |

핵심: **알림이 안 뜨는 건 자산 부재가 아니라 알림 첨부 미설정**. 카드 아이콘이 흐릿한 건 **iOS asset catalog가 scale 변종을 빼먹어서**.

---

## 1. iOS 푸시 알림 — 가장 큰 문제

### 증상
디바이스에 푸시가 도착하면 텍스트만 보이고 우측 상단에 회색 사각형(또는 SteerIOS 앱의 작은 AppIcon)이 보일 뿐, 카드 컨텐츠와 어울리는 provider 아이콘(Claude/Codex 마크)이 안 뜸.

### 원인
**파일:** `packages/relay/src/apns.ts:78-121`

```ts
// apns.ts:89-92
const aps: Record<string, unknown> = {
  alert: { title: req.title, body: req.body },
  sound: "default",
};
```

- `mutable-content: 1` flag 없음
- `apns-push-type` 는 `"alert"` 만 (정상이지만 첨부 활용 불가)
- payload에 이미지 URL/식별자 없음

iOS 알림은 다음 중 하나가 필요합니다:
1. **Notification Service Extension** 타겟 — `mutable-content: 1` 받으면 payload에서 URL 꺼내 이미지 다운로드 → `UNNotificationAttachment` 부착 → 알림에 인라인 표시
2. 또는 앱 측에서 **`UNNotificationCategory`** + locally-bundled image identifier

현재 SteerIOS 프로젝트:
- Notification Service Extension 타겟 **없음** (`apps/ios/Steer.xcodeproj/project.pbxproj` 확인 — `Steer` 단일 앱 타겟만 존재)
- `apps/ios/SteerIOS/` 폴더에 `UNUserNotificationCenter` 호출 코드 자체가 **없음** (`grep -rn "UNUserNotification\|registerForRemoteNotifications" apps/ios/` 결과 비어있음)

### 그래서 정확히 어떻게 빠진 건가
1. APNS payload 단에서 첨부 metadata 없이 발사
2. 클라이언트 측에 NSE도 없어서 받아서 가공할 수도 없음
3. 결국 iOS 시스템은 그냥 텍스트만 그리고 앱 AppIcon은 *왼쪽 위*(badge용 작은 영역)에만 fallback 표시
4. AppIcon 자체도 1024×1024 한 장만 있어서 시스템이 작은 사이즈로 다운스케일 (1.b 참조)

### 어떻게 넣어야 하나 (수정 방향 — 진단만, 구현은 별도 PR)
**옵션 A — Notification Service Extension 추가 (정공법)**
- 새 타겟 `SteerNotificationService` 추가 (Xcode: New Target → Notification Service Extension)
- `didReceive(_:withContentHandler:)` 에서 payload의 `card-icon-url` (또는 provider key) 읽어서 이미지 다운로드 → 임시파일 → `UNNotificationAttachment(identifier:url:options:)` → `content.attachments = [att]`
- Worker(`apns.ts`) 측에서 `mutable-content: 1`, payload에 `cardIcon: "claude" | "codex"` 또는 직접 URL 포함
- 이미지는 R2 + CDN으로 호스팅하거나, 앱이 미리 캐시 (provider 아이콘은 두 종류뿐이라 앱 번들에 PNG 두면 NSE 다운로드 불필요)

**옵션 B — 카테고리 매칭 (간단하지만 제한적)**
- iOS 15+ `UNNotificationContent.targetContentIdentifier` 로는 아이콘 못 바꿈
- 알림 자체 아이콘은 옵션 A 가야 함

### 곁들여 — APNS 자체가 도달하는지
사용자 보고는 "아이콘이 안 들어가 있는 이슈" — 본문/제목은 보이는 듯합니다. 그렇다면 APNS 전송과 인증은 동작 중이고, *비주얼 표현만 빠진* 상태로 진단됨.

---

## 2. Mac 로컬 알림 — 두 번째 문제

### 증상
Mac 알림센터에 알림이 뜨면 좌측에 Steer AppIcon이 있어야 하는데 회색 박스만 나오거나, 일부 경우 아예 아이콘이 빠짐.

### 원인
**파일:** `apps/mac/Sources/SteerMac/ActionNotificationService.swift:28-43`

```swift
let content = UNMutableNotificationContent()
content.title = card.title
content.body = card.summary
content.sound = SteerSettings.shared.soundEnabled ? .default : nil
content.userInfo = [...]
// content.attachments = []   ← 빠져 있음
```

Mac 알림 아이콘 동작:
1. **앱 번들 AppIcon** 이 LaunchServices에 등록되면 → 알림 좌측 큰 아이콘에 자동 fallback
2. `attachments` 에 image 넣으면 → 그게 우측에 큰 썸네일로 보임 (좌측 작은 아이콘은 여전히 AppIcon)

지금 빌드 상태:
- `.build/SteerMac.app/Contents/Resources/AppIcon.icns` 존재 ✅
- `Info.plist` 에 `CFBundleIconFile = AppIcon` 있음 ✅ (`build-mac-app.sh:89-94`)
- icns 내부 chunk 모두 존재: ic04(16x16), ic05(32x32), ic07(128x128), ic08(256x256), ic09(512x512), ic10(1024x1024@2x), ic11~ic14(Retina) ✅
- **`CFBundleIconName`** 없음 ⚠️ — macOS 11+ Big Sur 이후로 권장 키. `CFBundleIconFile`만 있어도 동작하지만, 일부 SwiftUI 시스템 컨텍스트에서는 `CFBundleIconName` 기반의 .xcassets 컴파일된 AppIcon만 인식

### 그래서 정확히 어떻게 빠진 건가
가설 순서:
1. **LaunchServices 캐시 stale** — ad-hoc 서명된 dogfood 빌드(`build-mac-app.sh`)를 같은 bundle id로 여러 번 덮어쓰면 LaunchServices가 아이콘을 다시 안 읽는 경우 있음. `lsregister -f` 로 강제 갱신 필요
2. **`CFBundleIconName` 부재** — Big Sur 이후 시스템 알림 UI는 .xcassets에서 컴파일된 `Assets.car` 안의 `AppIcon` 그룹을 우선 찾음. 우리는 SwiftPM 빌드라 .xcassets 컴파일이 안 일어남 → `AppIcon.icns` 만 있음. 대부분의 경우 `CFBundleIconFile` fallback이 동작하지만, 알림센터의 특정 렌더 경로는 `CFBundleIconName` + `Assets.car` 만 본다는 보고가 있음
3. **`attachments` 비어있음** — 첨부를 명시하면 시스템 fallback에 의존하지 않고 확정적으로 카드별 아이콘 표시 가능 (provider 아이콘을 좌측 큰 아이콘 자리에 넣으려면 옵션 B)

### 어떻게 넣어야 하나
**최소 수정 (앱 아이콘만 확실히 보이게):**
1. `build-mac-app.sh` Info.plist 생성부에 `CFBundleIconName = AppIcon` 추가
2. 빌드 후 `/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister -f .build/SteerMac.app` 실행 → 캐시 갱신
3. 정확히 확인: `mdls -name kMDItemDisplayName -name kMDItemKind .build/SteerMac.app` 로 LaunchServices가 번들 인식했는지 확인

**카드별 아이콘까지 넣고 싶다 (옵션):**
- `ActionNotificationService.swift` 에서 provider 아이콘 PNG를 임시 디렉토리에 복사 후 `UNNotificationAttachment(identifier:url:options:)` 생성, `content.attachments = [att]`
- iOS와 같은 구조로 통일 가능

---

## 3. iOS 카드 provider 아이콘 — Retina 흐림

### 증상
앱 내 카드 헤더의 Claude/Codex 마크가 iPhone(3x) / iPad(2x)에서 흐릿하게 보임 (또는 fallback 알파벳 배지로 떨어짐).

### 원인
**파일:** `apps/ios/SteerIOS/Assets.xcassets/claude.imageset/Contents.json`

```json
"images" : [
  { "filename" : "claude.png", "idiom" : "universal", "scale" : "1x" },
  { "idiom" : "universal", "scale" : "2x" },     ← filename 없음
  { "idiom" : "universal", "scale" : "3x" }      ← filename 없음
]
```

- 컴파일된 `Assets.car` 검증 결과: claude는 `PixelWidth: 512, Scale: 1` 만 존재 (`xcrun assetutil --info` 출력)
- codex-color도 동일

### 그래서 정확히 어떻게 빠진 건가
1. PNG 원본은 512x512(claude) / 640x640(codex) — 충분히 큰데 1x scale로만 등록됨
2. SwiftUI `UIImage(named: "claude")` → 1x 이미지 반환 → `.scaledToFill()` 로 24pt 프레임에 stretch
3. 3x device에서는 24pt = 72px이 필요한데 실제 데이터는 512px → 다운스케일링은 OK지만 imageset 메타데이터가 1x라서 시스템이 *3x slot이 없다*고 판단, 일부 컨텍스트(미리보기, contextual menu 썸네일 등)에서 fallback 동작

### 어떻게 넣어야 하나
**옵션 A — scale 변종 PNG 생성**
- claude.png → claude@2x.png(1024), claude@3x.png(1536) 추가
- imageset Contents.json의 빈 slot에 filename 채움

**옵션 B — single-size로 명시 (PDF/SVG 처럼 취급)**
- imageset Contents.json에서 2x/3x slot 제거하고 1x만 남김 → Xcode가 "single scale" mode로 처리
- 또는 `"properties": { "preserves-vector-representation": true }` (SVG일 경우)

**옵션 C — PDF/SVG 자산으로 교체**
- 백터 자원이면 모든 스케일에서 선명

---

## 4. iOS AppIcon — 단일 사이즈

### 증상
홈스크린/Spotlight/Settings 등 일부 iOS 시스템 컨텍스트에서 앱 아이콘이 다운스케일로 흐릿하게 보일 수 있음.

### 원인
**파일:** `apps/ios/SteerIOS/Assets.xcassets/AppIcon.appiconset/Contents.json`

```json
"images" : [
  {
    "filename" : "AppIcon-1024.png",
    "idiom" : "universal",
    "platform" : "ios",
    "size" : "1024x1024"
  }
]
```

- 이건 사실 iOS 17+ 의 "single-size AppIcon" 방식 (Xcode가 자동으로 모든 사이즈 생성)
- 컴파일된 `Assets.car` 보면 `AppIcon-1024.png` 하나만 들어있고, 빌드 산출물 `Steer.app/AppIcon60x60@2x.png`, `AppIcon76x76@2x~ipad.png` 가 별도로 추출됨
- Info.plist에 `CFBundleIconName = AppIcon` 정상 ✅

### 평가
**거의 정상**. iOS 17부터 단일 1024 자산만 있어도 시스템이 알아서 다운스케일. 단:
- 알림 좌측 작은 아이콘은 시스템이 1024를 60pt @2x = 120px로 압축 — 약간 흐릴 수 있으나 무시 가능
- 만약 더 선명하게 하고 싶다면 imageset에 60x60@2x, 60x60@3x 등 명시 (옛 방식)

---

## 5. Mac AppIcon — 정상

- `apps/mac/Resources/AppIcon.icns` (1.9 MB)
- icns chunk 점검: ic04, ic05, ic07, ic08, ic09, ic10, ic11, ic12, ic13, ic14 모두 존재
- `build-mac-app.sh:89-94` 가 Info.plist 동적 생성 시 `CFBundleIconFile = AppIcon` 박음

**개선 여지:** `CFBundleIconName` 키 추가 → 일부 macOS 알림 UI 코드 패스가 그것만 본다는 추정

---

## 6. 기타 — Mac 카드 provider 아이콘 (✅ 정상)

**파일:** `apps/mac/Sources/SteerMac/ActionCardView.swift:101-104`

```swift
if let iconName = provider.iconName,
   let url = Bundle.module.url(forResource: iconName, withExtension: "png"),
   let image = NSImage(contentsOf: url) {
    Image(nsImage: image)
```

- `apps/mac/Sources/SteerMac/Resources/claude.png`, `codex-color.png` 존재
- SwiftPM이 `SteerMac_SteerMac.bundle` 로 패키징
- `build-mac-app.sh:76-79` 가 그 bundle을 `.app/Contents/Resources/` 로 복사
- `Bundle.module` 이 런타임에 정상 resolve

이쪽은 진단 결과 문제 없음.

---

## 7. 메뉴바 아이콘 (✅ 정상)

`apps/mac/Sources/SteerMac/SteerAppDelegate.swift:138-179` — `MenuBarIcon.png`, `@2x.png`, `@3x.png` 다 있음. 리소스 등록도 정상.

---

## 우선순위

리스크 vs 임팩트로 정렬:

1. **🔥 iOS 푸시 알림 아이콘** (`packages/relay/src/apns.ts` + 새 NSE 타겟) — 사용자에게 가장 잘 보이는 문제. NSE 새 타겟 추가 + Worker payload 수정 필요. 코드 양은 많지 않지만 Xcode 프로젝트 변경 필요
2. **🟡 Mac 로컬 알림 아이콘** (`ActionNotificationService.swift` 또는 `build-mac-app.sh` Info.plist 보강) — 두 갈래 접근 가능. 빠르게 시도해볼 건 `CFBundleIconName` 추가 + `lsregister -f`
3. **🟢 iOS 카드 provider 아이콘** (`Assets.xcassets/*.imageset/Contents.json`) — 단순 자산 작업. @2x/@3x PNG 생성하거나 single-scale 모드로 명시
4. **⚪ iOS AppIcon 다중 사이즈** — 거의 보일까 말까 한 차이. 우선순위 낮음

각 항목은 별도 PR로 가는 게 안전:
- PR1: relay APNS payload + iOS NSE 추가 (구조 변경)
- PR2: Mac Info.plist 보강 + ActionNotificationService 첨부 (Mac side)
- PR3: iOS asset catalog 정리 (단순 자산)

---

## 검증 방법 (수정 후)

| 항목 | 검증 |
|---|---|
| iOS 푸시 | TestFlight 또는 사이드로드된 iPhone에서 카드 publish → 알림 우측 상단에 provider 아이콘 보임 |
| Mac 알림 | `xcrun simctl push` 흉내 안 됨. 실제 카드 발생시키거나 `osascript -e 'display notification "..." with title "Steer"'` 와 비교 → 좌측에 Steer 앱 아이콘 |
| iOS 카드 | iPhone 14 Pro(3x) 시뮬레이터에서 카드 헤더 zoom → 픽셀 또렷 |
| Mac AppIcon | `/usr/bin/qlmanage -p .build/SteerMac.app` → QuickLook이 1024 아이콘 그림. Finder Get Info에서도 동일 |

---

## 진단에서 *건드리지* 않은 것

- 코드 수정은 *없음*. 이 PR(`diag/notification-icons`)은 docs/ICON_AUDIT.md 추가만
- sync-v2 작업과 독립. `design/sync-v2` 의 WIP 커밋에는 영향 없음
- 실제 fix는 위 우선순위대로 별도 브랜치/PR
