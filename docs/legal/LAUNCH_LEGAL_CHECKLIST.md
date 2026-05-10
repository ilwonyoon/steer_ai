# Legal And Privacy Launch Checklist

Last updated: May 10, 2026

This checklist is for shipping Steer on iPhone without getting blocked on Terms, Privacy Policy, account deletion, or App Store privacy labels.

## Current Implementation Facts

- Sync backend: Cloudflare Workers relay, D1, Durable Objects WebSocket fanout.
- Auth: Sign in with Apple identity token verified server-side, then Steer mints a 30-day session JWT.
- iOS storage: session JWT in Keychain.
- Mac storage: local SQLite and transcript logs under the local Steer data directory.
- Relay storage: users, cards, instructions, sessions.
- CloudKit: old planning artifacts still exist, but current iOS/Mac relay path does not use CloudKit.

## Must Finish Before App Store Submission

- [ ] Fill legal operator name in `PRIVACY_POLICY.md` and `TERMS_OF_SERVICE.md`.
- [ ] Fill support/privacy/legal email addresses.
- [ ] Publish public URLs for Privacy Policy and Terms.
- [x] Add those URLs inside the iOS app.
- [ ] Ensure Privacy Policy and Terms are reachable from the signed-out screen, not only signed-in account settings.
- [x] Add account/settings UI with Sign Out and Delete Account.
- [x] Add relay account deletion API.
- [x] Add iOS client call to `DELETE /v1/me` from Delete Account.
- [ ] Complete Sign in with Apple deletion flow by revoking Apple tokens during account deletion.
- [ ] Decide whether to keep custom Terms separate from Apple's standard EULA or paste a custom EULA into App Store Connect.
- [ ] Document Cloudflare production log retention.
- [ ] Add demo/offline mode so the app is reviewable without a live Mac.
- [ ] Implement the full pre-connection UX in `docs/IOS_PRE_CONNECTION_ONBOARDING.md`.
- [ ] Implement the Mac-first cross-device onboarding plan in `docs/CROSS_DEVICE_ONBOARDING_PLAN.md`.
- [ ] Replace custom Sign in with Apple button with Apple's native `SignInWithAppleButton`.
- [ ] Add Mac-side "Enable iPhone Sync" consent screen that lists all synced relay fields before data leaves the Mac.
- [ ] Add terminal excerpt sync setting or explicit launch-time opt-in.
- [ ] Add relay-backed Mac device presence/heartbeat and iOS Mac connection chip with setup/offline recovery instructions.
- [ ] Update App Store privacy answers from `APP_STORE_PRIVACY_LABELS.md`.
- [ ] Finalize App Review Notes with demo instructions and "not remote terminal / not remote desktop" explanation.
- [ ] Audit App Store copy, screenshots, and in-app copy for remote-shell language.

## Strongly Recommended

- [ ] Add a "What syncs" inspection screen showing current sync scope and last sync status.
- [ ] Let users disable terminal excerpt sync separately from card title/summary sync.
- [ ] Add a local data deletion help section for Mac files.
- [ ] Add server-side cleanup for resolved cards and old instruction records.
- [ ] Add a redaction pass for common secret patterns before publishing card payloads.
- [ ] Add GitHub Release page setup instructions from `docs/CROSS_DEVICE_ONBOARDING_PLAN.md`.

## Demo Mode Requirements

Demo Mode is a P0 App Review requirement, not polish. It should be reachable without a relay account and should demonstrate:

- Action card stack.
- Persistent connection state: Sample, No Mac, Mac online, Mac idle, Mac offline, or Sync issue.
- Card detail.
- Short terminal excerpt.
- Suggested reply chips.
- Reply composer.
- Simulated queued, delivered, and failed statuses.
- Account/settings access to Privacy Policy, Terms, and Support.

The demo must not imply that it is controlling a real terminal. Label it as sample data for reviewing Steer's action-inbox workflow.

## Copy And Metadata Guardrails

Use:

- "AI coding action inbox"
- "Review waiting agent cards"
- "Queue replies to your own Mac coding sessions"
- "Mac handles local delivery"

Avoid:

- "Remote terminal"
- "Remote shell"
- "Control your Mac terminal"
- "Run commands from iPhone"
- "Terminal mirror"
- "Remote desktop"

## App Store Risk Controls

- Minimum functionality: show a real native inbox experience and demo data without requiring immediate Mac setup.
- Privacy policy: link in App Store Connect and inside the app.
- Account deletion: easy to find, deletes full relay account and associated relay data.
- Accurate metadata: describe Steer as an AI coding action inbox, not a remote terminal.
- Privacy labels: disclose user content and identifiers because card/reply data leaves the device and is stored by the relay.

## Public URL Plan

Recommended URLs:

- `https://steer.ai/privacy`
- `https://steer.ai/terms`
- `https://steer.ai/support`

Fallback if the marketing site is not ready:

- GitHub Pages or another stable static host using the same Markdown content converted to HTML.
