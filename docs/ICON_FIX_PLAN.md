# Icon Fix Plan — 실행 문서

브랜치: `fix/notification-icons` (main에서 컷)
연관: [`docs/ICON_AUDIT.md`](./ICON_AUDIT.md) — 진단 보고서
상태: **대기 중 — main 정리 후 재개**

## 왜 지금 보류하나

진단 후 4개 영역을 고치려고 시작했는데 동시에 진행 중인 `design/sync-v2` 작업과 **충돌 위험**이 발견됐다:

- `apps/ios/Steer.xcodeproj/project.pbxproj` 가 sync-v2(파일 추가) 와 NSE(타겟 추가) 둘 다 건드리는 영역 → pbxproj 머지 충돌은 텍스트 diff로 안전하게 못 풀고 Xcode 열어서 손봐야 한다
- `packages/relay/src/*` 에 sync-v2 WIP 변경 + APNS payload 변경이 같이 가면 어느 변경이 깨졌는지 식별이 어렵다
- iOS Swift 파일들(`InboxView.swift`, `SyncInbox.swift`, `ActionCardView.swift`)에 sync-v2가 LoadPhase 로직을 추가하고 있다

**그래서 결정:** sync-v2 가 main 으로 머지되어 깨끗해진 후에 이 작업을 재개한다. 그동안 이 문서가 *재개 시점에 0초로 시작*할 수 있는 단일 진실 출처.

---

## 재개 시 명령

```sh
# 1. main 이 깨끗한지 확인 (sync-v2 머지 끝났는지)
git checkout main && git pull && git log --oneline -10

# 2. 이 브랜치로 돌아오고 main 위로 rebase
git checkout fix/notification-icons
git rebase main

# 3. 보관해둔 코드 변경 복원
git stash list  # "icon-fix-code-staged" 가 보여야 함
git stash pop stash@{0}  # 또는 정확한 인덱스

# 4. 충돌 확인 후 빌드 검증
swift build --package-path apps/mac
xcodebuild -project apps/ios/Steer.xcodeproj -scheme Steer \
  -destination 'generic/platform=iOS' build
```

**경고:** stash가 두 개 이상이라면 `git stash list` 결과를 잘 보고 "icon-fix-code-staged" 라벨이 붙은 것만 pop. `sync-v2-spillover` 라벨이 붙은 다른 stash는 이 작업과 무관 (sync-v2 누락분).

---

## 변경할 4영역 (우선순위 순)

### 1️⃣ iOS asset catalog @2x/@3x (✅ 코드 stash 에 준비됨)

**문제:** `claude.imageset` / `codex-color.imageset` 의 Contents.json 이 1x slot만 채움. 빌드된 Assets.car 에 1x 만 들어가 있어 3x 디바이스에서 흐림.

**파일:**
- `apps/ios/SteerIOS/Assets.xcassets/claude.imageset/Contents.json` — 2x/3x slot의 filename 채움
- `apps/ios/SteerIOS/Assets.xcassets/claude.imageset/claude@2x.png` — 신규(48×48, 원본 512에서 다운스케일)
- `apps/ios/SteerIOS/Assets.xcassets/claude.imageset/claude@3x.png` — 신규(72×72)
- `apps/ios/SteerIOS/Assets.xcassets/codex-color.imageset/Contents.json` — 동일
- `apps/ios/SteerIOS/Assets.xcassets/codex-color.imageset/codex-color@2x.png` — 신규
- `apps/ios/SteerIOS/Assets.xcassets/codex-color.imageset/codex-color@3x.png` — 신규

**스케일 근거:** 카드 헤더 ProviderMark 최대 사용 사이즈 24pt → 3x 디바이스 72px. 14pt 작은 사용도 있으나 72px 자산으로 다운스케일 가능. 알림용 큰 자산은 NSE에서 별도 처리(섹션 4).

**생성 명령 (재현 가능):**
```sh
cd apps/ios/SteerIOS/Assets.xcassets/claude.imageset
sips -z 24 24 claude.png --out /tmp/claude_24.png > /dev/null
sips -z 48 48 claude.png --out claude@2x.png > /dev/null
sips -z 72 72 claude.png --out claude@3x.png > /dev/null
mv /tmp/claude_24.png claude.png

cd ../codex-color.imageset
sips -z 24 24 codex-color.png --out /tmp/codex_24.png > /dev/null
sips -z 48 48 codex-color.png --out codex-color@2x.png > /dev/null
sips -z 72 72 codex-color.png --out codex-color@3x.png > /dev/null
mv /tmp/codex_24.png codex-color.png
```

**검증:**
```sh
xcodebuild -project apps/ios/Steer.xcodeproj -scheme Steer \
  -destination 'generic/platform=iOS' build
xcrun assetutil --info \
  apps/ios/build/DerivedData/Build/Products/Debug-iphoneos/Steer.app/Assets.car \
  | grep -A1 '"Name" : "claude"' | head -10
# claude 가 1x/2x/3x 세 번 등장해야 함
```

---

