# Steer testing

Three layers, each commit runs at least the first two:

## 1. Unit and contract tests (always run)

```sh
npm test
```

Covers:

- `packages/agent/test/classifier.test.js` — every category branch of the classifier with real transcript fragments.
- `packages/agent/test/lifecycle_contract.test.js` — agent store lifecycle (Stop hook, reply resolution, disconnect).
- `packages/agent/test/visibility_gate.test.js` — Mac SQL gate executed in-process. Regresses any drift in `apps/mac/Sources/SteerMac/LocalSteerStore.swift`.
- `packages/agent/test/hook_event.test.js` — Claude Stop hook payload normalization.
- `packages/cli/test/cancel_keys.test.js` — Esc / Ctrl-C byte-level detection.
- `packages/cli/test/attachments.test.js` — `[attached image] <path>` formatter.
- `packages/cli/test/codex_session_reader.test.js` — Codex JSONL session log tail.
- `packages/cli/test/hooks.test.js` — `~/.claude/settings.local.json` writer.
- `packages/cli/test/pty_input.test.js` — bracketed-paste injection format.
- `packages/cli/test/pty_idle.test.js` — Claude PTY idle report extraction.

These are pure-process tests with no PTY, no socket, no real binaries. They run in well under 5 seconds.

## 2. Integration tests (gated, fast-ish)

```sh
npm run test:integration
```

These boot a real `SteerAgent`, run a real `steer wrap -- node fake_provider.js`, and exercise the wrapper / agent / classifier / store stack against an isolated `STEER_HOME` per test.

- `packages/cli/test/wrapper_invariant.test.js` — five invariants:
  - Register surfaces a ready card.
  - Stdin keystroke flips state to running.
  - Esc keystroke flips state to waiting.
  - A long-running turn keeps the card hidden; Stop re-surfaces it.
  - PTY-only repaint never counts as semantic traffic.
- `packages/cli/test/reconnect_invariant.test.js` — three failure modes:
  - Reply-box send forces state=running on the receiving session.
  - Agent SIGKILL leaves a stale socket; the wrapper auto-recovers.
  - Agent graceful restart preserves run_state on reconnect.
- `packages/cli/test/coding_session_e2e.test.js` — a 3-turn coding session with mid-turn cancel.

Integration tests use the real `node-pty` PTY layer and real Unix sockets, so they only run on macOS / Linux and require Node ≥ 22.5. The `STEER_INTEGRATION=1` environment variable gates them so `npm test` stays cheap; CI runs both.

Each test cleans up its `STEER_HOME` and kills any spawned wrappers / agent in `t.after()`. If a test crashes mid-run and leaves something behind, the OS tmpdir reaper catches it; in the meantime `pgrep -f 'steer-test-'` shows what's left.

## 3. Mac end-to-end (manual, occasional)

`docs/MAC_UI_E2E.md` documents the AppleScript flow against a foreground SteerMac. There is no XCUITest target yet. We run this manually before any release that touches Mac UI behaviour.

## 4. iOS XCUITest (`SteerUITests`)

`apps/ios/SteerIOSUITests/CardFlowUITests.swift` drives the simulator end-to-end. From the repo root:

```sh
cd apps/ios && xcodegen generate   # only when project.yml changed
xcodebuild test \
  -project apps/ios/Steer.xcodeproj \
  -scheme Steer \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SteerUITests
```

Three things make this work:

1. **`--uitest` launch argument.** `SyncInbox.fixtureModeEnabled` honors `ProcessInfo.processInfo.arguments.contains("--uitest")` in addition to the existing `STEER_FIXTURES=1` env var. Every UI test sets `app.launchArguments = ["--uitest"]` so the app skips Sign in with Apple (the system Apple ID sheet is owned by another process and cannot be driven by XCUITest), loads a fake user, and seeds the sample cards from `SyncInboxFixtures.swift`.
2. **Accessibility identifiers, applied to leaves.** `reply-input` is on the `TextField`, `reply-send` on the `Button`. `inbox-content` is on the inbox root container. **Don't** apply `.accessibilityIdentifier()` to a card-shaped container: SwiftUI cascades the identifier to every subview and overwrites the child identifiers, which silently breaks `reply-input` / `reply-send` lookups.
3. **System TabBar buttons use SF Symbol labels.** Applying an identifier inside `.tabItem { Image(systemName: ...) }` does not survive — the system rewrites the button label to the symbol's accessibility name (e.g. `rectangle.stack.fill` becomes "Album"). Tests address tabs positionally via `app.tabBars.firstMatch.buttons.element(boundBy: 0)`.

Why XCUITest rather than Maestro or fastlane snapshot: XCUITest ships with Xcode, runs entirely from `xcodebuild` without a separate runtime, and the test sources sit next to the app target so they're version-locked to the SwiftUI changes that motivate them. fastlane snapshot is XCUITest underneath but is screenshot-oriented. Maestro is a YAML driver maintained outside Apple and would add a second toolchain for very little gain at our current scope.

## Adding a new test

When fixing a bug:

1. **Write the integration test that would have caught it first.** If the bug is in the wrapper / agent path, add a case to `wrapper_invariant.test.js` or `reconnect_invariant.test.js`. If it is in the SQL gate, add a row to `visibility_gate.test.js`.
2. **Confirm the test fails on the bug branch.** Roll back the fix, run the relevant suite, see the assertion break.
3. **Re-apply the fix and confirm the test passes.**

The fake provider at `packages/cli/test/helpers/fake_provider.js` accepts a JSON plan via `STEER_FAKE_PLAN`. Each plan turn can specify `responseBytes`, `responseDelayMs`, `ptyRepaints`, and a `preamble` string. To imitate a real Claude / Codex turn closely, give it 8–30 KB of body, 1–4 seconds of delay, and a few PTY repaints sprinkled across the duration. The harness in `packages/cli/test/helpers/harness.js` exposes `setPlan`, `spawnWrappedSession`, `sendInstruction`, `fireStopHook`, `stopAgent`, and `waitFor` — most new scenarios can be expressed in five or six harness calls.

## Pre-merge gate

`scripts/verify-steer-regression.sh` should run `npm test`, `npm run test:integration`, `swift build --package-path apps/mac`, and `scripts/build-mac-app.sh` before any commit that touches the wrapper, classifier, Mac card loading, notifications, or terminal rendering.
