# Cross-Device Onboarding Plan

Last updated: 2026-05-10

## Purpose

Steer's real user path is Mac-first. The iPhone app needs Demo Mode for App Review and evaluation, but live value requires Steer for Mac to be installed, signed in, configured, and running.

This document defines the onboarding sequence across GitHub Release, Mac app, CLI/wrapper setup, relay sync, and iPhone app.

## Core Truth

Live iPhone delivery requires:

1. Steer for Mac is installed.
2. Steer for Mac is running or its background agent/login item is running.
3. The user is signed in with Apple on Mac.
4. iPhone Sync is enabled on Mac.
5. The user has at least one Steer-managed coding session, such as `steer codex` or `steer claude`.
6. The iPhone app is signed in with the same Apple account.

iPhone can queue replies while Mac is offline, but Mac must come back online to inject those replies into local CLI sessions.

## Recommended User Order

```text
1. Install Steer for Mac from GitHub Release / website.
2. Open Steer for Mac.
3. Complete Mac first-run setup:
   - install `steer` CLI symlink
   - install/verify Claude hooks if needed
   - verify Codex/Claude commands
   - enable notifications
4. Sign in with Apple on Mac.
5. Enable iPhone Sync on Mac after reviewing What Syncs.
6. Start a Steer-managed session:
   - `steer codex`
   - or `steer claude`
7. Install Steer on iPhone from App Store/TestFlight.
8. Sign in with the same Apple account on iPhone.
9. Confirm the top-right Mac chip shows the expected Mac, such as `MacBook Air` or `Mac mini`.
10. Reply from iPhone when a live card appears.
```

## GitHub Release Page Requirements

Every Mac release page should explain the setup order clearly. Suggested sections:

### What Steer Does

Steer is an AI coding action inbox for local Mac coding agents. It surfaces waiting or blocked moments as cards and lets you reply from Mac or iPhone.

### Install Steer for Mac

1. Download `Steer-<version>.dmg`.
2. Open the DMG and drag Steer to Applications.
3. Open Steer.
4. Complete first-run setup.

### Complete First-Run Setup

Steer will guide you through:

- Installing the `steer` command.
- Enabling notifications.
- Setting up Claude hooks when you use Claude Code.
- Verifying Codex/Claude command availability.
- Signing in with Apple for iPhone Sync.

### Start A Steer-Managed Coding Session

Use one of:

```sh
steer codex
steer claude
```

Steer only tracks sessions launched through Steer. It does not attach to arbitrary existing Terminal windows.

### Enable iPhone Sync

In Steer for Mac:

1. Open Settings.
2. Sign in with Apple.
3. Turn on iPhone Sync.
4. Review What Syncs.
5. Keep Steer for Mac running for live delivery.

### Install iPhone App

Install Steer on iPhone and sign in with the same Apple account. The top-right Mac chip should show your Mac, for example `MacBook Air`, `Mac mini`, or your custom Mac name.

If the Mac chip says `No Mac`, `Mac idle`, or `Mac offline`, tap it for setup or recovery instructions.

## Mac App Onboarding

Mac onboarding is the primary live-product onboarding. It should be a checklist, not a generic welcome screen.

### Step 1: Welcome

Copy:

`Steer keeps local AI coding sessions moving. Start sessions through Steer, review action cards, and reply from Mac or iPhone.`

CTA: `Set Up Steer`

### Step 2: Install CLI

Required:

- Detect whether `steer` command is on PATH.
- Offer userland symlink install.
- Show resulting command path.

Success copy:

`steer command installed`

### Step 3: Verify Providers

Required:

- Detect whether Codex CLI is available.
- Detect whether Claude Code is available.
- Show provider-specific setup actions:
  - `steer codex`
  - `steer claude`
  - `steer install-claude-hooks`

Do not block if one provider is missing. The user only needs one working provider.

### Step 4: Notifications

Required:

- Request macOS notification permission.
- Explain that notifications are for waiting/blocker cards.

### Step 5: Sign In With Apple

Required:

- Sign in with Apple inside Mac app.
- Store relay session token in Keychain.
- Show signed-in Apple relay email or account label.

Copy:

`Sign in to sync action cards and replies between your own devices.`

