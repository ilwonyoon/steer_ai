import SwiftUI

/// Shared shape between real `ActionCard` and `OnboardingCard` so
/// the SwiftUI view code stays single-source. Anything that needs
/// to render a card body — header tint, terminal excerpt, age
/// capsule — reads through this protocol instead of the concrete
/// type.
///
/// Lifecycle data (sessionId, instructionId, cardId, updatedAt,
/// responseRevision, …) deliberately stays OFF this protocol. Those
/// fields are real-card-only and exist for sync / classifier flow.
/// Onboarding cards don't have them, and we don't want the view
/// layer to start branching on "is this a real card?" because of
/// nullable fields creeping in.
protocol CardDisplayable {
    var project: String { get }
    var provider: ProviderKind { get }
    var state: SessionState { get }
    var terminalLines: [TerminalLine] { get }
    /// Empty string suppresses the age capsule entirely. Real cards
    /// always populate this with a relative-time label; onboarding
    /// cards leave it blank.
    var age: String { get }
    /// Optional — falls back to `provider.displayName` in the
    /// header. Real cards may carry a git branch label when known.
    var branchLabel: String? { get }
    /// Project identity hue from git origin, 0…360. Real cards
    /// inherit it from the Mac side so the same repo gets the same
    /// color across devices. Onboarding cards pick a neutral value.
    var accentHue: Double { get }
    /// Title + summary feed the compact carousel cards along the
    /// bottom strip. The full-card body uses `terminalLines`.
    var title: String { get }
    var summary: String { get }
}

extension ActionCard: CardDisplayable {}

extension OnboardingCard: CardDisplayable {
    var state: SessionState { .waiting }
    var age: String { "" }
    var branchLabel: String? { nil }
    /// Neutral hue for the onboarding header tint. 28° lands in
    /// the warm orange band that matches the app icon palette
    /// (#FB7139 sits around hue 18°; 28° is a slightly more
    /// muted neighbor so the header reads as branded but doesn't
    /// fight real cards' more saturated colors when both render
    /// in close succession during demo flow).
    var accentHue: Double { 28 }
}
