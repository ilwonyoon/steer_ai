# App Store Privacy Labels

Last updated: May 10, 2026

This file maps the current Steer iOS + Mac relay implementation to App Store Connect privacy answers. Keep it aligned with code before every TestFlight or App Store submission.

## Sources Reviewed

- `apps/ios/SteerIOS/SyncInbox.swift`
- `apps/mac/Sources/SteerMac/SyncClient.swift`
- `apps/mac/Sources/SteerMac/SteerCardMapping.swift`
- `packages/relay/src/auth.ts`
- `packages/relay/src/store.ts`
- `packages/relay/migrations/0001_initial.sql`

Apple references:

- App Privacy Details: https://developer.apple.com/app-store/app-privacy-details/
- App Review Guidelines 5.1.1 Privacy: https://developer.apple.com/app-store/review/guidelines/
- Account deletion: https://developer.apple.com/support/offering-account-deletion-in-your-app

## Tracking

Answer: No.

Steer does not use synced content, identifiers, or usage data to track users across apps or websites owned by other companies. There is no advertising SDK in the current code.

## Data Linked To The User

Declare these data types as linked to the user and used for App Functionality.

| App Store data type | Current Steer data | Purpose |
| --- | --- | --- |
| Contact Info - Email Address | Apple relay email or real email from Sign in with Apple | Authentication and account identification |
| Contact Info - Name | Apple display/given name if provided | Account display |
| User Content - Other User Content | Action card title, summary, terminal excerpt lines, reply text, suggested options, failure reasons | Sync action cards and deliver replies |
| Identifiers - User ID | Apple `sub`, Steer session user ID, session IDs, card IDs, instruction IDs | Authentication, sync ownership, routing |

## Data That May Be Processed By Infrastructure

Cloudflare may process operational request metadata to operate Workers, D1, and Durable Objects. Confirm the production Cloudflare logging settings before final submission.

If production logs are retained in a way Steer can access beyond real-time request servicing, consider whether to disclose:

- Usage Data - Product Interaction
- Diagnostics - Crash Data or Performance Data
- Identifiers - Device ID, if added later

Do not declare these unless the production implementation actually collects or retains them.

## Data Not Currently Collected

Based on current code, do not declare:

- Location.
- Contacts.
- Photos or Videos.
- Audio Data.
- Browsing History.
- Search History.
- Health and Fitness.
- Financial Information.
- Purchases.
- Advertising Data.
- Sensitive Info as a dedicated category, unless Steer intentionally collects classified sensitive categories beyond incidental terminal text.

## Privacy Policy Required Claims

The public policy must say:

- Steer uses Sign in with Apple.
- Steer uses Cloudflare Workers, D1, and Durable Objects for relay sync.
- Steer may sync short terminal excerpts, project/provider/branch labels, action card summaries, and user replies.
- Steer does not sell user data.
- Steer does not use synced content for advertising.
- Steer does not use synced content to train AI models.
- Account deletion removes relay user data and synced relay records.

## Launch Blockers

- [x] Relay has an authenticated account deletion endpoint: `DELETE /v1/me`.
- [x] iOS app exposes account deletion in an easy-to-find account/settings UI.
- [x] Public Privacy Policy URL is live and matches `PRIVACY_POLICY.md`: `https://ilwonyoon.github.io/steer_ai/privacy/`.
- [x] Public Terms URL is live and matches `TERMS_OF_SERVICE.md`: `https://ilwonyoon.github.io/steer_ai/terms/`.
- [ ] Production Cloudflare log retention setting is documented.
- [ ] App Store Connect privacy answers are updated from this file.
- [ ] Any analytics, crash reporting, or telemetry SDK added later is reflected here before submission.
