# Settings: Profile Picture + Display Name Research

**Date:** 2026-05-13
**Author:** Claude (Opus 4.7) research pass
**Audience:** Steer engineering — read before implementing
**Status:** research only, no code touched

## Why this exists

`SettingsView.swift` currently renders an `IdentityRow` with a circle of accent-coloured initials and `user.displayName ?? "Signed in"`. The displayName is whatever Apple handed us on the *first* `ASAuthorizationAppleIDCredential.fullName` and stored on the relay (`users.display_name` in `0001_initial.sql`). The repo already has the standard "fullName is nil on subsequent sign-ins" comment in both
`apps/ios/SteerIOS/SyncInbox.swift` (handleAppleCredential, lines ~248–261) and
`apps/mac/Sources/SteerMac/SyncClient.swift` (handleAppleCredential, lines ~235–248).

Question is whether we can do better than that for **(a)** the real display name and **(b)** a profile picture. Short answer: **no, not via Apple. Yes, via a user-uploaded avatar.** Long answer below.

---

## 1. Re-prompting for `fullName`

### 1.1 What Apple actually returns

Apple staff (Frameworks Engineer "Patrick" on Apple Dev Forums, the canonical reference everyone cites):

> *"User info is only sent in the ASAuthorizationAppleIDCredential upon initial user sign up. Subsequent logins to your app using Sign In with Apple with the same account do not share any user info and will only return a user identifier in the ASAuthorizationAppleIDCredential."*
> — Apple staff, [Apple Developer Forums thread/121496](https://developer.apple.com/forums/thread/121496)

The mechanism is keyed on (Apple ID `sub`, primary App ID / bundle id). Once Apple has handed `fullName` over once, the system caches the "this app already saw the name" flag at the OS level and on Apple's auth servers. Re-requesting `[.fullName, .email]` in `request.requestedScopes` on subsequent attempts is silently honoured but returns `nil`.

This is exactly what our existing comment says, so nothing new there — but I want to record the citations because the rest of this section is mostly negative findings.

### 1.2 `ASAuthorizationAppleIDProvider().getCredentialState(forUserID:)`

**Return states** ([CredentialState docs](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidprovider/credentialstate)):
- `.authorized` — system has a valid credential for this user
- `.revoked` — the user revoked the app's Sign-in-with-Apple grant (Settings → Apple ID → Sign in with Apple → Steer → Stop Using). This is the trigger of `credentialRevokedNotification`.
- `.notFound` — no credential exists for that user id (uninstalled / never signed in / fresh device)
- `.transferred` — used during Apple's "transfer your account to another team" / App Store transfer flow. Migrating ownership of a bundle id between Apple Developer accounts can leave existing user identifiers in a transferred state, after which clients must re-auth. Practically irrelevant for us — we own the bundle and have no plan to transfer it.

**Side effects:** none documented. It's a pure read. It does **not** trigger a re-prompt, it does **not** invalidate the cached name grant, it does **not** revoke. It's exactly what its name says: a state query.

### 1.3 Re-calling `performRequests()` after a delay / with `[.fullName, .email]`

Tested by many third-party developers and consistently reported. There is no time-based reset. The cache is keyed on (Apple ID sub, bundle id) and persists across:
- App reinstalls
- Device reboots
- iOS major version upgrades
- Years of disuse

Re-requesting `requestedScopes = [.fullName, .email]` is a no-op at the protocol level on subsequent flows. The identity token's `email` and `email_verified` claims are still present on each fresh auth (so the relay's `appleEmail` field stays valid), but `fullName` is missing from the credential and the JWT.

### 1.4 Server-side `/auth/revoke` — can we force a re-consent?

This is the interesting case and the most-misreported on the open web. Let me lay out the canonical Apple position from [TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple) and the [token revocation reference](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens):

