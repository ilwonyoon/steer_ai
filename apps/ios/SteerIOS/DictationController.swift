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
    /// Per-dot smoothed amplitude (0…1) for the three-capsule
    /// visualizer. Index 0 is the leftmost dot (live), 1 and 2 are
    /// the same envelope delayed 80ms and 160ms — that delay is
    /// what creates the left→right "ripple" instead of all three
    /// dots pulsing in unison.
    ///
    /// Smoothing is asymmetric in the dB domain (attack 30ms,
    /// release 220ms) so syllable onsets pop while decay reads
    /// natural. See sub-agent research notes captured in the
    /// commit message for the chosen constants.
    @Published private(set) var dotLevels: [Float] = [0, 0, 0]

    private var baseText: String = ""

    // Visualizer envelope state. Lives outside any actor isolation
    // (a class-internal serial queue would also work) because the
    // audio tap closure runs on a realtime queue; we mutate via a
    // lock-free pattern (only the audio thread writes, only the
    // main actor reads once per frame via the publish hop).
    private let envelopeLock = NSLock()
    private var smoothedDb: Float = -80.0   // dBFS
    private var levelHistory: [Float] = []  // ring buffer of recent linear levels for delay channels
    private var levelHistoryCursor: Int = 0
    private let levelHistoryCapacity: Int = 32 // ~640ms @ 50Hz buffers

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer? = {
        SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }()
    private var request: SFSpeechAudioBufferRecognitionRequest? = nil
    private var recognitionTask: SFSpeechRecognitionTask? = nil

    init() {
        levelHistory = Array(repeating: 0, count: levelHistoryCapacity)
    }

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

        dotLevels = [0, 0, 0]
        envelopeLock.lock()
        smoothedDb = -80
        for i in 0..<levelHistory.count { levelHistory[i] = 0 }
        levelHistoryCursor = 0
        envelopeLock.unlock()
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { @Sendable [weak self] buffer, _ in
            requestRef.append(buffer)
            guard let self else { return }
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            // 1) RMS on channel 0.
            let samples = channels[0]
            var sum: Float = 0
            for i in 0..<frames { sum += samples[i] * samples[i] }
            let rms = sqrtf(sum / Float(frames))

            // 2) dBFS conversion + asymmetric one-pole smoothing
            //    in the dB domain. Attack ≈15ms (snappier than
            //    the 30ms default — speech onsets need to read
            //    "live"), release ≈220ms for natural decay.
            //    Buffer cadence ≈ 21ms, so alphaAttack ≈ 0.75,
            //    alphaRelease ≈ 0.09.
            let db = 20 * log10f(max(rms, 1e-7))
            self.envelopeLock.lock()
            let target = db
            let alpha: Float = target > self.smoothedDb ? 0.75 : 0.09
            self.smoothedDb = alpha * target + (1 - alpha) * self.smoothedDb
            // 3) Map [-45, -15] dBFS → [0, 1], then pow(0.5) to
            //    stretch the low end strongly. Window is narrower
            //    than a typical mic meter on purpose: regular
            //    speech sits around -30 to -20 dBFS, so this
            //    keeps the dots in their visually-active middle
            //    range during normal use.
            let clamped = min(max((self.smoothedDb - (-45)) / 30.0, 0), 1)
            let curved = powf(clamped, 0.5)
            // 4) Push into ring history so delayed channels can
            //    sample older values for the per-dot phase offset.
            self.levelHistory[self.levelHistoryCursor] = curved
            // Per-buffer ≈ 21ms; dot delays target 0ms / 80ms /
            // 160ms → 0 / 4 / 8 buffers back.
            let live = curved
            let dot2 = self.sampleHistory(stepsBack: 4)
            let dot3 = self.sampleHistory(stepsBack: 8)
            self.levelHistoryCursor = (self.levelHistoryCursor + 1) % self.levelHistoryCapacity
            self.envelopeLock.unlock()

            Task { @MainActor [weak self] in
                self?.dotLevels = [live, dot2, dot3]
            }
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
            let errorMessage: String? = (error as NSError?).flatMap { ns in
                // Filter benign "request canceled" codes that fire
                // whenever we (or the user) call stop() — these are
                // the recognizer winding down cleanly, not failures.
                //   - kAFAssistantErrorDomain 1110: AssistantServices side
                //   - kLSRErrorDomain        301:  Local recognizer side
                if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 { return nil }
                if ns.domain == "kLSRErrorDomain", ns.code == 301 { return nil }
                return "Recognizer error: \(ns.domain) \(ns.code) — \(ns.localizedDescription)"
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let recognizedText {
                    self.publishPartial(recognized: recognizedText)
                }
                if let errorMessage {
                    // Surface the recognizer's real error so we can
                    // see it in the test UI instead of silently
                    // bouncing back to .idle.
                    self.state = .failed(errorMessage)
                    self.stop()
                } else if isFinal {
                    self.stop()
                }
            }
        }
    }

    /// Audio-thread helper: read a curved level value from N
    /// buffers ago in the ring history. Caller must hold
    /// envelopeLock.
    private func sampleHistory(stepsBack: Int) -> Float {
        let idx = (levelHistoryCursor - stepsBack + levelHistoryCapacity) % levelHistoryCapacity
        return levelHistory[idx]
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
