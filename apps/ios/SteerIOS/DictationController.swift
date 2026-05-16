import Accelerate
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

    // Per-band envelope state. Three bands (low / mid / high)
    // drive the three dots respectively, so the row reads as a
    // tiny spectrum rather than three copies of the same level.
    // Audio thread writes; main actor reads via DispatchQueue hop.
    private let envelopeLock = NSLock()
    private var smoothedBandDb: [Float] = [-80, -80, -80]
    // FFT scratch — allocated once at init, reused on every
    // audio callback. nonisolated(unsafe) because the audio
    // thread reads them but only the main actor's init/deinit
    // writes; treat as effectively immutable after init.
    private let fftLog2N: vDSP_Length = 9 // 512-sample FFT
    nonisolated(unsafe) private var fftSetup: vDSP_DFT_Setup? = nil
    nonisolated(unsafe) private var fftWindow: [Float] = []

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer? = {
        SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }()
    private var request: SFSpeechAudioBufferRecognitionRequest? = nil
    private var recognitionTask: SFSpeechRecognitionTask? = nil

    init() {
        let n = 1 << fftLog2N  // 512
        // Forward real DFT — gives us a complex spectrum from a
        // 512-sample real input. Reused across every buffer.
        fftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)
        // Hann window so FFT bin boundaries don't ring.
        fftWindow = [Float](repeating: 0, count: n)
        vDSP_hann_window(&fftWindow, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
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
        smoothedBandDb = [-80, -80, -80]
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
        // bufferSize 512 @ 48kHz ≈ 10.7ms tap cadence — half the
        // latency of the default 1024. Reference: jnpdx
        // AudioEngineLoopbackLatencyTest (the canonical AVAudioEngine
        // latency benchmark) uses 256–512 for "feels live"; 1024
        // pushes the audio→UI gap into the visibly sluggish band.
        let sampleRate = Float(recordingFormat.sampleRate)
        inputNode.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { @Sendable [weak self] buffer, _ in
            requestRef.append(buffer)
            guard let self else { return }
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            // 1) FFT-based per-band dBFS. Three bands chosen for
            //    human speech, mapped to bin ranges at sampleRate
            //    (typically 48kHz, 93.75Hz/bin at 512 FFT):
            //      low  : 80–500 Hz   — vowel fundamentals
            //      mid  : 500–2k Hz   — vowel formants
            //      high : 2k–6k Hz    — consonants / sibilance
            let bandDb = self.computeBandLevels(samples: channels[0], frameCount: frames, sampleRate: sampleRate)

            // 2) Asymmetric envelope per band: snap on attack,
            //    one-pole release at alpha 0.20 (~50ms).
            self.envelopeLock.lock()
            var out: [Float] = [0, 0, 0]
            for i in 0..<3 {
                let db = bandDb[i]
                if db > self.smoothedBandDb[i] {
                    self.smoothedBandDb[i] = db
                } else {
                    self.smoothedBandDb[i] = 0.20 * db + 0.80 * self.smoothedBandDb[i]
                }
                // 3) Tighter dB window than the single-RMS pipe.
                //    Per-band energy sits ~6-10dB lower than the
                //    overall RMS, so quiet speech needs the floor
                //    pulled down to register. pow(0.35) stretches
                //    the bottom end aggressively.
                let clamped = min(max((self.smoothedBandDb[i] - (-55)) / 30.0, 0), 1)
                out[i] = powf(clamped, 0.35)
            }
            self.envelopeLock.unlock()

            // Lowest-latency bridge — same shape as before.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.dotLevels = out
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

    /// Audio-thread FFT band analysis. Returns [low, mid, high]
    /// magnitudes in dBFS (-∞ … 0). Runs on the realtime queue,
    /// uses preallocated FFT setup + Hann window.
    nonisolated private func computeBandLevels(samples: UnsafePointer<Float>, frameCount: Int, sampleRate: Float) -> [Float] {
        let n = 1 << fftLog2N    // 512
        let frames = min(frameCount, n)
        guard let setup = fftSetup else { return [-80, -80, -80] }

        // 1) Window the input. Pad with zeros if buffer shorter
        //    than the FFT size (rare with 512 tap on 48kHz).
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, fftWindow, 1, &windowed, 1, vDSP_Length(frames))

        // 2) Run the real-to-complex DFT.
        var realIn = [Float](repeating: 0, count: n / 2)
        var imagIn = [Float](repeating: 0, count: n / 2)
        // Split real input into even/odd halves (vDSP convention).
        windowed.withUnsafeBufferPointer { bufPtr in
            bufPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                var split = DSPSplitComplex(realp: &realIn, imagp: &imagIn)
                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
            }
        }
        var realOut = [Float](repeating: 0, count: n / 2)
        var imagOut = [Float](repeating: 0, count: n / 2)
        vDSP_DFT_Execute(setup, realIn, imagIn, &realOut, &imagOut)

        // 3) Magnitudes: sqrt(re² + im²) per bin, half spectrum.
        let halfN = n / 2
        var mags = [Float](repeating: 0, count: halfN)
        var split = DSPSplitComplex(realp: &realOut, imagp: &imagOut)
        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfN))

        // 4) Average magnitude per band, then convert to dBFS.
        let binHz = sampleRate / Float(n)
        let bands: [(low: Float, high: Float)] = [
            (80, 500),
            (500, 2000),
            (2000, 6000)
        ]
        return bands.map { band in
            let lo = max(1, Int((band.low / binHz).rounded()))
            let hi = min(halfN - 1, Int((band.high / binHz).rounded()))
            guard hi > lo else { return Float(-80) }
            var sum: Float = 0
            for i in lo...hi { sum += mags[i] }
            // Avg magnitude across band, normalised by sample
            // count (windowed signal has half-energy of unit
            // peak), → dBFS.
            let avg = sum / Float(hi - lo + 1)
            let normalised = avg / Float(n) * 2.0
            return 20 * log10f(max(normalised, 1e-7))
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
