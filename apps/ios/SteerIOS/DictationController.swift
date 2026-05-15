import Foundation
import SwiftUI

/// Voice-reply controller for ReplyDock. Wraps SFSpeechRecognizer +
/// AVAudioEngine so the user can tap a mic icon inside the input
/// field, speak, and see the transcript stream into the same `reply`
/// binding the send button consumes.
///
/// Step 1: skeleton only — state enum + empty observable surface so
/// the rest of the build wiring (Info.plist usage strings, pbxproj
/// reference) lands without functional changes. Step 2 fills in the
/// engine, recognizer, and permission flow. See
/// `docs/IOS_DICTATION_DESIGN.md` for the full step plan.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// The live partial transcript. Empty when not listening; on
    /// stop, holds the final string. ReplyDock will observe this
    /// and fold it into the `reply` binding starting in Step 4.
    @Published private(set) var partialText: String = ""

    init() {}
}
