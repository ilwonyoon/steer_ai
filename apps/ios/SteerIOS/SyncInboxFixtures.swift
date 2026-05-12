import Foundation
import SteerCore

/// Sample cards used in two places:
///   * The Try Demo path that Apple App Review needs to evaluate
///     the product without a working Mac.
///   * The fixture path the simulator + XCUITest use to iterate
///     UI work without standing up Sign in with Apple.
///
/// Four cards, English-only, all the same visual treatment. They
/// double as onboarding — card 1 explains how the inbox works,
/// cards 2 and 3 show what real waiting sessions look like, card
/// 4 is the explicit exit toward Sign in with Apple.
enum SyncInboxFixtures {
    static func cards() -> [CardPayload] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            // Card 1 — welcome + how-to. Reads like a card from
            // a friendly teammate. Reply options demonstrate that
            // chips are real interactive controls.
            CardPayload(
                cardId: "demo-welcome",
                sessionId: "demo-welcome",
                category: "waiting",
                priority: "normal",
                title: "Welcome to Steer",
                summary: "This is what an action card looks like.",
                actionPrompt: "Tap a chip below or type your own reply.",
                payload: [
                    "provider": AnyCodable(("claude")),
                    "project": AnyCodable(("Welcome")),
                    "branchLabel": AnyCodable(("main")),
                    "options": AnyCodable(([
                        "Looks good",
                        "Tell me more",
                        "Skip this"
                    ])),
                    "terminalLines": AnyCodable(([
                        "Steer surfaces a card whenever a CLI coding agent on your Mac stops and needs your input.",
                        "",
                        "From this screen you can:",
                        "  • Read the last few lines of terminal output",
                        "  • Tap a suggested chip to reply instantly",
                        "  • Type a custom reply in the field below",
                        "",
                        "When you connect your Mac, real waiting sessions appear here in the same shape."
                    ]))
                ],
                state: "active",
                createdAt: now - 4_000,
                updatedAt: now - 4_000
            ),

            // Card 2 — Claude waiting on a routing decision in a
            // real-feeling repo. No category label visible to the
            // user; the card UI is identical to every other card.
            CardPayload(
                cardId: "demo-claude-routing",
                sessionId: "demo-claude-routing",
                category: "question",
                priority: "normal",
                title: "Claude is asking",
                summary: "Should the new endpoint live under /v1/users or /v1/accounts?",
                actionPrompt: "Pick one or send your own direction.",
                payload: [
                    "provider": AnyCodable(("claude")),
                    "project": AnyCodable(("acme-api")),
                    "branchLabel": AnyCodable(("feat/account-export")),
                    "options": AnyCodable(([
                        "Use /v1/users",
                        "Use /v1/accounts",
                        "You decide"
                    ])),
                    "terminalLines": AnyCodable(([
                        "We already have /v1/users/:id for profile reads.",
                        "The new export endpoint touches the same row but ships every",
                        "field, including billing. Two options on the table:",
                        "",
                        "  /v1/users/:id/export       — keeps the resource grouping",
                        "  /v1/accounts/:id/export    — separates billing-ish surfaces",
                        "",
                        "Either is fine but the team should pick once before we wire",
                        "the route into the client SDKs."
                    ]))
                ],
                state: "active",
                createdAt: now - 3_000,
                updatedAt: now - 3_000
            ),

            // Card 3 — Codex blocked on a missing env var. Shows
            // the terminal-tail-as-trust-surface pattern.
            CardPayload(
                cardId: "demo-codex-blocked",
                sessionId: "demo-codex-blocked",
                category: "blocker",
                priority: "normal",
                title: "Codex hit a blocker",
                summary: "Missing STRIPE_SECRET_KEY in .env.local.",
                actionPrompt: "Tell Codex how to recover.",
                payload: [
                    "provider": AnyCodable(("codex")),
                    "project": AnyCodable(("payments-worker")),
                    "branchLabel": AnyCodable(("fix/refund-webhook")),
                    "options": AnyCodable(([
                        "Use the test key in 1Password",
                        "Skip Stripe — mock the call",
                        "Stop and ask the team"
                    ])),
                    "terminalLines": AnyCodable(([
                        "$ pnpm run test:integration",
                        "  ▶ payments-worker",
                        "  ✗ refund.webhook  Error: STRIPE_SECRET_KEY is undefined",
                        "      at loadSecrets (./src/env.ts:14:9)",
                        "      at handleRefund (./src/refund.ts:8:3)",
                        "",
                        "I can't continue without a Stripe key. Want me to use the",
                        "test key, mock the network call, or stop and wait?"
                    ]))
                ],
                state: "active",
                createdAt: now - 2_000,
                updatedAt: now - 2_000
            ),

            // Card 4 — explicit exit to Sign in with Apple. Same
            // card shape, just no terminal block of failure output
            // and a single CTA chip.
            CardPayload(
                cardId: "demo-connect-mac",
                sessionId: "demo-connect-mac",
                category: "waiting",
                priority: "normal",
                title: "Ready to use it for real?",
                summary: "Connect your Mac to start seeing your own sessions here.",
                actionPrompt: "Sign in with Apple to link your Mac.",
                payload: [
                    "provider": AnyCodable(("claude")),
                    "project": AnyCodable(("Get started")),
                    "branchLabel": AnyCodable(("")),
                    "options": AnyCodable(([
                        "Sign in with Apple"
                    ])),
                    "terminalLines": AnyCodable(([
                        "Install Steer for Mac, run `steer claude` or `steer codex`",
                        "in any terminal, then sign in here with the same Apple ID.",
                        "Cards from your wrapped sessions land in this inbox the",
                        "moment they pause for input."
                    ]))
                ],
                state: "active",
                createdAt: now - 1_000,
                updatedAt: now - 1_000
            ),
        ]
    }
}
