import Foundation
import SteerCore

/// Hard-coded card payloads for the simulator UX iteration loop.
/// Mirrors the shape that the Mac SyncClient publishes to the relay
/// so the iOS UI can be developed without a working sign-in flow.
enum SyncInboxFixtures {
    static func cards() -> [CardPayload] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            CardPayload(
                cardId: "fixture-question",
                sessionId: "codex-fixture-question",
                category: "question",
                priority: "normal",
                title: "Codex CLI · codex has a question",
                summary: "내 생각엔 pSEO 페이지에서는 article이 1번이고, 앱 비디오는 마지막 CTA에 가까운 게 맞아.",
                actionPrompt: "Answer the question or give a direct next instruction.",
                payload: [
                    "provider": AnyCodable(("codex")),
                    "project": AnyCodable(("Documents/SaveReset")),
                    "branchLabel": AnyCodable(("feat/routine-share-links")),
                    "options": AnyCodable(([
                        "Yes, continue",
                        "Use your judgment",
                        "Explain first"
                    ])),
                    "terminalLines": AnyCodable(([
                        "내 생각엔 **pSEO 페이지에서는 article이 1번이고, 앱 비디오는 마지막 CTA에 가까운 게 맞아.**",
                        "",
                        "이유는 간단해:",
                        "- pSEO 유입자는 \"SaveBack이 뭔지\"보다 먼저 `desk stretches` 같은 문제를 해결하러 들어옴",
                        "- 첫 화면에 앱 비디오가 크면 다시 랜딩 페이지처럼 보여서 검색 의도와 어긋남",
                        "- Google 관점에서도 페이지의 주 콘텐츠가 \"해당 쿼리에 대한 도움이 되는 글\"이어야 함",
                        "",
                        "그래서 구조는 이렇게 가는 게 제일 자연스럽다:",
                        "1. Hero: 검색 키워드에 맞는 문제와 답",
                        "2. Article: beginner-friendly guide, routine order, cues",
                        "3. Related guides: 내부 링크로 pSEO 확장",
                        "4. Bottom landing CTA: \"이 루틴을 앱에 저장해서 반복해라\""
                    ]))
                ],
                state: "active",
                createdAt: now - 60_000,
                updatedAt: now - 30_000
            ),
            CardPayload(
                cardId: "fixture-waiting",
                sessionId: "codex-fixture-waiting",
                category: "waiting",
                priority: "normal",
                title: "Codex CLI · codex is waiting",
                summary: "session just opened — send your first instruction",
                actionPrompt: "Send the next instruction so the session can continue.",
                payload: [
                    "provider": AnyCodable(("codex")),
                    "project": AnyCodable(("packages/relay")),
                    "branchLabel": AnyCodable(("feature/relay-backend")),
                    "options": AnyCodable(([
                        "Continue",
                        "Summarize result",
                        "Start next task"
                    ])),
                    "terminalLines": AnyCodable(([
                        "session just opened — send your first instruction"
                    ]))
                ],
                state: "active",
                createdAt: now - 20_000,
                updatedAt: now - 10_000
            ),
            CardPayload(
                cardId: "fixture-blocker",
                sessionId: "claude-fixture-blocker",
                category: "blocker",
                priority: "high",
                title: "Claude Code · build failure",
                summary: "Type 'CardPayload' has no member 'kind' — fix or skip?",
                actionPrompt: "Decide how to handle the failing build before the session can continue.",
                payload: [
                    "provider": AnyCodable(("claude")),
                    "project": AnyCodable(("apps/ios")),
                    "branchLabel": AnyCodable(("feature/relay-backend")),
                    "options": AnyCodable(([
                        "Fix and rebuild",
                        "Skip for now",
                        "Show me the diff"
                    ])),
                    "terminalLines": AnyCodable(([
                        "$ swift build --package-path apps/ios",
                        "Building for debugging...",
                        "/apps/ios/SteerIOS/CardDetailView.swift:14:34: error:",
                        "  type 'CardPayload' has no member 'kind'",
                        "  switch card.payload?[\"kind\"]?.value {",
                        "                              ^~~~",
                        "** BUILD FAILED **"
                    ]))
                ],
                state: "active",
                createdAt: now - 5_000,
                updatedAt: now - 2_000
            )
        ]
    }
}
