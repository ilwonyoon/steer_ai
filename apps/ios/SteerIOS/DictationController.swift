import AVFoundation
import Foundation
import OSLog
import Speech
import SwiftUI
import UIKit

private let dictationLog = Logger(subsystem: "ai.steer.ios", category: "dictation")

/// Voice-reply controller for ReplyDock. Wraps SFSpeechRecognizer +
/// AVAudioEngine so the user can tap a mic icon inside the input
/// field, speak, and see the transcript stream into the same `reply`
/// binding the send button consumes.
///
/// Lifecycle is owned per-card: the ReplyDock owns this via
/// `@StateObject`, so swiping the carousel to a different card
/// tears the controller (and the audio engine) down cleanly.
///
/// See docs/IOS_DICTATION_DESIGN.md for the full design.
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

    /// The live transcript composed with the base text the user
    /// already had in the field. While `.listening`, this updates
    /// on every partial; on stop, it holds the final string.
    /// ReplyDock folds this into the `reply` binding in Step 4.
    @Published private(set) var partialText: String = ""

    private var baseText: String = ""

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer? = nil
    private var request: SFSpeechAudioBufferRecognitionRequest? = nil
    private var recognitionTask: SFSpeechRecognitionTask? = nil
    private var interruptionObserver: NSObjectProtocol? = nil

    init() {}

    // deinit is intentionally NOT used for engine teardown. Under
    // Swift 6 strict concurrency it's nonisolated and can't touch
    // main-actor state. Callers must invoke `stop()` explicitly
    // (ReplyDock does this from `.onDisappear`). The audio engine
    // will also clean itself up when the process exits.

    // MARK: - Public API

    /// Tap on the mic button. Asks for permission the first time;
    /// subsequent taps start listening immediately. If we're
    /// already listening, this is a no-op (use `stop()` to end).
    func start(appendingTo baseText: String) async {
        guard state != .listening, state != .requestingPermission else { return }
        self.baseText = baseText
        self.partialText = baseText

        state = .requestingPermission

        // 1) Speech recognition authorization.
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            dictationLog.notice("speech auth denied status=\(String(describing: speechStatus), privacy: .public)")
            state = .denied
            return
        }

        // 2) Microphone authorization.
        let micGranted = await Self.requestMicAuthorization()
        guard micGranted else {
            dictationLog.notice("mic auth denied")
            state = .denied
            return
        }

        // Just after the system permission prompt dismisses, the
        // audio session's hardware route hasn't fully settled yet —
        // installTap can crash on a stale/empty format. One frame
        // (~50ms) is enough for the OS to flip the route up.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Recognizer might be nil if the locale isn't supported; fall
        // back to en-US in that case (design doc Decisions §locale).
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale.current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .failed("Speech recognizer is not available right now.")
            return
        }

        do {
            try beginRecognition(recognizer: recognizer)
            installInterruptionObserverIfNeeded()
            state = .listening
        } catch {
            dictationLog.error("dictation start failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Stop listening. Safe to call from any state — no-op if not
    /// listening. Cleans up audio engine + recognizer in one shot.
    func stop() {
        recognitionTask?.finish()
        recognitionTask = nil

        request?.endAudio()
        request = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        // Restore the shared audio session so notification sounds
        // / future TTS in the rest of the app aren't muted.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }

        if state == .listening || state == .requestingPermission {
            state = .idle
        }
    }

    /// Used by ReplyDock when the user taps the alert's "Open
    /// Settings" button after a denied state.
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Engine

    private func beginRecognition(recognizer: SFSpeechRecognizer) throws {
        // Reset any previous engine state. If a prior start() failed
        // mid-flight, the engine could still have a stale tap or
        // running state — reset clears that without throwing.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()

        let session = AVAudioSession.sharedInstance()
        // .record + .default — Apple's SpeechRecognizer sample shape.
        // `.allowBluetooth` keeps AirPods working without forcing the
        // route change UI.
        try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
        try session.setActive(true, options: [.notifyOthersOnDeactivation])

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        // Reading inputFormat BEFORE prepare() can return a 0-channel
        // / 0-rate format on first launch right after permission was
        // granted (hardware route still settling). Call prepare()
        // first; that primes the route. Then read the live format.
        audioEngine.prepare()
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(
                domain: "ai.steer.dictation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone not ready. Try again in a moment."]
            )
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Hop to the main actor for any @Published mutation; the
            // callback fires on a private SFSpeechRecognizer queue.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let recognized = result.bestTranscription.formattedString
                    self.publishPartial(recognized: recognized)
                }
                if let error {
                    // Apple buries a benign "Recognition request was
                    // canceled" inside the same callback when we
                    // call .finish(). Don't surface those to the user.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 { return }
                    if self.state == .listening {
                        dictationLog.notice("recognition error: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    private func publishPartial(recognized: String) {
        let trimmed = recognized.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            partialText = baseText
            return
        }
        if baseText.isEmpty {
            partialText = trimmed
        } else {
            // Single space separator between what the user typed
            // before they hit mic and what they spoke after.
            partialText = baseText + " " + trimmed
        }
    }

    // MARK: - Interruptions (phone call, etc.)

    private func installInterruptionObserverIfNeeded() {
        guard interruptionObserver == nil else { return }
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            // Both .began and .ended drop us to idle. We deliberately
            // do not auto-resume on .ended — design decision.
            if type == .began || type == .ended {
                Task { @MainActor in self.stop() }
            }
        }
    }

    // MARK: - Authorization helpers (nonisolated wrappers)
    //
    // These run as detached tasks so awaiting them never parks the
    // main actor on a callback that is itself trying to hop back to
    // main. Without `.detached`, the Speech prompt and main were
    // racing on the same actor and the first mic tap froze the UI.

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }.value
    }

    private static func requestMicAuthorization() async -> Bool {
        await Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }.value
    }
}