- Calling `POST https://appleid.apple.com/auth/revoke` with the refresh/access token + a signed client_secret JWT **does** invalidate that token on Apple's side.
- This is what the relay already does in `revokeAppleAuthGrant()` during `DELETE /v1/me` — good, App Store guideline 5.1.1(v) compliance is in place.
- But on subsequent sign-in to the same (Apple ID, bundle id), **Apple's auth UI still shows "Continue" (silent re-auth) rather than the initial consent sheet, and `fullName` is still `nil`.**

The only way to get the initial-consent path again is for the user to manually visit System Settings → Apple ID → Sign in with Apple → \[App\] → "Stop Using Apple ID", then sign in again from the app. Our existing code comment is correct.

Field reports confirm: even after a properly-completed `/auth/revoke` *plus* the user reinstalling the app, name is not re-issued unless the user does the "Stop Using" step ([invertase/react-native-apple-authentication#340](https://github.com/invertase/react-native-apple-authentication/issues/340)). Some open-web sources claim revoke resets the prompt — those are wrong or are conflating server-side revoke with the user-side "Stop Using" action.

### 1.5 "Sign in with Apple at Work & School" / Managed Apple Accounts

Different surface, different code path:
- Triggered only when the user signed in to the device with a *Managed Apple Account* (Apple Business Manager / Apple School Manager). Consumer Apple IDs cannot use this flow.
- The first-only-fullName rule still applies — the [WWDC22 session 10053](https://developer.apple.com/videos/play/wwdc2022/10053/) walks through the exact same consent screen, just titled differently. The org-provided name is shown and provided to the app on first authorization. No documented "re-issue" mechanism.
- Apple's [Sign in with Apple at Work & School Privacy doc](https://www.apple.com/legal/privacy/data/en/sign-in-with-apple-at-work-and-school/) is identical in substance to the consumer one: first-sign-in only.

Not relevant for our consumer iOS / Mac app. (And asking users to switch to a Managed Apple Account just so we can refetch their name is, obviously, absurd.)

### 1.6 Server-to-Server Notifications

The [processing-changes-for-Sign-in-with-Apple-accounts](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts) endpoint delivers four event types:
- `email-disabled` (user paused the Hide-My-Email relay)
- `email-enabled` (re-enabled)
- `consent-revoked` (user did the "Stop Using" flow — same trigger as `credentialRevokedNotification` on-device)
- `account-delete` (the entire Apple ID was deleted)

None of these endpoints accept inbound calls to **force** a re-consent. They are read-only outbound webhooks. The relay doesn't currently subscribe to them at all — worth adding for `consent-revoked` and `account-delete` (App Store 5.1.1 compliance hygiene), but not relevant to the profile picture / name problem.

### 1.7 Sandbox / TestFlight / development bundles

- **Bundle id change resets the cache.** Because the (Apple ID, bundle id) tuple is the cache key, signing in to `ai.steer.ios.dev` instead of `ai.steer.ios` is a "first sign-in" for that bundle. This is how we'd test the name path without burning our own production grant.
- TestFlight builds share the production bundle id. So a TestFlight install reuses the same cache — no help there.
- Sandbox Apple IDs created in App Store Connect can be used for Sign in with Apple testing, but they're a pain: 2FA is required, sandbox accounts don't have full-fat Apple ID features, and the consent flow is mostly indistinguishable from production. Not a viable "give me my name back" workaround for real users.

### 1.8 Summary of section 1

**No programmatic way exists to force `fullName` to re-issue.** The only path is the user-initiated System Settings → "Stop Using Apple ID" flow. We should stop pretending otherwise and design the UX around that constraint.

---

## 2. Photo

### 2.1 Sign in with Apple

Apple's official answer ([Apple Dev Forums thread/121998](https://developer.apple.com/forums/thread/121998), Frameworks Engineer "Patrick" again):

> *"Currently, you can request scopes for full name and an email address. If you need additional information from the user, like a profile picture, you can prompt for that information using your own user interface after completing the Sign In with Apple flow. Sign In with Apple will not provide any other user information."*

This has been the position since 2019 and has not changed at WWDC23/24/25/26. Looking at `ASAuthorizationAppleIDCredential`'s property list (`user`, `state`, `authorizedScopes`, `authorizationCode`, `identityToken`, `email`, `fullName`, `realUserStatus`) — no image, no avatar, no photo, no nothing. The `identityToken` JWT claims (`sub`, `iss`, `aud`, `exp`, `iat`, `email`, `email_verified`, `is_private_email`, `nonce`, `auth_time`) carry no image URL either.

The `ASAuthorization.Scope` enum is just `.fullName` and `.email`. There is no `.photo` or `.image`.

### 2.2 Contacts framework — `CNContactStore`

This is where it gets interesting and platform-specific.

**macOS:** `CNContactStore.unifiedMeContactWithKeys(toFetch:)` exists and returns a `CNContact` for the "Me" card. Requires:
- `NSContactsUsageDescription` in Info.plist
- User grants the Contacts permission prompt
- Codesigning with appropriate entitlement (`com.apple.security.personal-information.addressbook`)
- For the photo specifically, fetch `CNContactImageDataKey` or `CNContactThumbnailImageDataKey`

For the Mac app this is technically feasible. The Mac app already has its own entitlements file (per the recent `1b290a2 fix(mac): restore dogfood entitlements file` commit) so adding the personal-information.addressbook entitlement is mechanically possible.

**iOS:** `unifiedMeContactWithKeys(toFetch:)` is **explicitly unavailable on iOS, watchOS, and visionOS**. Apple staff has confirmed this in [Apple Dev Forums thread/747688](https://developer.apple.com/forums/thread/747688):

> *"The unifiedMeContactWithKeys(toFetch:) instance method is unavailable on iOS, watchOS, and visionOS. The Objective-C section of its documentation display the correct platforms on which this API is available."*

There's no documented iOS replacement. You could request full Contacts read access and then heuristically match against the iCloud-signed-in Apple ID's email — but (a) that requires you to *know* the user's iCloud email, which we don't, and (b) reading the entire contacts database to find one card is overreach that App Review will not love.

This is the deal-breaker for "show the iCloud user's photo automatically on iPhone." We **cannot** do this on iOS via Contacts.

### 2.3 Other system-provided avatar sources

- **`ShareLink` / system share sheet** — does not surface any user-image asset.
- The Sign-in-with-Apple sheet **does** show the user's Memoji / Apple ID photo on the "Continue as Jane" greeting, but that image is rendered inside Apple's own controller, never exposed to the embedding app.
- **Continuity / Handoff** APIs — no profile image surface.
- **GameKit** (`GKLocalPlayer.local.loadPhoto`) — returns the user's Game Center photo but only after they sign in to Game Center, and our app is not a game. App Review would reject Game Center integration for "we just want the photo".
- **`PKPassLibrary`**, **`HMHomeManager`**, **`HKHealthStore`** — none expose Apple ID avatar.

No usable iOS path.

### 2.4 Gravatar fallback

Gravatar's URL scheme is `https://gravatar.com/avatar/{sha256(lowercase(email))}`. Two problems for us specifically:

1. **Apple's relay address is the common case.** Users who chose "Hide My Email" get an `@privaterelay.appleid.com` alias. Hashing that gives us a Gravatar URL for the alias, not the real account. Probability of a Gravatar hit on `@privaterelay.appleid.com`: essentially zero (the relay address is per-app and not something users register on Gravatar).
2. **Even for real emails, hit rate is low.** Gravatar is popular among developers / GitHub users; general consumer apps see <20% coverage. For our developer-tooling audience the hit rate is probably 40–60%, which is decent — but only for the subset of users who chose "Share My Email" during Sign in with Apple.
3. **Privacy disclosure obligation.** Sending the user's email (even hashed) to a third-party CDN is a "data linked to user" event for App Store privacy nutrition labels. We'd have to add "Email Address — Product Personalization — Linked to User" to the label *and* mention Gravatar in the privacy policy. Not a deal-breaker but not nothing.
4. **Gravatar's MD5 → SHA256 rollover.** Older Gravatars are still keyed on MD5; modern ones use SHA256. To maximize hit rate we'd have to request both URLs and fall back.

Verdict: **Gravatar is a useful "best effort" fallback for the share-real-email subset only.** It is **not** a primary photo source.

### 2.5 Identicon / generated avatar

For users with no real email and no uploaded photo, we can still beat "first-initial-on-coloured-circle" with something a touch more personal. Options:
- Deterministic SVG identicon keyed on `userId` (looks like GitHub's identicons)
- The system Memoji-style emoji generator — there is no public API for that. Don't try.
- Pre-baked palette of monochrome SF Symbol portraits — boring but works on-brand

We already have the coloured-initial circle in `IdentityRow`. That's effectively a degenerate identicon. Going further is pure UX polish, not a research question.

---

## 3. Let the user upload one (the pragmatic path)

### 3.1 iOS / macOS picker code

iOS 16+: `PhotosPicker` from PhotosUI. Works in SwiftUI, no Photos-library entitlement needed for *picking* one item (only for full library read). Standard pattern is:

```swift
PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
    Label("Change Photo", systemImage: "person.crop.circle")
}
.onChange(of: pickedItem) { _, new in
    Task { /* load Data, downscale, upload */ }
}
```

macOS 13+ has the same `PhotosPicker` in SwiftUI. Alternative on Mac is `NSOpenPanel` + drag-drop into the avatar circle, both more native to the desktop idiom. Drag-drop is one extra modifier (`.onDrop(of:)`).

### 3.2 Backend storage on Cloudflare R2

The relay already runs on Cloudflare Workers + D1 (per `packages/relay/wrangler.toml`). R2 is **not** currently bound — only D1 and Durable Objects. To add avatars:

- Provision a new R2 bucket via `wrangler r2 bucket create steer-avatars`. Cost is negligible at our scale (R2 free tier is 10 GB-month + 10M Class A ops/month).
- Add an `[[r2_buckets]]` binding to wrangler.toml.
- Endpoints (suggested, not yet implemented):
  - `PUT /v1/me/avatar` — multipart body (or raw bytes + Content-Type); auth required; downscale + sanity-check on the worker (max 512x512 PNG/JPEG, ~50 KB after re-encode); store at key `avatars/{userId}.jpg`; return the public URL or a signed-URL TTL.
  - `DELETE /v1/me/avatar` — clear it.
  - `GET /v1/me` already returns the `SyncUser`. Add an `avatarUrl: String?` field there. Cache-bust via a short query string (`?v={timestamp}` or `?h={sha8}`) so iOS/Mac don't show stale images after upload.
- Schema migration: add `avatar_key TEXT` and/or `avatar_updated_at INTEGER` to `users` in a `0007_avatar.sql`. The relay returns a synthesised URL, not the raw key, so we can move buckets later without breaking clients.
- Public read or signed-URL? Public-read is simpler (R2 supports public buckets via custom domain). Signed URLs are more privacy-preserving (one URL per request, time-limited). For avatars, **public is fine** — they're already shown in-app, and the URL only leaks the userId, which the user's own iPhone+Mac both know.

Total backend delta: ~150 lines of TypeScript + one SQL migration + one wrangler binding. This is genuinely small.

### 3.3 Image sanitization

A few practical hazards if we accept user uploads:
- **EXIF / metadata** — strip it server-side. Cloudflare Images would do this automatically but is an extra paid product. Doing it ourselves: use `@cf/wasm-bindings/imagemagick` or just re-encode through `Image` API on Workers (free).
- **Orientation** — the iOS picker returns `Data` whose JPEG orientation tag is non-zero. The relay should normalize via re-encode, otherwise the Mac app will show it rotated 90 degrees.
- **Animated GIF / huge PNG** — limit to static, max ~2 MB pre-encode, ~50 KB post-encode.

### 3.4 App Store Review impact

- **Privacy nutrition label:** add "User Content — Photos or Videos — Linked to User — App Functionality" (we'd also already need "Identifiers — User ID" once we ship Sign in with Apple, which is presumably already on the label). Standard, low-friction.
- **Deletion flow:** App Store guideline 5.1.1(v) already requires we delete user data on account delete. The relay's `DELETE /v1/me` flow (which already runs `deleteUserData`) needs to also delete the R2 object — one extra line.
- **User-generated content moderation (1.2):** technically, an avatar is UGC. Apps with UGC need a way to flag inappropriate content AND a EULA prohibiting it. For an avatar-only flow (no other users see your avatar — it's only visible to *you* on your own iPhone+Mac), App Review has historically waived the full UGC moderation requirement. Worth a short note in the App Store Connect "Review Notes" field. Risk: low but non-zero. Worst case is one rejection and we add a "report" button that nobody will ever press because, again, no one else can see it.
- **Age rating:** if your avatar is invisible to other users, this doesn't move age rating. Trivial.

### 3.5 What App Review will NOT wave through for Contacts

- "We need to read your full Contacts to find your own Me card and copy the photo" — this is the exact pattern Apple has been clamping down on since iOS 17's "Limited Contacts Access" feature. Even with a stellar `NSContactsUsageDescription`, App Review will ask why you need full access instead of letting the user select. There's no "out-of-process picker" for a single contact (`CNContactPickerViewController` shows other contacts too, not your own card). Verdict: don't go here, it's a fight you can lose.

---

## 4. Display name re-entry

This is the genuinely-easy path. Once we accept that Apple's name only lands at first-sign-in and the user may have flubbed it (or hit Sign in with Apple before we ever asked for `[.fullName]` and got no name at all — a real failure mode our handleAppleCredential currently treats as "Signed in"):

- Add a `TextField` for "Display Name" to the existing AccountDetailView (or a new edit-profile sheet)
- Add `PUT /v1/me` to the relay accepting `displayName?: string` and updating `users.display_name`
- Optimistic update in `SyncInbox` / `SyncClient` so the IdentityRow refreshes instantly
- Optional: pre-fill from the existing displayName so users with the name already populated don't see an empty field

**Trade-off:** we lose the "system-derived identity, no extra friction" purity that was the original Sign in with Apple selling point. But (a) Apple's product designers themselves expose an editable name on appleid.apple.com — they don't pretend the system has divine truth either, and (b) Steer is a developer tool where users are perfectly comfortable typing their name into a profile field. The cost is approximately zero.

No App Store impact at all. No nutrition label change (we already collect a name).

---

## Honest recommendation

Given the constraints — Apple structurally refuses to give us the user's name a second time and structurally refuses to give us their photo at all on iOS — **stop trying to derive identity from Apple's surface**. Build a small "Edit Profile" sheet that lets the user (1) edit their display name and (2) upload an avatar. Keep `displayName ?? "Signed in"` as the fallback for users who skip it. The single user-visible benefit of Sign in with Apple from this point forward is identity-without-passwords; the visual identity is ours to design. Rank: **(1) ship the user-editable display name now** (1-2 days, backend + UI), **(2) add R2-backed avatar upload next** (~3-5 days end to end including server work, App Store privacy nutrition label update, and deletion-flow plumbing), **(3) consider a Gravatar fallback for the share-real-email subset only** as an opportunistic polish later, never as a primary source. Do **not** add Contacts permission. Do **not** pretend the System Settings "Stop Using" instruction is a usable solution — users will not do that.

## Quick-win that doesn't require Apple

In one PR, no Apple-side dependency:

1. Add `PUT /v1/me` to the relay accepting `{ displayName?: string }`, updating `users.display_name`, broadcasting the change on the user's WebSocket so the other device picks it up.
2. Add an editable "Name" row in `AccountDetailView` with optimistic save and a debounced PUT.
3. Render that updated name in `IdentityRow` — already works because `IdentityRow` reads from `user.displayName`.
4. Leave the avatar as the current initials-circle for this PR (already exists, looks clean).
5. Add a one-line entry to `EXECUTION_PLAN.md` under Settings.

Estimated work: 1 day, ~100 lines TS + ~80 lines Swift + 1 SQL migration (none needed — `display_name` is already a TEXT column we just need a way to UPDATE).

Shipping this alone removes 80% of the "my Settings screen says 'Signed in'" pain.

## Things I do NOT know and would have to test on a real device

- Whether `/auth/revoke` followed by reinstall + sign-in **does** re-issue `fullName` in any edge case (e.g. revoke + 24h wait + bundle-id flag rotation server-side). Anecdotal field reports say no, but the only authoritative test is to actually try it against a real Apple ID + our real bundle. Worth a half-day test on a personal device — I would NOT design the production UX around a positive outcome here, but if it works it materially changes the calculus.
- Whether the user's Memoji shows up in the Sign-in-with-Apple sheet for **all** users or only those who have set a Memoji as their Apple ID photo. (Apple does not say. The image is rendered inside the system controller anyway, so this is academic, but the photo coverage estimate matters for UX expectations.)
- Whether App Review will object to "User Content — Photos or Videos — Linked to User" on the nutrition label for an avatar-only feature, given the avatar is only ever shown to the user themselves. I expect "no objection" but I haven't put a Steer build through review yet.
- Real-world Gravatar hit rate against our actual signed-up user base. Estimate is 40-60% for developers. Could be much lower if everyone picked Apple's relay email.
- How the iCloud-keychain stored Apple ID interacts with `getCredentialState(forUserID:)` on a brand-new device after iPhone → iPhone migration. The `.transferred` state is documented but I have no in-the-field experience with it.
- Whether the existing `displayName` value on the relay for any user who signed in *before* we requested `[.fullName, .email]` (if such a window ever existed in our deploy history) is actually null in D1. Worth a one-line query against production D1 before designing migration UX.
- Whether macOS `unifiedMeContactWithKeys` on the user's Mac would return a photo for a typical user — the Me card is *only* automatically populated when the user explicitly identified themselves at first Mac setup, which is not universal. Some Macs have a Me card with no photo even on macOS 15+.

## References

- [ASAuthorizationAppleIDCredential](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential) — properties list (no image)
- [ASAuthorizationAppleIDProvider.CredentialState](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidprovider/credentialstate) — authorized / revoked / notFound / transferred
- [Apple Dev Forums 121496 (fullName first-time-only, Apple staff)](https://developer.apple.com/forums/thread/121496)
- [Apple Dev Forums 121998 (no profile picture, Apple staff)](https://developer.apple.com/forums/thread/121998)
- [Apple Dev Forums 747688 (unifiedMeContactWithKeys not on iOS, Apple staff)](https://developer.apple.com/forums/thread/747688)
- [Apple Dev Forums 708415 (revoke + credential state)](https://developer.apple.com/forums/thread/708415)
- [TN3194 Handling account deletions and revoking tokens for Sign in with Apple](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
- [Sign in with Apple REST: revoke-tokens](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)
- [Processing changes for Sign in with Apple accounts (S2S notifications)](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts)
- [WWDC22 10053 Discover Sign in with Apple at Work & School](https://developer.apple.com/videos/play/wwdc2022/10053/)
- [invertase/react-native-apple-authentication#340 — revoke does NOT re-issue name in practice](https://github.com/invertase/react-native-apple-authentication/issues/340)
- [App Store Review Guidelines 5.1.1 — account deletion](https://developer.apple.com/app-store/review/guidelines/)
- [Bringing Photos picker to your SwiftUI app](https://developer.apple.com/documentation/photokit/bringing-photos-picker-to-your-swiftui-app)
- [CNContactStore](https://developer.apple.com/documentation/contacts/cncontactstore)
- [NSContactsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nscontactsusagedescription)
