import AVFoundation
import Foundation
import os.log

/// Blocking `AVAudioEngine` / HAL half of `MicCaptureSource`, behind a seam
/// so the threading contract is unit-testable: every call here is synchronous
/// audio-device work (input node creation, format reads, tap install,
/// engine start/stop) that stalls for seconds while a meeting's audio devices
/// come up — it must NEVER run on the main thread.
/// WHY: docs/decisions/2026-07-08-meeting-audio-hal-scan-off-main.md
protocol MicEngineOperating: Sendable {
    /// Install the input tap and start the engine. Blocking HAL work.
    /// Cleans the engine up itself before rethrowing on failure.
    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    /// Remove the tap, stop and reset the engine. Blocking HAL work.
    func stopCapture()
    /// Object `AVAudioEngineConfigurationChange` notifications are posted
    /// for — the concrete `AVAudioEngine` in production.
    var configurationChangeObject: AnyObject { get }
}

/// Production `MicEngineOperating`: owns the `AVAudioEngine` and performs
/// the actual tap + engine lifecycle.
final class AVAudioEngineMicOperator: MicEngineOperating, @unchecked Sendable {
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "recorder")
    private let engine = AVAudioEngine()

    var configurationChangeObject: AnyObject { engine }

    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let inputNode = engine.inputNode
        let hardwareInputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = inputNode.outputFormat(forBus: 0)
        let tapFormat = MicTapFormatSelector.preferredTapFormat(
            inputFormat: hardwareInputFormat,
            outputFormat: outputFormat
        )

        inputNode.removeTap(onBus: 0)
        os_log(
            "MicCaptureSource: installing tap inputRate=%{public}.0f inputChannels=%{public}u outputRate=%{public}.0f outputChannels=%{public}u tapRate=%{public}.0f tapChannels=%{public}u",
            log: Self.log,
            type: .info,
            hardwareInputFormat.sampleRate,
            hardwareInputFormat.channelCount,
            outputFormat.sampleRate,
            outputFormat.channelCount,
            tapFormat?.sampleRate ?? 0,
            tapFormat?.channelCount ?? 0
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: tapFormat
        ) { buffer, _ in
            onBuffer(buffer)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
            throw error
        }
    }

    func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
    }
}

