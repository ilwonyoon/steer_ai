# Harness Engineering Standard

Steer must be tested as a lifecycle product, not as a terminal renderer. The harness should keep the core promise intact: show the user the last actionable stopped report, let them reply, then stay quiet while the agent runs.

## Golden Behaviors

1. **Stop report opens a card**: Claude Stop hooks, Codex idle reports, and provider-native stopped events must create one active card.
2. **Direct terminal input is local only**: if the user types in the terminal, Steer must not mirror, summarize, notify, or create a card from that terminal interaction.
3. **Wrapper preserves CLI usability**: `steer codex` and `steer claude` must preserve normal prompt behavior, Enter handling, wrapping, colors, and line breaks.
4. **Stopped report preserves the final block**: provider-native `lastAssistantMessage` / final report text is the source of truth and should be preserved as raw text plus display lines. Current automatic display cap is 120 lines with an explicit trim marker above that.
5. **Progress noise is filtered**: `Working`, `Ran`, `checking`, elapsed time/status repaint, token counters, prompt chrome, and MCP startup boilerplate should not become action-card content.
6. **Terminal rendering remains readable**: no horizontal scrolling in Steer cards, no user input echo, no broken ANSI fragments, and no clipped normal-length final reports.
7. **Mac app stays stable**: DB polling must not hang, disconnected cards must disappear, and repeated repaint/status updates must not create repeated notifications.

## Automated Harness

Run this before every change touching wrappers, hooks, classifier, card loading, notifications, terminal rendering, or SQLite access:

```sh
scripts/verify-steer-regression.sh
```

This wraps:

- `npm test`
- `swift build --package-path apps/mac`
- `scripts/build-mac-app.sh`

Current automated coverage:

- Stop hook creates an active action card.
- Reply closes the active card and next stopped report reopens it.
- Disconnected sessions produce no active cards.
- Raw PTY repaint alone cannot create an active card.
- Codex idle prompt can produce a report only after the prompt returns.
- Codex startup/progress noise is filtered.
- Multiline instructions preserve wrapper Enter behavior.
- Normal-length final report blocks are not truncated.

## Manual Dogfood Checklist

1. Start `steer codex`; startup alone should not create a noisy terminal mirror card.
2. Type directly in the terminal; Steer should stay quiet.
3. Send from Steer; the current card should close and the terminal should receive the text plus Enter.
4. Wait for the AI to stop; exactly one card should open with the final meaningful report.
5. Check that `Working`, `Ran`, `checking`, elapsed time, and prompt chrome are absent from the card.
6. Close the terminal; disconnected cards should disappear without repeated notifications.

## Known Boundary

The boundary is clear for provider-native events: Claude `last_assistant_message`, Codex app-server turn output, and hook payloads are authoritative. The boundary is heuristic for raw interactive PTY because TUIs repaint screens and echo user input. PTY is therefore allowed only as a limited idle detector; it must never become a live terminal sync surface.
