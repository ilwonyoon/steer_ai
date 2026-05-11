# Sparkle appcast.xml — execution plan

What this delivers: Steer.app, once installed, checks a public
appcast.xml on every launch and silently downloads + offers to
install newer DMGs. Currently Sparkle ships inside the bundle but
stays dormant because `SparkleEnabled` / `SUFeedURL` /
`SUPublicEDKey` aren't set in Info.plist.

Three pieces have to line up:

1. **A signing key pair.** `generate_keys` produces an EdDSA pair.
   The public key gets baked into every shipped bundle; the private
   key never leaves the release machine + GitHub Secrets.
2. **A public URL the app polls** for the appcast XML.
3. **Two values flowed into `build-mac-app.sh`** as env vars so
   `SUFeedURL` and `SUPublicEDKey` land in the bundle's Info.plist.

## Step 1 — Generate the EdDSA key pair (one-time)

On the release machine:

```sh
# generate_keys writes the private key into the macOS keychain and
# prints the public half to stdout. Don't pipe it anywhere we'd
# accidentally commit.
swift run --package-path apps/mac generate_keys
# Or if SwiftPM hasn't fetched the tool: run from the checkouts dir
apps/mac/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

Save the printed `SUPublicEDKey` value somewhere secure (1Password
note labelled "Steer Sparkle public key"). The private half lives
in `~/Library/Keychains/login.keychain-db` under the account
`ed25519`.

Add `generate_keys` output to GitHub Secrets:

```sh
# The public key — safe to ship publicly, but easier to manage as a
# secret alongside the other release secrets.
echo -n '<base64 public key>' | gh secret set SPARKLE_PUBLIC_ED_KEY --repo ilwonyoon/steer_ai

# Export the private key so CI can sign updates. generate_keys can
# round-trip via the keychain; we want the raw 64-byte base64.
apps/mac/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p > /tmp/sparkle_priv.txt
# Strip whitespace, then:
gh secret set SPARKLE_PRIVATE_ED_KEY --repo ilwonyoon/steer_ai < /tmp/sparkle_priv.txt
shred -u /tmp/sparkle_priv.txt  # or `rm` if shred isn't installed
```

## Step 2 — Pick the appcast URL

Cheapest path: GitHub Pages on the repo's `gh-pages` branch.

- URL: `https://ilwonyoon.github.io/steer_ai/appcast.xml`
- Setup: Settings → Pages → Source = `gh-pages` branch, /(root)
- The release workflow writes a fresh `appcast.xml` to that branch
  on every published tag.

Alternative: drop the XML alongside the DMG in the GitHub Release
itself. Cleaner provenance, but Sparkle has to follow redirects and
GH Releases occasionally rate-limits unauthenticated polls.

Decision needed before step 3 — defaulting to gh-pages below.

## Step 3 — Wire Sparkle config into the build

`scripts/build-mac-app.sh` already emits `SparkleEnabled` /
`SUFeedURL` / `SUPublicEDKey` keys when both env vars are set:

```sh
SPARKLE_FEED_URL="https://ilwonyoon.github.io/steer_ai/appcast.xml" \
SPARKLE_PUBLIC_ED_KEY="<key from step 1>" \
bash scripts/build-mac-app.sh
```

For CI, add the two values to `.github/workflows/release.yml`'s
build step so every tagged release ships them:

```yaml
- name: Run release-mac.sh
  env:
    STEER_NOTARY_PROFILE: steer-notary
    APP_VERSION: ${{ steps.tag.outputs.version }}
    PROVISIONING_PROFILE: ${{ steps.profile.outputs.path }}
    SPARKLE_FEED_URL: https://ilwonyoon.github.io/steer_ai/appcast.xml
    SPARKLE_PUBLIC_ED_KEY: ${{ secrets.SPARKLE_PUBLIC_ED_KEY }}
  run: bash scripts/release-mac.sh
```

## Step 4 — Sign + publish each release

After `release-mac.sh` produces the notarized DMG, sign it with the
EdDSA private key and append an entry to `appcast.xml`:

```sh
DMG=".build/release/Steer-$(APP_VERSION).dmg"
SIG=$(apps/mac/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update "$DMG")

# Append a new <item> to appcast.xml — generate_appcast handles this
# from a directory of DMGs, but for a single-DMG-per-tag flow it's
# simpler to template the XML by hand.
cat >> /tmp/new-item.xml <<EOF
<item>
  <title>Version $APP_VERSION</title>
  <pubDate>$(date -R)</pubDate>
  <enclosure
    url="https://github.com/ilwonyoon/steer_ai/releases/download/v$APP_VERSION/$(basename "$DMG")"
    sparkle:version="$APP_BUILD"
    sparkle:shortVersionString="$APP_VERSION"
    $SIG
    length="$(stat -f %z "$DMG")"
    type="application/octet-stream" />
</item>
EOF

# Splice it into the gh-pages branch's appcast.xml, push.
```

Wire this into the release workflow as a separate step after the
existing notarize/publish — it's the only one that touches a
different branch (`gh-pages`).

## Step 5 — Verify

1. Build a v0.1.x DMG with the new env vars.
2. Confirm `defaults read /path/to/Steer.app/Contents/Info.plist SUFeedURL` returns the URL.
3. Open Steer, then **Check for Updates** in the menu (Sparkle adds
   the menu item automatically when enabled). It should report
   "Up to date" against the current tag.
4. Cut a v0.1.(x+1) DMG with no Sparkle config changes.
   `appcast.xml` gets a new `<item>` via step 4. Re-open the v0.1.x
   Steer.app and confirm it offers to upgrade.

## Open decisions

- gh-pages vs releases-only hosting?
- Auto-update default: silent install (preferred) vs notify-only?
  Default Sparkle config asks the user; flip via Info.plist
  `SUAutomaticallyUpdate=YES` once we have at least one successful
  upgrade in the wild.
- Skip versions / channel support? Not for v1.
