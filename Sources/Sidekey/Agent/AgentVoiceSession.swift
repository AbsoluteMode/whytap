import Combine
import Foundation

protocol AgentAudioRecording: AnyObject {
    func start() throws
    func stop() throws -> Data
    func cancel()
    /// Maximum normalized [0..1] meter reading observed across the
    /// just-finished recording. Read by `AgentVoiceSession` after `stop()`
    /// so the controller's silence guard can decide whether to transcribe
    /// at all. 0 between recordings.
    var peakEnergy: Float { get }
}

extension AudioRecorder: AgentAudioRecording {}

@MainActor
protocol AgentVoiceSessioning: AnyObject {
    var elapsedSeconds: Double { get }
    var onAutoStop: (() -> Void)? { get set }
    /// Peak audio energy observed across the just-finished recording.
    /// Exposed alongside `elapsedSeconds` so `AgentController` can run a
    /// silence check after `stop()` returns without coupling the
    /// controller to `AudioRecorder` directly. 0 before the recording
    /// completes.
    var peakEnergy: Float { get }

    func start()
    func stop() async -> Data?
    func cancel()
}

@MainActor
final class AgentVoiceSession: ObservableObject, AgentVoiceSessioning {
    private static let defaultTimerInterval: TimeInterval = 0.1

    @Published private(set) var elapsedSeconds: Double = 0

    var onAutoStop: (() -> Void)?

    private let recorder: any AgentAudioRecording
    private let maxDurationSeconds: TimeInterval
    private var timer: Timer?
    private var startedAt: Date?
    private var didStart = false
    private var didStop = false
    private var isCancelled = false
    private var capturedAudio: Data?
    /// Snapshotted at `stop()` so the controller can read the peak after
    /// the recorder has been torn down. Mirrors how `elapsedSeconds` is
    /// frozen at stop time rather than continuing to advance.
    private(set) var peakEnergy: Float = 0

    init(recorder: AudioRecorder, maxDurationSeconds: TimeInterval = 60) {
        self.recorder = recorder
        self.maxDurationSeconds = maxDurationSeconds
    }

    init(recorder: any AgentAudioRecording, maxDurationSeconds: TimeInterval = 60) {
        self.recorder = recorder
        self.maxDurationSeconds = maxDurationSeconds
    }

    func start() {
        guard !didStart, !didStop else { return }

        do {
            try recorder.start()
        } catch {
            isCancelled = true
            didStop = true
            FileHandle.standardError.write(
                Data("Agent voice recording failed to start: \(error)\n".utf8)
            )
            return
        }

        didStart = true
        startedAt = Date()
        elapsedSeconds = 0
        scheduleTimer()
    }

    func stop() async -> Data? {
        stopAndCapture()
    }

    func cancel() {
        guard !didStop else { return }

        isCancelled = true
        didStop = true
        didStart = false
        capturedAudio = nil
        invalidateTimer()
        recorder.cancel()
        elapsedSeconds = 0
    }

    private func scheduleTimer() {
        invalidateTimer()

        guard maxDurationSeconds > 0 else {
            stopForMaxDuration()
            return
        }

        let interval = min(Self.defaultTimerInterval, max(maxDurationSeconds / 10, 0.01))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        updateElapsedSeconds()
        guard elapsedSeconds >= maxDurationSeconds else { return }
        stopForMaxDuration()
    }

    private func stopForMaxDuration() {
        guard !didStop else { return }
        elapsedSeconds = maxDurationSeconds
        _ = stopAndCapture()
        onAutoStop?()
    }

    private func stopAndCapture() -> Data? {
        if didStop {
            return capturedAudio
        }

        guard didStart, !isCancelled else {
            invalidateTimer()
            didStop = true
            didStart = false
            capturedAudio = nil
            return nil
        }

        updateElapsedSeconds()
        invalidateTimer()
        didStop = true
        didStart = false

        do {
            let audio = try recorder.stop()
            capturedAudio = audio.isEmpty ? nil : audio
        } catch {
            capturedAudio = nil
        }
        // Read AFTER `recorder.stop()` — the recorder finalises its
        // peak measurement at stop time and we want the cumulative
        // peak across the whole recording, not the instantaneous one.
        peakEnergy = recorder.peakEnergy

        return capturedAudio
    }

    private func updateElapsedSeconds() {
        guard let startedAt else { return }
        elapsedSeconds = min(Date().timeIntervalSince(startedAt), maxDurationSeconds)
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }
}
