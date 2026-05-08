# Release Process — SteerMac

Direct-distribution release pipeline for the macOS app: signed with a Developer ID Application certificate, notarized through Apple's notary service, packaged into a `.dmg`. The Mac App Store path is intentionally out of scope; see the "MAS Out Of Scope" entry in `EXECUTION_PLAN.md` for the rationale.

## One-time setup on the release machine

The release machine is whichever Mac actually runs `scripts/release-mac.sh`. Today that is a personal workstation; a CI runner is fine later.

### 1. Apple Developer Program

- Membership active under ILWON YOON (the same account that ships Backtick).
- Recorded values:

  ```
  Team ID:                         LG7667PAS6
  Apple ID for Apple Developer:    ilwonyoon@gmail.com
  Apple ID for App Store Connect:  ilwonyoon@gmail.com
  Bundle Identifier (Mac app):     ai.steer.mac
  ```

- Steer's Bundle ID is `ai.steer.mac`. If the App ID has not yet been registered in Apple Developer → Certificates, Identifiers & Profiles → Identifiers, register it once before the first signed build (no special capabilities required for v1 — no iCloud, no push, no associated domains).

### 2. Developer ID Application certificate

This is the signing identity for direct-distribution apps. **Not** the "Apple Distribution" certificate — that one is for the Mac App Store and will not satisfy notarization for direct .dmg distribution.

The same Developer ID Application certificate already issued for Backtick is reusable for Steer — Apple binds these to a Team, not a single bundle ID, so we do not need to enroll a second certificate.

Verify on this machine:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Today this returns two valid certificates under `Developer ID Application: ILWON YOON (LG7667PAS6)`. Either works; the release script auto-picks the first non-revoked match. To pin a specific cert, export `STEER_SIGN_IDENTITY` to its full name string before running the release script.

### 3. App-specific password for notarytool

`notarytool` needs an Apple ID + app-specific password (or an App Store Connect API key — equivalent for our purposes). The password approach is simpler:

1. Sign in at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords → generate one labelled `steer-notary`.
2. Stash it in the local keychain so the release script never sees the plaintext password:

   ```sh
   xcrun notarytool store-credentials steer-notary \
     --apple-id "<your-apple-id>" \
     --team-id "<TEAMID>" \
     --password "<the-app-specific-password>"
   ```

   The profile name `steer-notary` is what the release script consumes via `STEER_NOTARY_PROFILE`.

### 4. Optional: `create-dmg`

The release script falls back to `hdiutil` if `create-dmg` is missing, but `create-dmg` produces a much nicer installer window:

```sh
brew install create-dmg
```

## Cutting a release

```sh
# 1. Make sure the working tree is clean.
git status

# 2. Tag the release. Tags drive the version embedded in the bundle.
git tag v0.1.0
git push origin v0.1.0

# 3. Run the release script. With no environment overrides, the script picks
#    the first valid Developer ID Application identity from the keychain and
#    uses STEER_NOTARY_PROFILE if set, falling back to "steer-notary".
bash scripts/release-mac.sh

# To pin a specific cert / notary profile:
# export STEER_SIGN_IDENTITY="Developer ID Application: ILWON YOON (LG7667PAS6)"
# export STEER_NOTARY_PROFILE="steer-notary"
```

Output lands in `.build/release/`:

- `SteerMac.app`  — stapled, signed bundle
- `Steer-<version>.dmg` — stapled, signed installer

Test the artifact on a clean machine (or at least a fresh user account) before publishing:

```sh
spctl --assess --type open --context context:primary-signature .build/release/Steer-*.dmg
```

Should print `accepted` and the source as `Notarized Developer ID`. If it does not, fix the issue before shipping.

## Hardened runtime entitlements

Live config at `apps/mac/Steer.entitlements`. Start minimal; only add an entitlement when something actually fails under hardened runtime. Today's set:

- `com.apple.security.cs.allow-jit` — for any node-pty / Python pty fallback that JITs.
- `com.apple.security.cs.allow-unsigned-executable-memory` — same reason.

If the wrapper ever needs to load a non-Apple-signed dylib, add:

- `com.apple.security.cs.disable-library-validation`

If the agent process needs to attach to other PTYs in a way Apple's runtime restricts, audit the failure with `log stream --predicate 'eventMessage contains "SteerMac"'` before adding broad entitlements.

## Updating an existing release

The Sparkle integration (Phase 6 P1, not yet wired up) will consume an `appcast.xml` hosted on GitHub Releases. Until that lands, an "update" is just: cut a new tag, run the script, attach the new `.dmg` to a GitHub release manually, and announce it.

## Troubleshooting

- **`xcrun notarytool submit` hangs in `In Progress`** — Apple's queue is occasionally slow. The `--wait` flag will block; let it. If it errors, run `xcrun notarytool log <submission-id> --keychain-profile steer-notary` for the rejection reason.
- **`spctl assess` says `rejected`** — confirm the bundle is stapled (`xcrun stapler validate <path>`). If not stapled, the staple step earlier in the script failed silently; rerun the release script.
- **Gatekeeper still warns the first time** — that is normal for a freshly notarized app on a machine that has never seen this developer ID. Right-click → Open once; macOS records the trust decision.
- **node-pty `spawn-helper` fails to launch** — check `xattr` for `com.apple.provenance` on the helper inside `node_modules`. Notarization should clear quarantine on the bundle, but a stale helper sitting on the user's machine before the install can keep the attribute. Document in the first-run UX that a clean install path is best.
