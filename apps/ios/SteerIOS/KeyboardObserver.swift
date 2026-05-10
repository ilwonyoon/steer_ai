import SwiftUI
import UIKit
import Combine

/// Tracks the system keyboard's height *and* the system's own
/// animation curve+duration for keyboard transitions.
///
/// We need both pieces because the smooth result on dismiss is:
/// the carousel rides *with* the keyboard as it slides down — same
/// curve, same duration, same direction — instead of waiting for
/// the keyboard to finish hiding and then pop in. Using
/// `withAnimation(.uiKitKeyboard)` from a `keyboardWillChangeFrame`
/// observer keeps SwiftUI in lockstep with UIKit's spring.
@MainActor
final class KeyboardObserver: ObservableObject {
    /// 0 when fully hidden, otherwise the height of the visible
    /// keyboard portion (intersected against the screen).
    @Published private(set) var height: CGFloat = 0

    var isVisible: Bool { height > 0 }

    private var cancellables = Set<AnyCancellable>()

    init() {
        let center = NotificationCenter.default

        center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                self?.handle(note)
            }
            .store(in: &cancellables)

        center.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                self?.handle(note, forceHidden: true)
            }
            .store(in: &cancellables)
    }

    private func handle(_ note: Notification, forceHidden: Bool = false) {
        let info = note.userInfo ?? [:]
        let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let screenHeight = UIScreen.main.bounds.height
        let visibleHeight: CGFloat = forceHidden
            ? 0
            : max(0, screenHeight - endFrame.origin.y)

        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7

        // UIKit ships a private "keyboard" curve (raw 7) that's
        // smoother than easeInOut. Match it as closely as SwiftUI
        // can with .timingCurve.
        let animation: Animation
        if curveRaw == 7 {
            // Apple's keyboard curve, approx (0.17, 0.17, 0.17, 1.0).
            animation = .timingCurve(0.17, 0.17, 0.17, 1.0, duration: duration)
        } else {
            switch UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut {
            case .easeIn: animation = .easeIn(duration: duration)
            case .easeOut: animation = .easeOut(duration: duration)
            case .easeInOut: animation = .easeInOut(duration: duration)
            case .linear: animation = .linear(duration: duration)
            @unknown default: animation = .easeInOut(duration: duration)
            }
        }

        withAnimation(animation) {
            self.height = visibleHeight
        }
    }
}
