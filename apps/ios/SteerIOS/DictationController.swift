import AVFoundation
import Foundation
import OSLog
import Speech
import SwiftUI
import UIKit

private let dictationLog = Logger(subsystem: "ai.steer.ios", category: "dictation")

/// Voice-reply controller for ReplyDock.
///
/// v2 spike — ported from Apple's `RecognizingSpeechInLive` sample
/// almost line-for-line. Key shape differences from the v1 attempt
/// that failed on device:
///
/// - Permissions are requested separately from start(), not in the
///   same async chain. ReplyDock calls requestAuthorizations() first
///   and only invokes start() once both grants are in hand.
/// - AVAudioEngine is a stored property reused across sessions. We
///   stop it + reset it on stop(), but never tear it down — Apple's
///   sample takes the same shape.
/// - Audio session is `.record + .measurement`, matching Apple's
///   sample. No option flags.
/// - The recognition request is the only thing we recreate per
///   session, alongside removing/installing the tap.
///
/// Surface (state + partialText) is unchanged from v1.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case denied
        case failed(String)
    }

    enum AuthorizationResult {
        case authorized
        case denied
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var partialText: String = ""

    private var baseText: String = ""

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer? = {
        SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }()
    private var request: SFSpeechAudioBufferRecognitionRequest? = nil
    private var recognitionTask: SFSpeechRecognitionTask? = nil

    init() {}

    // MARK: - Authorization

    /// Trigger the system permission prompts for Speech then Mic.
    /// Returns once both have resolved. Splitting this from start()
    /// lets ReplyDock handle the denied case without any audio
    /// engine work happening first.
    func requestAuthorizations() async -> AuthorizationResult {
        let speechGranted = await Self.requestSpeechAuthorization()
        guard speechGranted else { return .denied }
        let micGranted = await Self.requestMicAuthorization()
        return micGranted ? .authorized : .denied
    }

    // MARK: - Public lifecycle

    /// Begin live dictation. Assumes requestAuthorizations() has
    /// already returned .authorized. Safe to call when in .idle or
    /// .failed; ignored otherwise.
    func start(appendingTo baseText: String) {
        guard state == .idle || state == .failed("") || isFailed else { return }
        self.baseText = baseText
        self.partialText = baseText

        guard let recognizer, recognizer.isAvailable else {
            state = .failed("Speech recognizer is not available right now.")
            return
        }

        do {
            try beginRecognition(recognizer: recognizer)
            state = .listening
        } catch {
            dictationLog.error("dictation start failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Stop listening. Safe in any state. The next start() will
    /// reuse audioEngine; only the request and recognition task
    /// are torn down.
    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        if state == .listening || state == .requestingPermission {
            state = .idle
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Engine (closely follows Apple's sample)

    private func beginRecognition(recognizer: SFSpeechRecognizer) throws {
        // Ensure we start from a clean audio engine state.
        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Apple sample sets this true; recognizers in simulator
        // support on-device for en-US, real devices may not.
        // Setting it true is what the sample does.
        request.requiresOnDeviceRecognition = false
        self.request = request

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        // Defensive: a 0-channel/0-rate format would crash installTap.
        guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
            throw NSError(
                domain: "ai.steer.dictation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone not ready. Try again in a moment."]
            )
        }

        // The tap callback fires on AVAudio's RealtimeMessenger
        // queue. Without `@Sendable` + a capture list that avoids
        // any actor-isolated state, the closure inherits the
        // enclosing class's @MainActor isolation and Swift's
        // runtime trips an isolation check on every buffer
        // delivery — that was the second crash. Capture only the
        // request (a Sendable Apple class for this purpose) and
        // mark the closure @Sendable to make the lack of
        // main-actor work explicit.
        let requestRef = request
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { @Sendable buffer, _ in
            requestRef.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        // Same Sendable shape as the installTap closure. The
        // recognizer dispatches this on its own background queue
        // (com.apple.Speech.Task.Internal). Hopping back to
        // @MainActor for the actual @Published mutation is fine —
        // that's what Task { @MainActor … } is for. The callback
        // itself just reads value types and schedules the hop.
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            var recognizedText: String? = nil
            var isFinal = false
            if let result {
                recognizedText = result.bestTranscription.formattedString
                isFinal = result.isFinal
            }
            let shouldStop = (error != nil) || isFinal
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let recognizedText {
                    self.publishPartial(recognized: recognizedText)
                }
                if shouldStop {
                    self.stop()
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
            partialText = baseText + " " + trimmed
        }
    }

    // MARK: - Authorization helpers
    //
    // These MUST be nonisolated. Without `nonisolated`, the @MainActor
    // attribute on the enclosing class makes the continuation.resume
    // call inherit main-actor isolation, and TCC dispatches the
    // permission callback on a background queue. The mismatch trips
    // _swift_task_checkIsolatedSwift → SIGTRAP, which is exactly the
    // crash we hit on the first mic tap. (Confirmed via simulator
    // crash report: thread 2, _dispatch_assert_queue_fail.)

    private nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private nonisolated static func requestMicAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
