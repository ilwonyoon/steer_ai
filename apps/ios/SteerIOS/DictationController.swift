import AVFoundation
import Foundation
import OSLog
import QuartzCore
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
    /// Time-domain scrolling waveform samples. Each entry is a
    /// normalized 0…1 amplitude representing one buffer of mic
    /// input. Index 0 is the OLDEST sample (leftmost bar on
    /// screen), last is the NEWEST (rightmost). On every audio
    /// buffer we drop the oldest and append the newest — that's
    /// what makes the bars "flow" left like the ChatGPT mac
    /// listening indicator. 9 bars ≈ 60% of the 14-bar version
    /// the user reviewed — still reads as "time is flowing"
    /// but takes less horizontal room in the input row.
    @Published private(set) var waveformSamples: [Float] = Array(repeating: 0, count: 32)
    /// Wall-clock time (CACurrentMediaTime) of the most recent
    /// ring shift. The view uses (now - lastShiftTime) / shiftInterval
    /// to compute a sub-slot pixel offset, so the row slides
    /// continuously between buffers.
    @Published private(set) var lastShiftTime: TimeInterval = 0
    /// Expected interval between ring shifts (= bufferSize / sampleRate).
    @Published private(set) var shiftInterval: TimeInterval = 0

    private var baseText: String = ""

    // Smoothed dB envelope so a single short syllable doesn't
    // disappear instantly. Asymmetric: snap on attack, ~50ms
    // release. Single value, not per-band — the visualizer is
    // a time-domain scroll, every bar shows the same kind of
    // signal but at a different moment in time.
    private let envelopeLock = NSLock()
    private var smoothedDb: Float = -80
    // Local ring of recent normalized samples; copied to the
    // published `waveformSamples` array each callback.
    private var sampleRing: [Float] = Array(repeating: 0, count: 32)

    private let audioEngine = AVAudioEngine()
    /// Built fresh on every `start()` so the recognizer always
    /// follows the live system language (Settings → General →
    /// Language & Region). Falling back to en-US keeps things
    /// usable when the device locale doesn't have a speech model.
    private var recognizer: SFSpeechRecognizer? = nil
    private var request: SFSpeechAudioBufferRecognitionRequest? = nil
    private var recognitionTask: SFSpeechRecognitionTask? = nil

    private static func makeRecognizer() -> SFSpeechRecognizer? {
        let system = Locale.autoupdatingCurrent
        if let r = SFSpeechRecognizer(locale: system), r.isAvailable {
            return r
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    init() {}

    // MARK: - Authorization

    /// Trigger the system permission prompts for Speech then Mic.
    /// Returns once both have resolved. Splitting this from start()
    /// lets ReplyDock handle the denied case without any audio
    /// engine work happening first.
    /// CRITICAL: this MUST only be called from an explicit user
    /// gesture (mic-button tap). It never runs on view appear,
    /// scenePhase change, or any other automatic path.
    func requestAuthorizations() async -> AuthorizationResult {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVAudioApplication.shared.recordPermission
        let speechGranted: Bool
        if speechStatus == .notDetermined {
            speechGranted = await Self.requestSpeechAuthorization()
        } else {
            speechGranted = (speechStatus == .authorized)
        }
        guard speechGranted else { return .denied }
        let micGranted: Bool
        if micStatus == .undetermined {
            micGranted = await Self.requestMicAuthorization()
        } else {
            micGranted = (micStatus == .granted)
        }
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

        self.recognizer = Self.makeRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            state = .failed("Speech recognizer is not available right now.")
            return
        }
        dictationLog.info("dictation locale: \(recognizer.locale.identifier, privacy: .public)")

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

        waveformSamples = Array(repeating: 0, count: 32)
        envelopeLock.lock()
        smoothedDb = -80
        for i in 0..<sampleRing.count { sampleRing[i] = 0 }
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

        self.shiftInterval = 512.0 / recordingFormat.sampleRate
        self.lastShiftTime = CACurrentMediaTime()

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
        // bufferSize 512 @ 48kHz ≈ 10.7ms tap cadence — half the
        // latency of the default 1024. Reference: jnpdx
        // AudioEngineLoopbackLatencyTest (the canonical AVAudioEngine
        // latency benchmark) uses 256–512 for "feels live"; 1024
        // pushes the audio→UI gap into the visibly sluggish band.
        inputNode.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { @Sendable [weak self] buffer, _ in
            requestRef.append(buffer)
            guard let self else { return }
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            // 1) RMS on channel 0 → dBFS → smoothed envelope →
            //    normalized 0…1 amplitude. Asymmetric: snap on
            //    attack, one-pole alpha 0.20 release (~50ms).
            let samples = channels[0]
            var sum: Float = 0
            for i in 0..<frames { sum += samples[i] * samples[i] }
            let rms = sqrtf(sum / Float(frames))
            let db = 20 * log10f(max(rms, 1e-7))

            self.envelopeLock.lock()
            if db > self.smoothedDb {
                self.smoothedDb = db
            } else {
                self.smoothedDb = 0.20 * db + 0.80 * self.smoothedDb
            }
            let clamped = min(max((self.smoothedDb - (-55)) / 35.0, 0), 1)
            let curved = powf(clamped, 0.4)

            // 2) Scrolling ring: shift left, append newest.
            //    The view reads index 0 as oldest (leftmost,
            //    fading), last as newest (rightmost, full).
            for i in 0..<(self.sampleRing.count - 1) {
                self.sampleRing[i] = self.sampleRing[i + 1]
            }
            self.sampleRing[self.sampleRing.count - 1] = curved
            let snapshot = self.sampleRing
            self.envelopeLock.unlock()

            let shiftTime = CACurrentMediaTime()
            // Lowest-latency bridge.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.waveformSamples = snapshot
                    self?.lastShiftTime = shiftTime
                }
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