### 2️⃣ Mac 알림 첨부 + Info.plist CFBundleIconName (✅ 코드 stash 에 준비됨)

**문제:**
- `ActionNotificationService.swift` 가 `content.attachments` 를 안 채워서 알림에 provider 아이콘이 안 박힘
- `build-mac-app.sh` 생성 Info.plist 에 `CFBundleIconName` 키가 없음 (CFBundleIconFile 만) → 일부 macOS 알림 렌더 경로에서 앱 아이콘 fallback이 누락될 수 있음

**파일 + 변경:**

A) `scripts/build-mac-app.sh` 의 ICON_KEY_BLOCK 부분 (line 89-94 부근):
```bash
if [ -f "$MAC_DIR/Resources/AppIcon.icns" ]; then
  cp "$MAC_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  # CFBundleIconFile is the classic key the Finder/Dock honor; CFBundleIconName
  # is what macOS 11+ system surfaces (notification center, share sheet, etc.)
  # read first. SwiftPM doesn't compile .xcassets so we can't ship an Asset.car
  # AppIcon group — declaring the icns under both keys keeps both code paths
  # happy and stops UserNotifications from falling back to the generic mask.
  ICON_KEY_BLOCK=$'\n  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>\n  <key>CFBundleIconName</key>\n  <string>AppIcon</string>'
else
  ICON_KEY_BLOCK=""
fi
```

B) `apps/mac/Sources/SteerMac/ActionNotificationService.swift` — `notify(card:)` 안에 첨부 추가:
```swift
// 기존 content 생성 후
if let attachment = providerIconAttachment(for: card) {
    content.attachments = [attachment]
}

// 클래스 멤버로 캐시
private var iconAttachmentCache: [String: URL] = [:]

private func providerIconAttachment(for card: ActionCard) -> UNNotificationAttachment? {
    guard let iconName = card.provider.iconName else { return nil }
    let url: URL
    if let cached = iconAttachmentCache[iconName] {
        url = cached
    } else {
        guard let bundled = Bundle.module.url(forResource: iconName, withExtension: "png") else { return nil }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("steer-notification-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(iconName).png")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.copyItem(at: bundled, to: dest)
        }
        iconAttachmentCache[iconName] = dest
        url = dest
    }
    return try? UNNotificationAttachment(
        identifier: "provider-\(iconName)",
        url: url,
        options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
    )
}
```

**검증:**
```sh
bash scripts/build-mac-app.sh
/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" .build/SteerMac.app/Contents/Info.plist
# "AppIcon" 출력되어야 함

# LaunchServices 캐시 갱신 (안 하면 macOS 가 옛 아이콘 정보 들고 있을 수 있음)
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister \
  -f .build/SteerMac.app

open .build/SteerMac.app
# 실제 카드 발생 시켜서 알림 확인 (화면 검증 필요)
```

**리스크:** stash 된 변경은 빌드 통과 확인됨 (Build complete! (3.20s)). 실제 알림에 아이콘이 보이는지는 화면 확인이 필요.

---

### 3️⃣ APNS payload (relay) — 별도 PR 권장

**문제:** `packages/relay/src/apns.ts:89-92` payload 에 `mutable-content: 1` 없음, 카드 아이콘 식별자 없음. NSE 없이도 변경 자체는 무해(NSE 가 없으면 mutable-content 는 그냥 무시됨), 그래서 단독으로 머지 가능.

**파일:** `packages/relay/src/apns.ts`

**변경 방향 (코드 미작성, 재개 시 작성):**
```ts
// PushRequest 에 cardIcon 필드 추가
interface PushRequest {
  deviceToken: string;
  title: string;
  body: string;
  /// One of "claude" | "codex" | undefined.
  /// NSE on the iPhone uses this to attach a bundled provider icon.
  cardIcon?: string;
  customPayload?: Record<string, unknown>;
}

// payload 생성부
const aps: Record<string, unknown> = {
  alert: { title: req.title, body: req.body },
  sound: "default",
};
if (req.cardIcon) {
  aps["mutable-content"] = 1;
}
const payload = {
  aps,
  ...(req.cardIcon ? { cardIcon: req.cardIcon } : {}),
  ...(req.customPayload ?? {}),
};
```

**호출부 확인:** `sendAPNSPush` 를 부르는 곳 (`grep -rn "sendAPNSPush" packages/relay/src/`) 에서 카드 객체의 provider 를 매핑해 cardIcon 을 채워야 함.

**검증:**
```sh
npm test --workspace packages/relay
# 푸시 통합 테스트가 있다면 cardIcon 케이스 추가
```

---

### 4️⃣ iOS Notification Service Extension (NSE) — 가장 큰 작업, Xcode 수작업 권장

**문제:** APNS payload 에 `mutable-content: 1` + `cardIcon` 을 보내도, iOS 클라이언트에 NSE 가 없으면 첨부가 만들어지지 않는다. 시스템은 그냥 텍스트만 표시.

**Xcode 수작업 단계 (안전):**

