import SwiftUI

/// iOS port of Mac ActionCardView. Same layout: tinted SessionHeader,
/// terminal excerpt, ReplyDock — wrapped in a rounded card with a
/// subtle stroke and shadow.
struct ActionCardView<Card: CardDisplayable>: View {
    let card: Card
    @Binding var reply: String
    let onSend: (String) -> Void
    var replyFieldFocused: FocusState<Bool>.Binding? = nil
    /// Called when the user taps the card body (header or transcript)
    /// while the keyboard is up. The parent dismisses focus.
    /// simultaneousGesture is used so a vertical drag inside the
    /// transcript starts a scroll instead of firing a tap.
    var onBodyTap: (() -> Void)? = nil
    /// Placeholder for the reply field. Real cards use the default
    /// ("reply to this session"); onboarding cards override it
    /// per-card so the user sees the suggested word inline.
    var replyPlaceholder: String? = nil

    #if DEBUG
    @AppStorage("ai.steer.ios.dictationStyle") private var spikeStyleRaw: String = DictationVisualStyle.outlinePulse.rawValue
    private var spikeStyle: DictationVisualStyle {
        DictationVisualStyle(rawValue: spikeStyleRaw) ?? .outlinePulse
    }
    #else
    private var spikeStyle: DictationVisualStyle { .outlinePulse }
    #endif

    private var headerTint: Color {
        SteerColors.hueTint(hue: card.accentHue, intensity: 0.65)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionHeader(card: card)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)
                .background(headerTint)
                .contentShape(Rectangle())
                .onTapGesture {
                    onBodyTap?()
                }

            Divider()

            TerminalExcerptView(lines: card.terminalLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .layoutPriority(1)
                // simultaneousGesture coexists with the inner
                // ScrollView's drag: a drag still scrolls, but a
                // clean (no-drag) tap fires and dismisses the
                // keyboard. Plain onTapGesture would either be
                // swallowed by ScrollView's gesture priority or
                // would fire mid-scroll.
                .simultaneousGesture(
                    TapGesture().onEnded { onBodyTap?() }
                )

            Divider()

            // Expand the tap-target so taps anywhere in the bottom
            // strip — not just inside the input pill — bring up the
            // keyboard. contentShape on the padded wrapper makes the
            // padding hit-testable; onTapGesture forwards focus to
            // the field via the parent's @FocusState binding.
            #if DEBUG
            // Spike-only chip row: lets us A/B/C/D the four listening
            // visuals against the real card on device. The picker
            // persists via AppStorage so the choice survives card
            // swipes within the same session. Removed before Stage 2
            // ships to the App Store.
            DictationStyleChipRow()
                .padding(.horizontal, 16)
                .padding(.top, 6)
            #endif
            ReplyDock(
                reply: $reply,
                onSend: onSend,
                placeholder: replyPlaceholder,
                externalFocus: replyFieldFocused,
                dictationStyle: spikeStyle
            )
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture {
                    replyFieldFocused?.wrappedValue = true
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SteerColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(SteerColors.separator, lineWidth: 1)
        }
        .shadow(color: SteerColors.cardShadow, radius: 24, y: 16)
        // Don't .accessibilityIdentifier() the whole card — SwiftUI
        // cascades it down to every subview and overwrites the
        // identifiers on `reply-input` / `reply-send`. UITests assert
        // on the reply field instead, which is unique per visible
        // card.
    }
}

struct SessionHeader<Card: CardDisplayable>: View {
    let card: Card

    var body: some View {
        HStack(alignment: .top) {
            HStack(spacing: 8) {
                ProjectMark(emoji: card.emoji)

                VStack(alignment: .leading, spacing: 2) {
                    // iOS HIG body: 17pt SF Text. Project name is the
                    // primary identifier on the card so it gets full
                    // body weight; previous 14pt monospaced read like
                    // metadata. Matches Messages / Mail header rows.
                    Text(card.project)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SteerColors.ink)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(card.state.color)
                            .frame(width: 6, height: 6)
                        Text(card.branchLabel ?? card.provider.displayName)
                            .font(.system(size: 14))
                            .foregroundStyle(SteerColors.secondaryInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            // Age capsule is hidden when the card doesn't carry an
            // age string (onboarding cards leave it blank). Real
            // cards always populate it.
            if !card.age.isEmpty {
                Text(card.age)
                    .font(.system(size: 13))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SteerColors.subtleFill, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(SteerColors.softSeparator, lineWidth: 1)
                    }
            }
        }
    }
}

struct ProviderMark: View {
    let provider: ProviderKind
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let iconName = provider.iconName,
               let image = UIImage(named: iconName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(provider.fallbackLetter)
                    .font(.system(size: max(8, size * 0.46), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.11, green: 0.11, blue: 0.12), Color(red: 0.37, green: 0.42, blue: 0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(provider.displayName)
    }
}

/// Project emoji marker. Stage 1 — informational only; the glyph
/// is computed by Mac (deterministic from cwd OR Stage 2 override)
/// and forwarded verbatim through the relay payload. Stage 2 will
/// make this tappable so the user can open an emoji picker, but
/// the rendering contract stays the same.
struct ProjectMark: View {
    let emoji: String
    var size: CGFloat = 24

    var body: some View {
        Text(emoji)
            // The emoji glyph itself is the affordance; the previous
            // disc background was an artifact of when this slot held
            // a rectangular image that needed a circle clip. Emoji
            // already read as a self-contained mark, and the disc
            // boxed it in awkwardly, so we drop the background and
            // let the glyph sit against the header tint.
            .font(.system(size: size))
            .frame(width: size, height: size)
            .accessibilityLabel("Project marker \(emoji)")
    }
}

#if DEBUG
/// Spike-only picker that sits above the ReplyDock in DEBUG
/// builds so we can compare the four dictation listening visuals
/// against a real card. Persists the selection via AppStorage so
/// the choice survives carousel swipes and app relaunches during
/// the dogfood loop. Removed before the variant ships.
struct DictationStyleChipRow: View {
    @AppStorage("ai.steer.ios.dictationStyle") private var selectedRaw: String = DictationVisualStyle.outlinePulse.rawValue

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DictationVisualStyle.allCases) { variant in
                Button {
                    selectedRaw = variant.rawValue
                } label: {
                    Text(variant.label)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                selectedRaw == variant.rawValue
                                    ? Color.accentColor.opacity(0.18)
                                    : SteerColors.subtleFill
                            )
                        )
                        .overlay {
                            Capsule().stroke(
                                selectedRaw == variant.rawValue
                                    ? Color.accentColor
                                    : SteerColors.softSeparator,
                                lineWidth: 1
                            )
                        }
                        .foregroundStyle(
                            selectedRaw == variant.rawValue
                                ? Color.accentColor
                                : SteerColors.secondaryInk
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
#endif
