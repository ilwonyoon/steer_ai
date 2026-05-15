# Cowork Handoff — App Store Submission for Steer v1.0.0

This is a self-contained work order for a Claude cowork session
that will drive the iOS App Store submission to the point of
"Submit for Review."

The cowork is NOT making product decisions. Every piece of copy,
every screenshot frame, every privacy answer has already been
decided. The cowork's job is mechanical: upload the build,
generate the screenshots, paste the metadata, confirm the
Submit button is enabled.

If you find yourself wanting to rewrite a screenshot caption,
shorten the description, or change the subtitle — stop. Read
`docs/APP_STORE_SUBMISSION_MARKETING_PACK.md` first. That doc
explains WHY each line is what it is, and any change to copy
has to come back through the human owner.

---

## Pre-flight: what is already true

You inherit a green state. Do not redo any of this.

- ✅ `.build/ios-appstore/export/Steer.ipa` exists and was built
  from `main` at commit `19bb22e` or later. Version 1.0.0, build 1.
- ✅ Marketing site is live:
    - `https://ilwonyoon.github.io/steer_ai/`
    - `https://ilwonyoon.github.io/steer_ai/privacy/`
    - `https://ilwonyoon.github.io/steer_ai/terms/`
    - `https://ilwonyoon.github.io/steer_ai/support/`
- ✅ Mac v0.2.0 DMG is live on GitHub Releases.
- ✅ Relay is deployed with `responseRevision` wired end-to-end.
- ✅ Account/data deletion is wired in Settings.
- ✅ Try Demo flow works on the signed-out screen.

If any of those are NOT true when you start, STOP and surface it
to the human owner before doing anything else. Don't try to
"fix" the missing piece — that means the prerequisite branch
hasn't landed and the submission isn't actually ready.

---

## Single source of truth for every value

When you're about to paste something into App Store Connect,
the value comes from EXACTLY ONE of these files:

| Form section | File |
|---|---|
| App Information, URLs, Promotional Text, Keywords, Description, What's New, Review Notes, Screenshots | `docs/APP_STORE_CONNECT_PASTE.md` |
| App Privacy answers | `docs/legal/APP_STORE_PRIVACY_LABELS.md` |
| Why each line of copy reads the way it does | `docs/APP_STORE_SUBMISSION_MARKETING_PACK.md` |
| Screenshot capture script | `scripts/capture-app-store-screenshots.sh` |

If the cowork can't find the value in one of these files, STOP.
Do not improvise.

---

## Cowork work order — six phases

Run them in order. Each phase has a defined "you can move on
when…" gate. Do not move on until the gate is green.

### Phase 1 — Re-verify the IPA is current

```sh
cd /Users/ilwonyoon/Documents/Steer_ai
git rev-parse HEAD                         # should be on main
git status                                 # should be clean
ls -la .build/ios-appstore/export/Steer.ipa # should exist, > 1 MB
```

If the IPA is missing or older than the latest `main` HEAD,
rebuild it before starting:

```sh
bash scripts/build-ios-appstore.sh
```

**Gate to move on:** `.build/ios-appstore/export/Steer.ipa` is
present and the file timestamp is newer than any commit on
`main` that touches `apps/ios/`.

### Phase 2 — Upload the IPA to App Store Connect

Use one of the two options below. Option A (Xcode Organizer) is
safer if you're unsure. Option B (CLI) is faster if you have an
API key already stored.

#### Option A — Xcode Organizer (recommended)

1. Open Xcode → `Window` → `Organizer` → `Archives` tab.
2. Select the most recent `Steer.xcarchive` (it should be the one
   matching the IPA timestamp from Phase 1).
3. Click `Distribute App` → `App Store Connect` → `Upload`.
4. Accept automatic signing, automatic provisioning, the team
   `LG7667PAS6` (Ilwon Yoon).
5. Wait for the upload to finish (~3–5 minutes).
6. You should see "Upload successful" in the Organizer.

#### Option B — altool CLI

```sh
xcrun altool --upload-app \
  -f .build/ios-appstore/export/Steer.ipa \
  --type ios \
  --apiKey <KEY_ID> \
  --apiIssuer <ISSUER_UUID>
```

API credentials live in 1Password under "App Store Connect API
Key" (if you cannot find them, fall back to Option A).

**Gate to move on:** The Apple "Your build has been processed"
email arrives (5–15 min after upload). The build also appears
in App Store Connect → My Apps → Steer → TestFlight tab with
status "Ready to Submit" (yellow exclamation is fine; we'll
clear it next).

### Phase 3 — Generate the five screenshots