1. Xcode 에서 `apps/ios/Steer.xcodeproj` 열기
2. File → New → Target → iOS → **Notification Service Extension**
3. Product Name: `SteerNotificationService`
4. Embed in Application: `Steer` (자동 체크)
5. Activate scheme: 묻지 말고 No (기본 Steer scheme 유지)
6. 생성된 `SteerNotificationService/NotificationService.swift` 를 아래 코드로 교체

```swift
import UserNotifications
import UIKit

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // payload.cardIcon → bundled PNG → UNNotificationAttachment
        if let iconKey = request.content.userInfo["cardIcon"] as? String,
           let attachment = attachment(forBundledIcon: iconKey) {
            content.attachments = [attachment]
        }

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    /// NSE has its own bundle separate from the host app. We need to ship
    /// the provider PNGs *inside the extension bundle* so the system has
    /// readable access during the brief notification-service window.
    private func attachment(forBundledIcon name: String) -> UNNotificationAttachment? {
        guard let url = Bundle(for: Self.self).url(forResource: name, withExtension: "png") else {
            return nil
        }
        // UNNotificationAttachment requires the file to live where the
        // notification daemon can read it. Copying to NSTemporaryDirectory
        // gives the daemon ephemeral readable access.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("steer-nse-\(name).png")
        if !FileManager.default.fileExists(atPath: tmp.path) {
            try? FileManager.default.copyItem(at: url, to: tmp)
        }
        return try? UNNotificationAttachment(
            identifier: "provider-\(name)",
            url: tmp,
            options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
        )
    }
}
```

7. NSE 타겟에 `claude.png`, `codex-color.png` 추가:
   - File → Add Files to "Steer" → `apps/mac/Sources/SteerMac/Resources/claude.png` 등을 *NSE 타겟에만 체크*
   - 또는 NSE 폴더에 PNG 복사 → Add Files 로 NSE target membership 만 체크

**왜 Mac 의 PNG 를 쓰나:** Mac 자산은 더 큰 사이즈(아마 원본)고, iOS asset catalog 의 24/48/72 는 너무 작아서 알림 우측 큰 썸네일에 부적합. iOS 쪽에도 같은 위치에 따로 큰 PNG를 두는 게 깔끔할 수 있음 — 그건 그때 결정.

**알림 페이로드 검증:**

8. 빌드 후 디바이스 설치, APNS 환경(`APNS_USE_SANDBOX=1`) 으로 테스트 푸시:
```sh
# relay 를 cardIcon 포함하게 수정 후
# 카드 1개를 publish 해서 푸시 발생
# 디바이스 lock screen 에서 알림에 provider 아이콘이 우측에 표시되는지 확인
```

---

## 영역별 PR 분리 권장

| PR | 범위 | 검증 비용 | 단독 머지 가능 |
|---|---|---|---|
| PR1 | 영역 1 (iOS asset @2x/@3x) | `xcodebuild` + `assetutil` — 5분 | ✅ |
| PR2 | 영역 2 (Mac 알림 + Info.plist) | `.app` 빌드 + 화면 확인 — 10분 | ✅ |
| PR3 | 영역 3 (APNS payload) | `npm test` + 실제 푸시 송신 — 15분 | ✅ (NSE 없어도 무해) |
| PR4 | 영역 4 (iOS NSE) | Xcode 수작업 + 디바이스 푸시 — 30~60분 | ✅ (PR3 머지 후) |

영역 1/2 는 stash 에 코드 준비 완료. 재개 시 stash pop → 빌드 검증 → 두 영역을 한 PR 로 묶거나 분리. 영역 3/4 는 코드 미작성 — 재개 시 위 스니펫 기준으로 구현.

---

## 보관 중인 stash 인벤토리

- `stash@{0}: icon-fix-code-staged` — 영역 1/2 코드 변경 (iOS asset PNG + Contents.json, Mac ActionNotificationService 첨부, build-mac-app.sh CFBundleIconName)
- `stash@{1}: sync-v2-spillover` — sync-v2 작업이 이 브랜치에 흘러들어온 변경 (InboxView/SyncInbox/ActionCardView LoadPhase). **design/sync-v2 에서 pop 해야 함**, 이 작업이랑 무관.

---

## 진단 결과 요약 (상세는 ICON_AUDIT.md)

| 영역 | 상태 | 핵심 원인 |
|---|---|---|
| iOS 푸시 알림 아이콘 | ❌ | APNS payload 첨부 메타 없음 + NSE 타겟 자체가 없음 |
| Mac 로컬 알림 아이콘 | ❌/⚠️ | `content.attachments` 미설정 + `CFBundleIconName` 키 누락 |
| iOS 카드 provider 아이콘 흐림 | ⚠️ | imageset Contents.json 의 2x/3x slot 비어있음 |
| iOS AppIcon (홈/스포트라이트) | ⚠️ | 1024 single-size — iOS 17+ 에선 정상이라 우선순위 낮음 |
| Mac AppIcon | ✅ | icns 모든 chunk 존재, CFBundleIconFile 박힘 |
| Mac 카드 provider 아이콘 | ✅ | Bundle.module + Resources/ PNG 정상 |
