# App Store launch runbook — Steer for iPhone

Target: submit to App Review within 24h.

This is the *operational* checklist. The longer-form planning docs
(`IOS_LAUNCH_PLAN.md`, `legal/LAUNCH_LEGAL_CHECKLIST.md`,
`legal/APP_REVIEW_NOTES.md`) stay as the why. This doc is the
order things have to happen in.

## Critical path — must finish before submission

Everything below blocks submission. Owner column says who has to
do each piece — anything marked **user** is a manual action no
script can take.

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Decide on Demo mode: keep or remove | **user** | open |
| 2 | SignInPrompt screen — wordmark, value prop, "Try Demo" button | code ✅ + **user visual check** | **done in code** |
| 3 | iOS Notification Service Extension (NSE) — needs Xcode UI | **user (Xcode)** | open (#279) |
| 4 | Privacy Policy + Terms public URLs published, app links them | **user** | **Enable GitHub Pages** (docs/ folder ready) |
| 5 | Privacy Policy / Terms / support email fields filled in | code ✅ | **done** — "Ilwon Yoon" set in PRIVACY_POLICY.md + TERMS_OF_SERVICE.md |
| 6 | Privacy Policy + Terms reachable from signed-out screen | code | open |
| 7 | App Store Connect privacy labels filled out | **user** | **draft ready** → `docs/APP_STORE_CONNECT_PASTE_SHEET.md` |
| 8 | App Review Notes finalized + demo flow described | code ✅ | **done** → `docs/APP_STORE_CONNECT_PASTE_SHEET.md` |
| 9 | Apple Distribution provisioning profile for `ai.steer.ios` | **user (Apple Portal)** | open (automatic signing in ExportOptions) |
| 10 | iOS bundle version bump (0.0.1 → 1.0.0) + Archive | user + code | version bump done in code; archive still needs distribution profile |
| 11 | Upload to App Store Connect via Xcode / Transporter | **user** | open |
| 12 | Screenshots (6.7" 1290×2796 required, 6.5" 1284×2778 recommended) | **user** | open |
| 13 | App Store description, keywords, what's new | code ✅ | **done** → `docs/APP_STORE_CONNECT_PASTE_SHEET.md` |

## Strong recommendations — fix before review but not strict blockers

| Item | Owner |
|---|---|
| Card-icon NSE for nicer banner (#277/#279) | user |
| Demo mode redact step (no real session ids in demo data) | code |
| Terminal-excerpt sync opt-in toggle in Settings | code |
| Mac iPhone Sync consent screen listing every synced field | code |

## What is OK to leave for v1.1

- Sparkle auto-update for Mac (already wired; needs key + appcast publish)
- iOS dark/light theme polish
- Demo reply animations
- Wrangler v4 upgrade

## Decisions waiting on user before I can code further

### Decision 1: Demo mode

App Review checklist requires the app to be reviewable *without
a live Mac*. Today there's a `Try Demo` button on the signed-out
screen that loads sample cards. Options:

- **Keep demo mode.** Status quo. Reviewer can tap Try Demo with
  zero setup. We finalize the sample data + add it to App Review
  Notes. Low risk.
- **Remove demo mode, ship credentialed review account.** Set up
  an Apple ID for App Review with a prepared Mac, hand the
  creds to Apple. Cleaner product, more operational burden,
  needs a Mac left running for the duration of review.

Recommend keep. Two hours of polish vs days of operational setup.

### Decision 2: SignInPrompt copy

Resolved for v1: wordmark plus two-line value prop.

- `Never let your AI sit idle.`
- `Set the course. Steer faster.`

The signed-out screen also exposes `Try Demo` so App Review can evaluate
the core reply flow without a live Mac.

### Decision 3: NSE

Xcode UI work that pbxproj-editing scripts can't do safely. Steps
in `docs/ICON_FIX_PLAN.md` section 4. ~15 min in Xcode. Without
NSE the banner shows the app icon instead of the per-provider
icon — still works, just less pretty.

### Decision 4: Custom Terms vs Apple standard EULA

Either pin our Terms in App Store Connect OR delete them and use
Apple's default. Apple's default is simpler; our custom adds
specific Mac/CLI clauses. Recommend Apple's default for v1 to
ship faster.

## Suggested order of operations (24h plan)

```
Hour 0–2:  user decisions 1, 2, 4 above
           code: signed-out Privacy/Terms links (item #6)
           code: SignInPrompt icon + copy (item #2)
Hour 2–4:  user: NSE in Xcode (item #3)
           user: fill operator name/email in legal docs (#4, #5)
Hour 4–5:  user: publish Privacy/Terms URLs (#4)
           code: app links them (already done; verify)
Hour 5–6:  user: Apple Distribution profile (#9)
           code: build script for App Store distribution (#10)
Hour 6–8:  user: take screenshots in Xcode simulator (#12)
           user: App Store Connect listing copy (#13)
Hour 8–9:  user: privacy labels (#7)
           user: Review Notes finalize (#8)
Hour 9–10: code + user: upload via Xcode / Transporter (#11)
Hour 10+:  submit
```

Items run in parallel where the owner is "code" — the user works
through their queue while I work through mine.

## What I'm starting on now without further decisions

These don't depend on user choices:

- Item #6: make Privacy / Terms reachable from the signed-out
  screen (currently only from settings, behind sign-in).
- Item #10: extend `build-mac-app.sh` pattern to a release iOS
  build script that takes a Distribution profile path and emits
  the .ipa.

If you'd rather I wait, say so. Otherwise I'll pick up #6 next.
