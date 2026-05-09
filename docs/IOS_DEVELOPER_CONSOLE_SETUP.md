# iOS Spike — Apple Developer Console Setup (one-time, ~30 min)

This is the GUI work the user has to do once before the iOS spike can move past the entitlement/provisioning wall. The automated work in this branch (CloudKit publisher, iOS skeleton) is wired up assuming these steps are done.

---

## 0. Prereqs already in place

- Apple Developer Program: ILWON YOON, Team ID `LG7667PAS6`.
- Existing Mac App ID: `ai.steer.mac` (already registered for v0.0.1 dmg).
- Notarytool keychain profile: `steer-notary` already configured.

---

## 1. Add CloudKit capability to the Mac App ID (5 min)

1. Go to https://developer.apple.com/account/resources/identifiers/list
2. Click on **ai.steer.mac** in the list.
3. Scroll to **Capabilities**.
4. Check **iCloud** if it isn't already.
5. Click **Configure** next to iCloud.
6. Under **iCloud Containers**, you'll create the container in step 2 — leave this open in another tab.

---

## 2. Create the CloudKit container (3 min)

1. Go to https://developer.apple.com/account/resources/identifiers/list/cloudContainer
2. Click **+** → **Register a CloudKit Container**.
3. Description: `Steer CloudKit Container`
4. Identifier: `iCloud.ai.steer.mac`
5. Click **Continue** → **Register**.

Now go back to step 1's tab:

6. Refresh the iCloud Containers list under **ai.steer.mac**.
7. Check the box next to **iCloud.ai.steer.mac**.
8. Click **Continue** → **Save**.

Apple will warn about modifying app capabilities — confirm.

---

## 3. Register the iOS App ID (3 min)

1. Same Identifiers page → **+** → **App IDs** → **App**.
2. Description: `Steer iOS`
3. Bundle ID (Explicit): `ai.steer.ios`
4. Capabilities: check **iCloud** + **Push Notifications**.
5. Click **Configure** next to iCloud and add **iCloud.ai.steer.mac** (the same container — both apps share it).
6. Click **Continue** → **Register**.

---

## 4. Create the Mac Developer ID provisioning profile (5 min)

The Mac dmg currently signs with Developer ID Application but has no provisioning profile. CloudKit on a notarized direct-distribution build *requires* a profile to assert the iCloud entitlements.

1. https://developer.apple.com/account/resources/profiles/list → **+**
2. Under **Distribution**: select **Developer ID** → **Continue**.
3. App ID: select **ai.steer.mac**.
4. Certificate: pick the existing `Developer ID Application: ILWON YOON (LG7667PAS6)` (either of the two valid certs is fine).
5. Profile Name: `Steer Mac Developer ID`
6. **Generate** → **Download**.
7. Double-click the downloaded `.provisionprofile` to install it into your login keychain.

Verify:

```sh
ls ~/Library/MobileDevice/Provisioning\ Profiles/
security cms -D -i ~/Library/MobileDevice/Provisioning\ Profiles/*.provisionprofile 2>/dev/null \
  | grep -E "Name|AppIDName|com.apple.developer.icloud"
```

You should see `Steer Mac Developer ID` and the iCloud entitlement keys.

---

## 5. (Deferred) Create the iOS development profile

Skip until iOS skeleton compiles. We'll create a Development profile when we first run the iOS app on a real device. For the simulator-only path no profile is needed.

---

## 6. Notify the agent

Once steps 1–4 are done, tell the agent: **"Apple Developer 콘솔 setup 끝"**. The next iOS-spike step (`A.2 entitlements + provisioning embedding`) is blocked on this.

---

## What this unlocks

- Mac release builds can declare `com.apple.developer.icloud-services` and `com.apple.developer.icloud-container-identifiers`, which lets CloudKit calls succeed in a notarized direct-distribution build.
- The iOS app can use the same `iCloud.ai.steer.mac` container without setting up CloudKit twice.
- Users only see one iCloud container in their Settings → Apple ID → iCloud → Apps Using iCloud list.
