# Steer iOS — Apple Developer Console Setup

Last updated: 2026-05-09

One-time setup required before CloudKit sync and iOS push notifications work.
All steps are on https://developer.apple.com — Team ID: LG7667PAS6 (ILWON YOON).

---

## Step 1 — Add iCloud capability to ai.steer.mac and register CloudKit container

URL: https://developer.apple.com/account/resources/identifiers/list

1. Click **ai.steer.mac** in the Identifiers list.
2. Scroll to **Capabilities** → find **iCloud** → check the checkbox.
3. A sub-panel appears. Select **CloudKit** (not "Include CloudKit support" Legacy checkbox).
4. Under **iCloud Containers**, click **+** → enter:
   ```
   iCloud.ai.steer.mac
   ```
   Then click **OK** / **Add**.
5. Confirm `iCloud.ai.steer.mac` is listed and highlighted under this App ID.
6. Click **Save** (top right).

**Verify:** The iCloud row in capabilities now shows ✓ and the container `iCloud.ai.steer.mac` is linked.

---

## Step 2 — Register ai.steer.ios with Push Notifications + iCloud

URL: https://developer.apple.com/account/resources/identifiers/list

1. Click **+** (top right, next to the Identifiers heading).
2. Select **App IDs** → Continue.
3. Type: **App** → Continue.
4. Fill in:
   - **Description:** `Steer iOS`
   - **Bundle ID (Explicit):** `ai.steer.ios`
5. Scroll to **Capabilities** and check **two** boxes:
   - ☑ **Push Notifications**
   - ☑ **iCloud** → select CloudKit → link existing container `iCloud.ai.steer.mac`
6. Click **Continue** → **Register**.

**Verify:** `ai.steer.ios` appears in the Identifiers list with identifier `ai.steer.ios`.

---

## Step 3 — Create Developer ID provisioning profile for Steer Mac

> Developer ID Mac apps need a provisioning profile only when using advanced
> capabilities like CloudKit. Without it, notarization passes but CloudKit
> entitlements are rejected at runtime.

URL: https://developer.apple.com/account/resources/profiles/list

1. Click **+** (top right, next to the Profiles heading).
2. Under **Distribution**, select **Developer ID** → Continue.
3. App ID: select **Steer Mac (ai.steer.mac)** → Continue.
4. Certificate: select the **Developer ID Application: ILWON YOON (LG7667PAS6)** certificate → Continue.
5. Profile Name: `Steer Mac Developer ID` → Generate.
6. Click **Download** → save the `.provisionprofile` file.
7. Double-click the downloaded file to install it into Keychain/Provisioning Profiles.

---

## Step 4 — Verify

Run in Terminal:

```bash
ls ~/Library/MobileDevice/Provisioning\ Profiles/
```

You should see at least one `.provisionprofile` file. If the directory is
empty or missing, re-run step 3 and double-click the downloaded file.

**All done** — report `"Apple Developer 콘솔 작업 끝"` to the Cowork agent.

---

## Troubleshooting

### "iCloud container already exists"
Normal — just select the existing `iCloud.ai.steer.mac` container in the picker and link it.

### "No matching profiles found" in Xcode / release script
Ensure the profile was double-clicked to install. Also check that the
`STEER_SIGN_IDENTITY` matches the certificate used in the profile.

### CloudKit entitlement rejected at runtime (macOS)
The app's entitlements plist must include:
```xml
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.ai.steer.mac</string>
</array>
```
And the binary must be re-signed with the provisioning profile embedded.

### Push Notifications sandbox vs production
For TestFlight / direct distribution: use **Production** push certificate.
For Xcode development: the **Apple Development** certificate handles both.
