import SwiftUI

/// Isolated dictation test surface for the v2 spike. Strips away
/// sign-in, sync, carousel, and card lifecycle so the recognizer
/// + ReplyDock + mic plumbing can be verified in isolation.
///
/// Gated by `#if targetEnvironment(simulator)` in SteerIOSApp's
/// root — production builds never see this screen.
struct DictationTestView: View {
    @State private var reply: String = ""
    @State private var sentTranscripts: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dictation spike")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Tap the mic, allow Speech + Microphone, speak. The recognized text streams into the field. Tap stop, then send — the transcript appears below.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                ReplyDock(
                    reply: $reply,
                    onSend: { text in
                        sentTranscripts.append(text)
                    },
                    placeholder: "Tap mic and speak…",
                    externalFocus: $focused.projectedValue
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