/// `AVAudioEngine` microphone capture for meeting recording. This is an
/// audio-only path: macOS shows the microphone privacy indicator, not the
/// Screen Recording indicator.
final class MicCaptureSource: MicSourcing, @unchecked Sendable {
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "recorder")
    private static let restartRetryDelaysNanoseconds: [UInt64] = [
        0,
        750_000_000,
        1_500_000_000,
        3_000_000_000,
        5_000_000_000
    ]

    let samples: AsyncStream<[Float]>
    private let samplesContinuation: AsyncStream<[Float]>.Continuation

    private let engineOperator: MicEngineOperating
    private let ensureAccess: @Sendable () async throws -> Void
    private let targetFormat: AVAudioFormat
    private let processingQueue = DispatchQueue(
        label: "com.sidekey.meetings.mic.processing",
        qos: .userInitiated
    )
    /// Serial home for all blocking engine/HAL work. Keeping it off the
    /// MainActor is the whole point: `engine.start()` / device-format reads
    /// stall for seconds while a meeting's audio devices come up (Bluetooth
    /// switching to HFP, Zoom claiming the input), and on main that froze
    /// the UI right after clicking Take notes / Stop.
    /// WHY: docs/decisions/2026-07-08-meeting-audio-hal-scan-off-main.md
    private let engineQueue = DispatchQueue(
        label: "com.sidekey.meetings.mic.engine",
        qos: .userInitiated
    )

    private var converter: AVAudioConverter?
    private var converterInputSignature: MicInputFormatSignature?
    private var isCaptureRequested = false
    private var isRunning = false
    /// True while `start()` is awaiting off-main engine work. Closes the
    /// re-entrancy window a second `start()` would otherwise slip through
    /// (the window predates this flag — `ensureMicrophoneAccess` already
    /// suspended — but widens with the engine hop).
    private var isStarting = false
    private var configurationObserver: NSObjectProtocol?

    /// Session counter for meeting-health telemetry (Task 7): every time the
    /// debounced route-change restart actually fires (i.e. the input route
    /// changed while capture was active). Monotonic within the process —
    /// `MeetingRecorder` snapshots start/stop deltas so route churn outside
    /// a meeting never leaks in. `@MainActor`-affine like the rest of this
    /// type's mutable state; only mutated inside
    /// `restartAfterConfigurationChange()`. Privacy inv. #3: a count only,
    /// never a device name.
    @MainActor
    private(set) var inputRouteChangeCount = 0

    private lazy var restartMonitor = AudioCaptureRestartMonitor(
        debounceNanoseconds: MicRouteChangePolicy.restartDebounceNanoseconds
    ) { [weak self] in
        await self?.restartAfterConfigurationChange()
    }

    /// - Parameters:
    ///   - engineOperator: blocking engine/HAL operations. Production
    ///     default owns a real `AVAudioEngine`; tests inject a
    ///     thread-observing fake.
    ///   - ensureAccess: microphone-permission gate. Production default
    ///     prompts / throws via `ensureMicrophoneAccess`; tests inject a
    ///     no-op so `start()` reaches the engine path headlessly.
    init(
        engineOperator: MicEngineOperating = AVAudioEngineMicOperator(),
        ensureAccess: @escaping @Sendable () async throws -> Void = {
            try await MicCaptureSource.ensureMicrophoneAccess()
        }
    ) {
        self.engineOperator = engineOperator
        self.ensureAccess = ensureAccess
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        self.samples = stream
        self.samplesContinuation = cont
        self.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engineOperator.configurationChangeObject,
            queue: .main
        ) { [weak self] _ in
            self?.restartMonitor.trigger()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        restartMonitor.setActive(false)
        samplesContinuation.finish()
    }

    @MainActor
    func start() async throws {
        guard !isRunning, !isStarting else {
            isCaptureRequested = true
            return
        }

        // Request BEFORE the first suspension so a concurrent stop() is the
        // later call and wins: each `guard isCaptureRequested` below honors
        // it after the corresponding await.
        isCaptureRequested = true
        isStarting = true
        defer { isStarting = false }

        // Gate on microphone permission. Without this, a denied/undetermined
        // grant leaves the input node with an invalid format -> the converter
        // is nil -> zero samples are produced, and the recording runs but
        // captures nothing (silent failure). Surface it instead.
        try await ensureAccess()
        guard isCaptureRequested else { return }

        resetConverter()

        let engineOperator = self.engineOperator
        let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
            self?.process(inputBuffer: buffer)
        }
        do {
            try await runEngineWork {
                try engineOperator.startCapture(onBuffer: onBuffer)
            }
        } catch {
            resetConverter()
            os_log(
                "MicCaptureSource: AVAudioEngine start failed %{public}@",
                log: Self.log, type: .error,
                String(describing: error)
            )
            throw error
        }

        guard isCaptureRequested else {
            // stop() arrived while the engine was starting off-main —
            // honor it instead of leaving a live capture nobody asked for.
            await runEngineWork { engineOperator.stopCapture() }
            resetConverter()
            return
        }

        isRunning = true
        restartMonitor.setActive(true)
        os_log("MicCaptureSource: AVAudioEngine started", log: Self.log, type: .info)
    }

    @MainActor
    func stop() async {
        isCaptureRequested = false
        restartMonitor.setActive(false)
        guard isRunning else { return }
        await stopEngine()
        os_log("MicCaptureSource: AVAudioEngine stopped", log: Self.log, type: .info)
    }

    @MainActor
    private func restartAfterConfigurationChange() async {
        guard isCaptureRequested, isRunning else { return }
        inputRouteChangeCount += 1
        restartMonitor.setActive(false)
        os_log(
            "MicCaptureSource: audio engine configuration changed; restarting capture",
            log: Self.log,
            type: .info
        )
        await stopEngine()

        let retrier = AudioCaptureRestartRetrier(
            delaysNanoseconds: Self.restartRetryDelaysNanoseconds
        )
        do {
            try await retrier.run(
                operation: { attempt in
                    guard self.isCaptureRequested else {
                        throw CancellationError()
                    }
                    try await self.start()
                    os_log(
                        "MicCaptureSource: restart attempt %{public}d succeeded after audio engine configuration change",
                        log: Self.log,
                        type: .info,
                        attempt
                    )
                },
                onFailure: { attempt, error in
                    os_log(
                        "MicCaptureSource: restart attempt %{public}d failed after configuration change %{public}@",
                        log: Self.log,
                        type: .error,
                        attempt,
                        String(describing: error)
                    )
                }
            )
        } catch is CancellationError {
            restartMonitor.setActive(false)
            os_log(
                "MicCaptureSource: restart after configuration change cancelled",
                log: Self.log,
                type: .info
            )
        } catch {
            restartMonitor.setActive(false)
            os_log(
                "MicCaptureSource: restart after configuration change exhausted retries %{public}@",
                log: Self.log,
                type: .error,
                String(describing: error)
            )
        }
    }

    @MainActor
    private func stopEngine() async {
        isRunning = false
        let engineOperator = self.engineOperator
        await runEngineWork { engineOperator.stopCapture() }
        resetConverter()
    }

    /// Runs blocking engine/HAL work on the dedicated serial queue and
    /// suspends the caller (freeing the main thread) until it finishes.
    private func runEngineWork(_ work: @escaping @Sendable () -> Void) async {
        let queue = engineQueue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }

    private func runEngineWork(_ work: @escaping @Sendable () throws -> Void) async throws {
        let queue = engineQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Resolve microphone permission before capture. Prompts on first use
    /// (`.notDetermined`); throws `MicCaptureError.permissionDenied` when the
    /// user denied access, so the recorder surfaces it instead of silently
    /// capturing nothing.
    static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw MicCaptureError.permissionDenied }
        case .denied, .restricted:
            throw MicCaptureError.permissionDenied
        @unknown default:
            throw MicCaptureError.permissionDenied
        }
    }

    private func process(inputBuffer: AVAudioPCMBuffer) {
        processingQueue.async { [weak self] in
            guard let self,
                  let samples = self.convertToMono16k(inputBuffer),
                  !samples.isEmpty else {
                return
            }
            self.samplesContinuation.yield(samples)
        }
    }

    private func convertToMono16k(_ inputBuffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = inputBuffer.format
        let inputSignature = MicInputFormatSignature(format: inputFormat)
        if converter == nil || converterInputSignature != inputSignature {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputSignature = converter == nil ? nil : inputSignature
            os_log(
                "MicCaptureSource: converter input format sampleRate=%{public}.0f channels=%{public}u",
                log: Self.log,
                type: .info,
                inputSignature.sampleRate,
                inputSignature.channelCount
            )
        }
        guard let converter else { return nil }
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(max(1024, Int(inputBuffer.frameLength)))
        ) else {
            return nil
        }

        var error: NSError?
        var didFeedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if didFeedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didFeedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil else { return nil }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0,
              let channelData = outBuffer.floatChannelData?.pointee else {
            return []
        }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        return MicSampleGain.applyDefault(to: samples)
    }

    private func resetConverter() {
        processingQueue.sync {
            converter = nil
            converterInputSignature = nil
        }
    }
}

