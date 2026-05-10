# Marketing Copy Audit

Last run: 2026-05-10

## Goal

Per EXECUTION_PLAN Phase 7 (App Store review gate), ensure no
user-facing copy in the iOS app, Mac app, App Store metadata, or
release notes uses framing that triggers App Review guideline 4.2.7
(remote desktop / remote terminal).

Banned phrases (used in this audit grep):

- `remote terminal`
- `remote shell`
- `remote desktop`
- `control your terminal` / `control your Mac terminal`
- `run commands from iPhone`
- `terminal mirror` / `terminal mirroring`

Preferred replacements:

- "AI coding action inbox"
- "review waiting agent cards"
- "queue replies to your own Mac sessions"
- "Mac handles local delivery"

## 2026-05-10 Result

### iOS / Mac user-facing strings

Searched `apps/ios/SteerIOS/` and `apps/mac/Sources/` for all banned
phrases.

Result: **clean**. Zero hits in any user-visible string.

### Documentation hits

Hits in repo-level documentation are all either:

1. The guidelines themselves (EXECUTION_PLAN, CROSS_DEVICE_ONBOARDING_PLAN,
   IOS_PRE_CONNECTION_ONBOARDING, LAUNCH_LEGAL_CHECKLIST, IOS_LAUNCH_PLAN)
   — these *use* the banned phrases to say "do not use".
2. Negation statements like "Steer is not a live terminal mirror"
   (README.md, CLAUDE.md, docs/TECH_SPEC.md, docs/CLASSIFIER_CONTRACT.md,
   docs/legal/TERMS_OF_SERVICE.md) — these explicitly clarify the
   product is *not* the banned thing, which is a positive defensive
   signal for App Review.

No documentation hits need rewriting.

## Re-running

```sh
for term in "remote terminal" "remote shell" "remote desktop" \
            "control your terminal" "control your mac terminal" \
            "run commands from iphone" "terminal mirror" "terminal mirroring"; do
  echo "--- '$term' ---"
  grep -ri "$term" \
    --include="*.swift" --include="*.md" --include="*.ts" --include="*.js" --include="*.json" \
    --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=DerivedData --exclude-dir=.git \
    .
done
```

Run before every TestFlight or App Store submission. Update this
file when banned phrases are added or removed.