The capture script automates simulator boot, app install, status
bar override, and PNG capture. The script will pause at each
shot with a prompt telling you what to set up on screen.

```sh
bash scripts/capture-app-store-screenshots.sh
```

For each of the five prompts:

1. Read the prompt. It tells you exactly what state the app
   must be in.
2. Drive the iPhone simulator window to that state (the cowork
   needs Accessibility / Screen Recording permissions to actually
   click in the simulator if you want to fully automate; otherwise
   the human owner can drive the sim while you watch).
3. Press Enter in the script's terminal to capture.

The five shots, in order, with their gate states:

| # | Label | State the simulator must be in |
|---|---|---|
| 1 | `01-your-ai-codes-you-answer` | Signed-out SignInPrompt screen. Sign in with Apple, Try Demo, and the legal links are all visible. No tutorial card. |
| 2 | `02-phone-shows-up-when-agent-stops` | Inbox with one or two waiting cards. Skip the tutorial first. Provider glyph, project label, and a short summary line must be on screen. |
| 3 | `03-answer-like-text` | Same card from shot 2, with the reply field focused and the keyboard up. Either a suggested-reply chip is highlighted, or the field has a short typed line. Do NOT send. |
| 4 | `04-back-to-empty` | Connected empty state right after every waiting card has been answered. The `N running` chip is visible. The green checkmark glyph must be at its FINAL resting frame. |
| 5 | `05-no-code-no-terminal` | Settings screen with identity row, Notifications, Report an Issue, Support, Privacy Policy, Terms, Sign Out, and Delete Account all visible. |

The PNGs land under `apps/ios/build/screenshots/iPhone_17_Pro_Max/`.

**Do not edit the PNGs.** The overlay headline + subline goes on
top during the Figma export, not on the simulator PNG. (See
"Phase 4" for the overlay pass.)

**Gate to move on:** All five PNGs exist, each is `1320 × 2868`,
the status bar in each PNG reads `9:41` with full Wi-Fi/cellular
and 100% battery.

### Phase 4 — Add the overlay copy

For each PNG, add the headline + subline overlay above the phone
frame. The headline and subline copy is the value pasted into the
"Overlay headline" / "Overlay subline" columns of the Screenshots
table in `docs/APP_STORE_CONNECT_PASTE.md`.

Visual rules (matches App Store norms for productivity apps):

- White or very-light background canvas, plain.
- Headline: large sans-serif, ~80–100pt, dark text.
- Subline: same family, ~32–40pt, gray (`#666` or similar).
- Phone frame: centered horizontally, occupies the bottom
  ~65–75% of the canvas.
- Do not crop the phone frame. The status bar, the cards, and
  the bottom rounded corners must all be inside the canvas.
- Do not put two phones side by side. One phone per shot.
- Final canvas size: `1320 × 2868`.