### Step 6: Enable iPhone Sync

Required:

- iPhone Sync must be explicit opt-in.
- Show What Syncs before the toggle commits.
- Publish Mac device presence heartbeat after sync is enabled.
- Device label should be visible and editable, for example `Ilwon's MacBook Air` or `Mac mini`.

What Syncs summary:

- Card title and summary.
- Short terminal excerpt.
- Suggested replies.
- Project/provider/branch labels.
- Replies sent from iPhone.
- Delivery status.

What Does Not Sync by default:

- Full raw transcripts.
- Environment variables.
- Attachments.
- Arbitrary file contents.

### Step 7: Start First Session

Required:

- Show copyable commands:
  - `steer codex`
  - `steer claude`
- Explain that Steer only tracks sessions launched through these commands.
- Show first-card readiness state after a session starts.

### Step 8: Install iPhone App

Required:

- Provide App Store/TestFlight link once available.
- Show QR code if available later.
- Explain same Apple account requirement.
- Tell user to check the iPhone Mac chip.

## iPhone App Onboarding

iPhone onboarding is secondary for live use but must be complete enough for App Review.

Required:

- Signed-out screen has `Try Demo`, native Sign in with Apple, Privacy, Terms, Support.
- Demo Mode works without Mac.
- After sign-in with no Mac, show `No Mac` chip and setup instructions.
- After Mac sync is enabled, show the Mac label chip.
- If Mac is offline, show queued reply behavior.

See `docs/IOS_PRE_CONNECTION_ONBOARDING.md` for detailed state design.

## Device Presence And Delivery Contract

Mac should heartbeat while iPhone Sync is enabled:

- `deviceId`
- `platform=mac`
- `displayName`
- `deviceClass`
- `appVersion`
- `lastSeenAt`
- `syncEnabled`

iPhone should treat Mac as:

- `connected`: heartbeat <= 90 seconds.
- `idle`: heartbeat > 90 seconds and <= 10 minutes.
- `offline`: heartbeat > 10 minutes.
- `neverConnected`: no Mac device record.

Reply behavior:

- Connected: reply can be queued and should be picked up quickly.
- Idle/offline: reply is saved to relay but shown as queued until Mac returns.
- Never connected: allow demo replies; live reply composer should explain setup first.

## App Review Framing

Review notes should say:

- The iPhone app includes Demo Mode so reviewers can exercise the app without a Mac.
- Live delivery requires Steer for Mac because local coding sessions run on the user's own Mac.
- The iPhone app queues replies; it does not execute commands directly.
- Steer is not a remote shell, terminal mirror, or remote desktop client.

## Implementation Checklist

### P0 Mac

- [ ] Add first-run checklist UI for CLI install, provider verification, notifications, Apple sign-in, iPhone Sync, and first session.
- [ ] Add Mac Sign in with Apple and visible signed-in state in Settings/onboarding.
- [ ] Add explicit iPhone Sync opt-in with What Syncs review.
- [ ] Add editable Mac device label and deviceClass detection.
- [ ] Add Mac device heartbeat to relay while sync is enabled.
- [ ] Add "keep Steer for Mac running" guidance and login item prompt.
- [ ] Add GitHub Release setup instructions.

### P0 iPhone

- [ ] Add signed-out Demo Mode and live sign-in path.
- [ ] Add top-right Mac chip and Mac Sync Status sheet.
- [ ] Add No Mac setup instructions that start with installing/opening Steer for Mac.
- [ ] Add offline/idle recovery instructions.
- [ ] Add queued reply copy when Mac is not connected.

### P1

- [ ] Add QR code/deep link from Mac to iPhone app when App Store URL exists.
- [ ] Add multi-Mac list and active Mac selection if multiple devices heartbeat.
- [ ] Add release-page screenshots or GIFs for Mac setup and iPhone chip states.

## Acceptance Criteria

- A new user can follow GitHub Release instructions, install Mac app, start `steer codex` or `steer claude`, enable iPhone Sync, install iPhone app, and see the correct Mac chip.
- A user understands that Mac must be running for live delivery.
- The iPhone app remains useful and reviewable before Mac setup through Demo Mode.
- No onboarding or release copy frames Steer as remote terminal control.