struct MicInputFormatSignature: Equatable {
    let commonFormat: AVAudioCommonFormat
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let isInterleaved: Bool

    init(format: AVAudioFormat) {
        self.commonFormat = format.commonFormat
        self.sampleRate = format.sampleRate
        self.channelCount = format.channelCount
        self.isInterleaved = format.isInterleaved
    }
}

enum MicTapFormatSelector {
    static func preferredTapFormat(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) -> AVAudioFormat? {
        if canCarryAudio(inputFormat) {
            return inputFormat
        }
        if canCarryAudio(outputFormat) {
            return outputFormat
        }
        return nil
    }

    private static func canCarryAudio(_ format: AVAudioFormat) -> Bool {
        format.channelCount > 0 && format.sampleRate > 0
    }
}

enum MicRouteChangePolicy {
    /// Bluetooth route switches can publish several transient input/output
    /// formats before the browser's WebRTC capture graph settles. Restarting
    /// Sidekey's input tap too early can race the meeting app's own mic stream.
    static let restartDebounceNanoseconds: UInt64 = 2_500_000_000
}

/// Microphone capture errors surfaced to the recorder / coordinator so a
/// permission problem is visible instead of a silent empty recording.
enum MicCaptureError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is off. Enable it in System Settings → "
                + "Privacy & Security → Microphone, then start the recording again."
        }
    }
}
