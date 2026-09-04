import AVFoundation
import Foundation

/// Wraps `AVAudioRecorder` with the project's WAV settings: 16 kHz, mono,
/// 16-bit signed little-endian PCM (Gemini-friendly input format).
///
/// While recording, samples a 30 Hz meter and pushes normalized [0..1]
/// amplitudes into `AppState.shared.audioLevels` so the floating pill can
/// render a live waveform.
final class AudioRecorder {
    /// 30 Hz sampling rate matches the reference UI (`updateRate = 30`).
    private static let meterInterval: TimeInterval = 1.0 / 30.0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private(set) var currentURL: URL?
    /// Wall-clock start of the current recording. Captured at `start()`
    /// time so `AudioSilenceDetector` can decide whether the gesture
    /// lasted long enough to plausibly contain speech without relying on
    /// the WAV file's sample count (the file may be truncated by a
    /// recorder hiccup; the wall-clock measurement is more robust). Nil
    /// when no recording is in flight.
    private(set) var startedAt: Date?
    /// Maximum normalized [0..1] meter reading observed across the
    /// current recording, updated on every meter tick. Reset to 0 on
    /// `start()` so consecutive recordings don't carry state forward.
    /// `AudioSilenceDetector` reads this at stop time to decide whether
    /// the user actually said anything.
    private(set) var peakEnergy: Float = 0
    /// Wall-clock duration of the last completed recording. Captured
    /// inside `stop()` because `startedAt` is cleared as part of the
    /// stop sequence, and we want callers to be able to query the
    /// duration after `stop()` returns. 0 between recordings.
    private(set) var lastDurationSeconds: TimeInterval = 0

    func start() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidekey_\(Int(Date().timeIntervalSince1970)).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw VEError.recorderNotStarted
        }
        self.recorder = recorder
        self.currentURL = url
        // Snapshot wall-clock start + reset per-recording stats so the
        // silence detector reads accurate values for THIS gesture rather
        // than carrying state from a previous one.
        self.startedAt = Date()
        self.peakEnergy = 0
        self.lastDurationSeconds = 0
        startMeterTimer()
    }

    /// Stops recording, reads the resulting WAV file into memory, deletes the
    /// temp file, and returns the bytes.
    func stop() throws -> Data {
        stopMeterTimer()
        guard let recorder = recorder, let url = currentURL else {
            throw VEError.recorderNotStarted
        }
        recorder.stop()
        // Compute final duration BEFORE clearing `startedAt` so the
        // silence detector's caller can read `lastDurationSeconds` after
        // we return. `Date()` here is the wall-clock stop instant; same
        // measurement basis as the duration `start()` captures.
        if let startedAt {
            lastDurationSeconds = Date().timeIntervalSince(startedAt)
        }
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        self.recorder = nil
        self.currentURL = nil
        self.startedAt = nil
        Task { @MainActor in AppState.shared.clearAudioLevels() }

        guard !data.isEmpty else { throw VEError.audioFileEmpty }
        return data
    }

    /// Best-effort cleanup if the recorder is still alive when the app exits.
    func cancel() {
        stopMeterTimer()
        recorder?.stop()
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        currentURL = nil
        startedAt = nil
        Task { @MainActor in AppState.shared.clearAudioLevels() }
    }

    // MARK: - Metering

    private func startMeterTimer() {
        let timer = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            self?.tickMeter()
        }
        // Use .common so the meter keeps firing during menu/event tracking.
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func tickMeter() {
        guard let recorder = recorder else { return }
        recorder.updateMeters()
        let dB = recorder.averagePower(forChannel: 0)
        let level = AudioMeter.normalize(dB: dB)
        // Track the loudest moment of the recording. `AudioMeter.normalize`
        // already clamps non-finite inputs to 0, so `peakEnergy` is
        // guaranteed finite; even so, `AudioSilenceDetector.decide`
        // double-checks `isFinite` defensively.
        if level > peakEnergy {
            peakEnergy = level
        }
        Task { @MainActor in AppState.shared.pushAudioLevel(level) }
    }
}
