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

    /// The engine is created lazily on each start() so its inputNode
    /// reflects whatever audio route exists AFTER the mic permission
    /// prompt resolves. A long-lived AVAudioEngine that was
    /// instantiated before the prompt ran could have an inputNode
    /// pinned to a pre-permission stub route; installTap on that
    /// node throws an Obj-C NSException that Swift can't catch.
    private var audioEngine: AVAudioEngine? = nil
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

        // Crash-trail: persist each step to UserDefaults so a hard
        // crash (Obj-C NSException, audio engine fault) leaves a
        // breadcrumb the next launch can surface. The key is read
        // in ReplyDock.onAppear; once we've shown it, it's cleared.
        Self.recordTrail("start: entered")

        // 1) Speech recognition authorization.
        Self.recordTrail("start: awaiting speech auth")
        let speechStatus = await Self.requestSpeechAuthorization()
        Self.recordTrail("start: speech auth = \(speechStatus.rawValue)")
        guard speechStatus == .authorized else {
            dictationLog.notice("speech auth denied status=\(String(describing: speechStatus), privacy: .public)")
            state = .denied
            return
        }

        // 2) Microphone authorization.
        Self.recordTrail("start: awaiting mic auth")
        let micGranted = await Self.requestMicAuthorization()
        Self.recordTrail("start: mic auth = \(micGranted)")
        guard micGranted else {
            dictationLog.notice("mic auth denied")
            state = .denied
            return
        }

        // Just after the system permission prompt dismisses, the
        // audio session's hardware route hasn't fully settled yet —
        // installTap can crash on a stale/empty format. One frame
        // (~50ms) is enough for the OS to flip the route up.
        Self.recordTrail("start: route settle sleep")
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Recognizer might be nil if the locale isn't supported; fall
        // back to en-US in that case (design doc Decisions §locale).
        Self.recordTrail("start: building recognizer")
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale.current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        guard let recognizer, recognizer.isAvailable else {
            Self.recordTrail("start: recognizer not available")
            state = .failed("Speech recognizer is not available right now.")
            return
        }
        Self.recordTrail("start: recognizer ok (locale=\(recognizer.locale.identifier))")

        do {
            try beginRecognition(recognizer: recognizer)
            Self.recordTrail("start: beginRecognition returned")
            installInterruptionObserverIfNeeded()
            Self.recordTrail("start: complete (.listening)")
            state = .listening
        } catch {
            Self.recordTrail("start: beginRecognition threw: \(error.localizedDescription)")
            dictationLog.error("dictation start failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Crash trail. Written synchronously to UserDefaults so even an
    /// abrupt termination preserves the last reached step.
    private static func recordTrail(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "\(ts) \(message)"
        let key = "ai.steer.ios.dictation.trail"
        let defaults = UserDefaults.standard
        var lines = defaults.stringArray(forKey: key) ?? []
        lines.append(entry)
        // Cap so the array doesn't grow forever on success paths.
        if lines.count > 50 { lines.removeFirst(lines.count - 50) }
        defaults.set(lines, forKey: key)
        defaults.synchronize()
        dictationLog.notice("\(entry, privacy: .public)")
    }

    /// Drains the crash trail collected since last read. Returns the
    /// concatenated string and clears it. ReplyDock surfaces this
    /// next launch when a previous run died mid-mic.
    static func drainTrail() -> String? {
        let key = "ai.steer.ios.dictation.trail"
        let defaults = UserDefaults.standard
        guard let lines = defaults.stringArray(forKey: key), !lines.isEmpty else { return nil }
        defaults.removeObject(forKey: key)
        return lines.joined(separator: "\n")
    }

    /// Stop listening. Safe to call from any state — no-op if not
    /// listening. Cleans up audio engine + recognizer in one shot.
    func stop() {
        recognitionTask?.finish()
        recognitionTask = nil

        request?.endAudio()
        request = nil

        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
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
        // Discard any prior engine entirely. inputNode is lazily
        // bound to whatever route was current when the AVAudioEngine
        // was constructed; the only reliable way to pick up the
        // post-permission route is to build a fresh engine here.
        Self.recordTrail("beginRecognition: discarding prior engine")
        if let prior = audioEngine {
            prior.stop()
            prior.inputNode.removeTap(onBus: 0)
        }

        Self.recordTrail("beginRecognition: building engine")
        let engine = AVAudioEngine()
        self.audioEngine = engine

        Self.recordTrail("beginRecognition: setting session category")
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
        Self.recordTrail("beginRecognition: activating session")
        try session.setActive(true, options: [.notifyOthersOnDeactivation])

        Self.recordTrail("beginRecognition: building request")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        Self.recordTrail("beginRecognition: reading inputFormat")
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        Self.recordTrail("beginRecognition: format ch=\(format.channelCount) sr=\(format.sampleRate)")
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(
                domain: "ai.steer.dictation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone not ready. Try again in a moment."]
            )
        }

        Self.recordTrail("beginRecognition: installTap")
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        Self.recordTrail("beginRecognition: prepare()")
        engine.prepare()
        Self.recordTrail("beginRecognition: start()")
        try engine.start()
        Self.recordTrail("beginRecognition: engine running")

        Self.recordTrail("beginRecognition: creating recognitionTask")
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
