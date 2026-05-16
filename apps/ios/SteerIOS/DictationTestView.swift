import SwiftUI

/// Isolated dictation test surface for the v2 spike. Strips away
/// sign-in, sync, carousel, and card lifecycle so the recognizer
/// + ReplyDock + mic plumbing can be verified in isolation.
///
/// A picker at the top swaps between the four candidate listening
/// visuals (rowWaveform / inlineBars / outlinePulse / edgeGlow)
/// so we can dogfood them side-by-side before picking one.
///
/// Gated by `#if targetEnvironment(simulator)` in SteerIOSApp's
/// root — production builds never see this screen.
struct DictationTestView: View {
    @State private var reply: String = ""
    @State private var sentTranscripts: [String] = []
    @State private var style: DictationVisualStyle = .rowWaveform
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dictation spike")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Tap the mic, speak. Switch the picker below to compare the four candidate listening visuals while dictation is live.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                Picker("Listening visual", selection: $style) {
                    ForEach(DictationVisualStyle.allCases) { variant in
                        Text(variant.label).tag(variant)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                ReplyDock(
                    reply: $reply,
                    onSend: { text in
                        sentTranscripts.append(text)
                    },
                    placeholder: "Tap mic and speak…",
                    externalFocus: $focused.projectedValue,
                    dictationEnabled: true,
                    dictationStyle: style
                )
                .padding(.horizontal)

                if !sentTranscripts.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(sentTranscripts.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 15))
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(SteerColors.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle("Dictation Test")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    DictationTestView()
}
