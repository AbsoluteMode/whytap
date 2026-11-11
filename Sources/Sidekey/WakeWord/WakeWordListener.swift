import AVFoundation
import Foundation
import os.log

/// What the listener needs from a keyword spotter; `WakeWordSpotter` in
/// production, a scripted fake in tests.
protocol WakeWordSpotting: AnyObject {
    func accept(_ samples: [Float]) -> [String]
}

extension WakeWordSpotter: WakeWordSpotting {}

/// Keeps the microphone open only while the wake word may be used and reports
/// each time the phrase is heard. Audio goes from the microphone straight into
/// the on-device spotter: nothing is stored, logged or sent anywhere.
/// WHY: .project-docs/decisions/2026-11-11-wake-word.md
@MainActor
final class WakeWordListener {
    struct Configuration: Equatable {
        var phrases: [String]
        var threshold: Float
    }

    typealias SpotterFactory = @Sendable (Configuration) throws -> WakeWordSpotting
    typealias MicFactory = @MainActor () -> MicSourcing

    /// After a detection the phrase's tail and echo must not fire it again.
    static let rearmDelay: TimeInterval = 2
    /// A failed start (no usable microphone yet) is tried again while wanted.
    static let retryDelay: Duration = .seconds(30)

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "wake-word")

    var onWake: ((String) -> Void)?
    private(set) var isListening = false

    private let makeSpotter: SpotterFactory
    private let makeMic: MicFactory
    private let now: () -> TimeInterval
    private var wanted: Configuration?
    private var running: Configuration?
    private var mic: MicSourcing?
    private var pump: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var generation = 0
    private var lastWakeAt: TimeInterval?

    init(
        makeSpotter: @escaping SpotterFactory = WakeWordListener.bundledSpotter,
        makeMic: @escaping MicFactory = WakeWordListener.listeningMicrophone,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.makeSpotter = makeSpotter
        self.makeMic = makeMic
        self.now = now
    }

    /// The one control: pass the configuration to listen with, or nil to
    /// release the microphone. Safe to call on every state change.
    func update(listenWith configuration: Configuration?) {
        wanted = configuration
        guard configuration != running else { return }
        stop()
        guard let configuration else { return }
        start(configuration)
    }

    private func start(_ configuration: Configuration) {
        generation += 1
        let generation = generation
        running = configuration
        let makeSpotter = makeSpotter
        let source = makeMic()
        mic = source
        pump = Task { [weak self] in
            do {
                // Model load is file I/O plus graph setup: keep it off main.
                let spotter = try await Task.detached(priority: .utility) {
                    UncheckedSpotter(value: try makeSpotter(configuration))
                }.value
                try Task.checkCancellation()
                try await source.start()
                guard let self, self.generation == generation else {
                    await source.stop()
                    return
                }
                self.isListening = true
                os_log("wake word: listening", log: Self.log, type: .info)
                await Self.pump(source.samples, into: spotter) { [weak self] phrase in
                    self?.heard(phrase, generation: generation)
                }
            } catch is CancellationError {
                await source.stop()
            } catch {
                await source.stop()
                // Only a microphone that may come back is worth retrying; a
                // denied grant or an unusable model/phrase list is not.
                let retryable = !(error is MicCaptureError) && !(error is WakeWordSpotter.Failure)
                self?.startFailed(generation: generation, retry: retryable)
            }
        }
    }

    /// Runs off the main actor: the spotter is touched only from here.
    private nonisolated static func pump(
        _ samples: AsyncStream<[Float]>,
        into spotter: UncheckedSpotter,
        onHeard: @escaping @MainActor (String) -> Void
    ) async {
        let reader = Task.detached(priority: .utility) {
            // Ends on cancellation: the microphone source finishes its stream
            // only when it is deallocated, and this loop is what would keep
            // it (and the loaded model) alive.
            for await chunk in samples {
                if Task.isCancelled { return }
                for phrase in spotter.value.accept(chunk) {
                    await onHeard(phrase)
                }
            }
        }
        // A detached task does not inherit cancellation: pass it on.
        await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
    }

    private func heard(_ phrase: String, generation: Int) {
        guard generation == self.generation, isListening else { return }
        let time = now()
        if let lastWakeAt, time - lastWakeAt < Self.rearmDelay { return }
        lastWakeAt = time
        // Count only; which phrase was heard stays out of the log.
        os_log("wake word: heard", log: Self.log, type: .info)
        onWake?(phrase)
    }

    private func startFailed(generation: Int, retry retryable: Bool) {
        guard generation == self.generation else { return }
        os_log("wake word: could not start listening", log: Self.log, type: .info)
        stop()
        guard retryable else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard !Task.isCancelled, let self, let wanted = self.wanted, self.running == nil else { return }
            self.start(wanted)
        }
    }

    private func stop() {
        generation += 1
        retry?.cancel()
        retry = nil
        pump?.cancel()
        pump = nil
        running = nil
        if isListening { os_log("wake word: stopped", log: Self.log, type: .info) }
        isListening = false
        guard let source = mic else { return }
        mic = nil
        Task { await source.stop() }
    }

    // MARK: - Production dependencies

    nonisolated static func bundledSpotter(_ configuration: Configuration) throws -> WakeWordSpotting {
        guard let model = WakeWordModel.bundled,
              let data = try? Data(contentsOf: model.sentencePiece),
              let tokenizer = WakeWordTokenizer(sentencePieceModel: data) else {
            throw WakeWordSpotter.Failure.modelMissing
        }
        return try WakeWordSpotter(
            model: model,
            keywords: WakeWordKeywords(
                phrases: configuration.phrases, threshold: configuration.threshold, tokenizer: tokenizer
            )
        )
    }

    /// Never prompts: background listening starts only with a grant the user
    /// already gave (the Settings switch is where the prompt belongs).
    static func listeningMicrophone() -> MicSourcing {
        MicCaptureSource(engineOperator: WakeWordMicOperator()) {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw MicCaptureError.permissionDenied
            }
        }
    }
}

/// The spotter is created on one background task and used on another, never
/// concurrently.
private struct UncheckedSpotter: @unchecked Sendable {
    let value: WakeWordSpotting
}