Tools: Figma + a Steer template (ask the human owner for the
template if you don't already have it), or any image editor that
can export at the required resolution.

Save the final overlaid PNGs to a new folder:

```
apps/ios/build/screenshots/app-store-final/
  01-your-ai-codes-you-answer.png
  02-phone-shows-up-when-agent-stops.png
  03-answer-like-text.png
  04-back-to-empty.png
  05-no-code-no-terminal.png
```

**Gate to move on:** All five overlaid PNGs exist at the final
folder above, each is exactly `1320 × 2868`, opening any of
them in Preview reads as "headline up top, phone in the middle,
not cut off."

### Phase 5 — Fill in App Store Connect

Open App Store Connect → My Apps → Steer → iOS 1.0.0.

For every field in the iOS 1.0.0 form, paste the corresponding
value from `docs/APP_STORE_CONNECT_PASTE.md`. Do NOT change a
single character. The doc is the source of truth.

Order to fill in, matching the App Store Connect form:

1. App Information section (top of the version page):
   - Subtitle → `Your AI codes. You answer.`
   - Promotional Text
   - Description
   - Keywords
   - Support URL
   - Marketing URL
   - Copyright

2. Build section: attach the build that finished processing in
   Phase 2. Confirm the version number is `1.0.0` and the build
   number is `1`.

3. Screenshots section: upload the five PNGs from Phase 4 to the
   6.9-inch iPhone slot. The order must match the table in
   `APP_STORE_CONNECT_PASTE.md` — App Store Connect respects the
   upload order.

4. App Review Information section:
   - Sign-in required: Yes.
   - Demo account: leave blank ("not required").
   - Notes: paste the "Notes for Review" block verbatim from
     `APP_STORE_CONNECT_PASTE.md`.
   - Contact First Name / Last Name / Email / Phone: as
     specified.

5. App Privacy section: open `docs/legal/APP_STORE_PRIVACY_LABELS.md`
   and answer each question with the exact value listed there.
   Do not improvise. If a question in the form doesn't appear in
   the labels file, STOP and surface it.

6. Version Release: leave on "Automatically release this version"
   unless the human owner says otherwise.

7. What's New: paste the v1.0.0 What's New from
   `APP_STORE_CONNECT_PASTE.md`. Same rule — paste verbatim.

**Gate to move on:** Every field on the iOS 1.0.0 form has a
green checkmark. The "Submit for Review" button is enabled.

### Phase 6 — Pre-submission verification

Before clicking Submit for Review, run through this checklist
end-to-end:

```
- [ ] Marketing, Support, Privacy, Terms URLs return 200 in a
      fresh incognito window.
- [ ] The Description does not contain any forbidden phrase:
      "remote terminal", "remote shell", "remote desktop",
      "screen mirror", "control your Mac", "mobile IDE".
      (App Review treats those as red flags.)
- [ ] The subtitle is `Your AI codes. You answer.` and not the
      legacy `Never let AI sit idle`.
- [ ] All five screenshots are in the 6.9" slot, in the order
      1 → 2 → 3 → 4 → 5.
- [ ] App Privacy answers match `APP_STORE_PRIVACY_LABELS.md`
      to the letter.
- [ ] The build attached to 1.0.0 is the one from this
      submission session, not a previous TestFlight build.
- [ ] Notes for Review include the "Target user note" line
      that names "vibe coders / non-engineers".
- [ ] Notes for Review include the "no live terminal / no
      remote shell / no remote desktop / no command launcher"
      block.
- [ ] Try Demo really works in the Build's TestFlight slot
      (install the build on a real device or simulator and
      run the demo carousel + reply once + back-to-empty).

When every box is checked, click **Submit for Review**.
```

**Final gate:** "Waiting for Review" appears on the version
page in App Store Connect.

---

## What to do if Apple rejects

If App Review rejects v1.0.0, copy the rejection message
verbatim into a new file under `docs/app-store-rejections/` and
STOP. Do not start changing copy yourself. The human owner will
read the rejection and decide whether it's a copy fix, a code
fix, or a privacy-answer fix.

The common rejection categories for this app's framing are
documented in `docs/APP_STORE_SUBMISSION_MARKETING_PACK.md`
under "Rejection Risk Controls", but those are predicted risks.
The actual rejection message is the source of truth.

---

## What to do if you get stuck

If any phase is blocked for > 15 minutes:

1. Capture the exact symptom (screenshot the App Store Connect
   error, copy the terminal output).
2. Do not click "Submit for Review" if any of the gates above
   is still red.
3. Surface the block to the human owner. Include:
   - which phase you're in,
   - what the gate says,
   - the literal error message you saw.

The human owner will decide whether to unblock, defer, or
postpone the submission.

---

## Hard rules — do not break any of these

1. Do not change a single character of the copy that lives in
   `docs/APP_STORE_CONNECT_PASTE.md`. If the copy needs editing,
   surface it to the human owner first.
2. Do not crop or recolor the screenshots. Don't add framing
   text inside the phone capture itself.
3. Do not click "Submit for Review" while any of the Phase 6
   checklist boxes is unchecked.
4. Do not enable "Manually release this version" without the
   human owner saying so.
5. Do not submit on a Friday after 6pm Pacific. App Review can
   come back at any hour, and a Saturday rejection sits all
   weekend.
6. Do not skip the privacy labels step. If you cannot find
   `docs/legal/APP_STORE_PRIVACY_LABELS.md`, STOP.

---

## Glossary, in case the cowork is missing context

- **codex** / **claude** — the two AI coding agents Steer wraps.
  Codex = OpenAI Codex CLI. Claude = Anthropic's Claude Code CLI.
  Steer is not affiliated with either.
- **steer CLI** — the Mac-side companion. Wraps a coding-agent
  session with `steer codex` or `steer claude`. Installs via the
  Mac DMG on GitHub Releases (v0.2.0+).
- **action card** — the iPhone surface unit. One stopped agent
  moment per card. The user replies, the card resolves.
- **inbox** — the iPhone home screen. Empty by default, fills
  only when an agent stops with a question.
- **agent runs** — codex/claude sessions in the user's Mac
  terminal. They keep running between cards.
- **vibe coder** — the explicit target user. People who delegate
  most coding work to AI and only step in to make decisions. Not
  the same as a developer driving a mobile IDE.

If a term in the App Store Connect form is unfamiliar, ask the
human owner before guessing.
