import FluidAudio
import XCTest
@testable import Sidekey

/// The owner's two follow-ups to the clean-M1 report: the take that said
/// Listening and then vanished without text or error must not end silently,
/// and every place that shows the model's download or preparation shows
/// progress with an approximate time left. Clock, rate and machine are
/// injected; no Core ML model loads.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
@MainActor
final class OnDeviceModelProgressTests: XCTestCase {

    // MARK: - The field sequence: Listening, release, then never silence

    private actor ColdDecoder: OnDeviceSpeechDecoding {
        enum Outcome { case stillPreparing, loadFailed, emptyAfterLoad, text(String) }
        private var loaded = false
        private let outcome: Outcome
        init(_ outcome: Outcome) { self.outcome = outcome }
        func modelIsLoaded() async -> Bool { loaded }
        func decode(samples: [Float], language: String?) async throws -> String {
            switch outcome {
            case .stillPreparing: throw OnDeviceSpeechError.modelPreparing
            case .loadFailed: throw OnDeviceSpeechError.modelLoadFailed
            case .emptyAfterLoad: loaded = true; return ""
            case .text(let text): loaded = true; return text
            }
        }
    }

    private final class Sink {
        var phases: [AppPhase] = []
        var noted: [Error] = []
        var retained: Data?
        var pasted: [String] = []

        func make() -> AppDelegate.DropBatchRecoverySink {
            AppDelegate.DropBatchRecoverySink(
                setPhase: { [weak self] in self?.phases.append($0) },
                deliver: { [weak self] text in self?.pasted.append(text); self?.phases.append(.idle); return true },
                retainForRetry: { [weak self] in self?.retained = $0 },
                clearPendingRetry: {},
                failTelemetry: { _ in },
                noteBatchFailure: { [weak self] in self?.noted.append($0) }
            )
        }
    }

    /// 2 s of a 220 Hz tone at about -10 dBFS: speech level.
    private func speech(seconds: Double = 2) -> Data {
        let count = Int(seconds * 16_000)
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let value = Int16(0.3 * Double(Int16.max) * sin(2 * .pi * 220 * Double(index) / 16_000))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func quiet(seconds: Double = 2) -> Data { Data(count: Int(seconds * 16_000) * 2) }

    /// Hold, Listening, release, then what the take ends with: the island's
    /// faces in order and the delivery's last phase.
    private func runTake(_ outcome: ColdDecoder.Outcome, audio: Data) async
        -> (wings: [IslandAgentFlowStore.Wing], result: StreamingSessionResult, sink: Sink) {
        let flow = IslandAgentFlowStore(responseStore: AskResponseStore(), dropProviderBrand: { nil })
        var wings: [IslandAgentFlowStore.Wing] = []
        let source = CapturingStubAudioSource(captured: audio)
        let session = OnDeviceTranscriptionSession(audioEngine: source, decoder: ColdDecoder(outcome), language: nil)
        session.onPreparingModel = { flow.dropLocalModelPreparing(); wings.append(flow.wing) }

        flow.dropPhaseChanged(.recording)
        wings.append(flow.wing)
        async let running = session.run()
        await Task.yield()
        flow.dropPhaseChanged(.transcribing)
        wings.append(flow.wing)
        await session.stop()
        source.stop()
        let result = await running

        let sink = Sink()
        await AppDelegate.resolveDelivery(
            result: result, capturedPCM: audio, lastPartial: "", hasBatchTranscriber: true,
            transcribe: { _ in "" }, sink: sink.make())
        if let phase = sink.phases.last {
            flow.dropPhaseChanged(phase, failureMessage: sink.noted.first.flatMap(ProviderFailure.init)?
                .dropMessage(provider: ""))
            wings.append(flow.wing)
        }
        return (wings, result, sink)
    }

    func test_field_sequence_listening_then_release_while_preparing_ends_with_a_reason_not_silence() async {
        let take = await runTake(.stillPreparing, audio: speech())

        XCTAssertEqual(take.wings.first, .recording(transcript: ""), "held: listening")
        XCTAssertTrue(take.wings.contains(.acting), "released: preparing local model…")
        XCTAssertEqual(take.sink.phases.last, .deliveryFailed, "never idle without text")
        XCTAssertEqual(take.wings.last, .deliveryFailed(message: "Local model still preparing, retry soon"))
        XCTAssertNotNil(take.sink.retained, "Retry has the audio")
    }

    func test_field_sequence_with_a_model_that_did_not_load_ends_with_a_reason() async {
        let take = await runTake(.loadFailed, audio: speech())
        XCTAssertEqual(take.sink.phases.last, .deliveryFailed)
        XCTAssertEqual(take.wings.last, .deliveryFailed(message: "Local model didn't load"))
    }

    func test_model_loaded_during_the_take_and_empty_on_speech_is_not_taken_as_silence() async {
        let take = await runTake(.emptyAfterLoad, audio: speech())
        XCTAssertEqual(take.result, .failed(.localModelNoText))
        XCTAssertEqual(take.sink.phases.last, .deliveryFailed)
        XCTAssertEqual(take.wings.last, .deliveryFailed(message: "No text from local model, Retry"))
        XCTAssertNotNil(take.sink.retained)
    }

    func test_quiet_take_on_a_model_loaded_during_it_is_still_silence() async {
        let take = await runTake(.emptyAfterLoad, audio: quiet())
        XCTAssertEqual(take.result, .transcript(""))
        XCTAssertEqual(take.sink.phases.last, .idle, "a silent room is silence, as decided on 2026-07-26")
    }

    func test_cold_model_that_lands_during_the_wait_pastes_the_take() async {
        let take = await runTake(.text("hello"), audio: speech())
        XCTAssertEqual(take.sink.pasted, ["hello"])
    }

    func test_speech_level_detector() {
        XCTAssertTrue(OnDeviceTranscriptionSession.hasSpeechLevelAudio(speech()))
        XCTAssertFalse(OnDeviceTranscriptionSession.hasSpeechLevelAudio(quiet()))
    }

    // MARK: - Download: time left from the measured rate

    func test_download_time_left_appears_after_a_few_seconds_and_updates() {
        var rate = OnDeviceDownloadRateEstimator()
        rate.record(fraction: 0, at: 0)
        rate.record(fraction: 0.02, at: 1)
        XCTAssertEqual(rate.timeLeft(at: 1), .estimating, "one second of data is not a number yet")

        for second in 2...6 { rate.record(fraction: 0.02 * Double(second), at: Double(second)) }
        guard case .seconds(let first) = rate.timeLeft(at: 6) else { return XCTFail("\(rate.timeLeft(at: 6))") }
        XCTAssertEqual(first, 44, accuracy: 8, "2% a second with 88% left")

        for second in 7...20 { rate.record(fraction: 0.02 * Double(second), at: Double(second)) }
        guard case .seconds(let later) = rate.timeLeft(at: 20) else { return XCTFail() }
        XCTAssertLessThan(later, first, "the number counts down")
        XCTAssertEqual(OnDeviceSpeechProgressText.timeLeft(.seconds(later)), "Less than a minute left")
    }

    func test_download_time_left_hides_on_stall_and_returns_with_progress() {
        var rate = OnDeviceDownloadRateEstimator()
        for second in 0...6 { rate.record(fraction: 0.01 * Double(second), at: Double(second)) }
        XCTAssertNotEqual(rate.timeLeft(at: 6), .estimating)
        XCTAssertEqual(rate.timeLeft(at: 17), .stalled, "no number while nothing arrives")
        XCTAssertEqual(OnDeviceSpeechProgressText.timeLeft(.stalled), "Stalled. Check your connection.")
        rate.record(fraction: 0.08, at: 18)
        guard case .seconds = rate.timeLeft(at: 18) else { return XCTFail("back after progress") }
    }

    func test_minutes_round_up_and_never_count_below_less_than_a_minute() {
        XCTAssertEqual(OnDeviceSpeechProgressText.timeLeft(.seconds(170)), "About 3 min left")
        XCTAssertEqual(OnDeviceSpeechProgressText.timeLeft(.seconds(61)), "About 2 min left")
        XCTAssertEqual(OnDeviceSpeechProgressText.timeLeft(.seconds(60)), "Less than a minute left")
        XCTAssertEqual(OnDeviceSpeechProgressText.timeLeft(.seconds(1)), "Less than a minute left")
        XCTAssertEqual(OnDeviceSpeechProgressText.accessibilityTimeLeft(.seconds(170)), "about 3 minutes left")
    }

    /// The controller from the first percent to a stall, with a clock the
    /// test moves.
    private actor HeldDownloadStore: OnDeviceSpeechModelManaging {
        private var progress: (@Sendable (Double) -> Void)?
        private var finish: CheckedContinuation<Void, Never>?
        func status() -> OnDeviceSpeechModelStatus { .notDownloaded }
        func download(progress: (@Sendable (Double) -> Void)?) async throws {
            self.progress = progress
            await withCheckedContinuation { finish = $0 }
        }
        func emit(_ fraction: Double) { progress?(fraction) }
        func end() { finish?.resume(); finish = nil }
        func hasProgress() -> Bool { progress != nil }
        func delete() async throws {}
        func acquire() async throws -> AsrManager { throw OnDeviceSpeechError.modelNotDownloaded }
        func release() {}
    }

    func test_settings_controller_shows_time_left_while_downloading_and_stalled_when_it_stops() async {
        let store = HeldDownloadStore()
        var clock: TimeInterval = 100
        let controller = OnDeviceSpeechModelController(store: store, now: { clock }, tickInterval: nil)
        let download = Task { await controller.download() }
        await eventually { await store.hasProgress() }
        XCTAssertEqual(controller.timeLeft, .estimating)

        for step in 1...8 {
            clock = 100 + Double(step)
            await store.emit(0.05 * Double(step))
            await eventually { if case .downloading(let f) = controller.status { return f >= 0.05 * Double(step) - 1e-9 }; return false }
        }
        await controller.tick()
        guard case .seconds(let left) = controller.timeLeft else { return XCTFail("\(String(describing: controller.timeLeft))") }
        XCTAssertEqual(left, 12, accuracy: 4, "5% a second with 60% left")

        clock += 30
        await controller.tick()
        XCTAssertEqual(controller.timeLeft, .stalled)
        await store.end()
        _ = await download.value
    }

    // MARK: - Preparation: an honest estimate

    func test_expected_preparation_comes_from_the_machine_class() {
        let m1 = OnDeviceSpeechMachine(brand: "Apple M1", memoryBytes: 8 * 1_073_741_824)
        XCTAssertEqual(m1, OnDeviceSpeechMachine(generation: 1, isHighEnd: false, memoryGB: 8))
        XCTAssertEqual(OnDeviceSpeechPreparationEstimator.tableSeconds(.firstCompile, machine: m1), 240)
        XCTAssertEqual(OnDeviceSpeechPreparationEstimator.tableSeconds(.reload, machine: m1), 15)
        let pro = OnDeviceSpeechMachine(brand: "Apple M4 Pro", memoryBytes: 48 * 1_073_741_824)
        XCTAssertEqual(pro.generation, 4)
        XCTAssertTrue(pro.isHighEnd)
        XCTAssertEqual(OnDeviceSpeechPreparationEstimator.tableSeconds(.firstCompile, machine: pro), 45)
        let unknown = OnDeviceSpeechMachine(brand: "", memoryBytes: 16 * 1_073_741_824)
        XCTAssertEqual(OnDeviceSpeechPreparationEstimator.tableSeconds(.firstCompile, machine: unknown), 180)
    }

    func test_a_duration_measured_on_this_mac_replaces_the_table() {
        let history = OnDeviceModelPreparationTests.MemoryHistory()
        let estimator = OnDeviceSpeechPreparationEstimator(
            machine: OnDeviceSpeechMachine(generation: 1, isHighEnd: false, memoryGB: 8), history: history)
        XCTAssertEqual(estimator.expectedSeconds(.firstCompile), 240)
        history.record(.firstCompile, seconds: 100)
        XCTAssertEqual(estimator.expectedSeconds(.firstCompile), 125, "measured, with headroom")
    }

    func test_long_preparation_says_so_instead_of_a_wrong_number() {
        let estimator = OnDeviceSpeechPreparationEstimator(
            machine: OnDeviceSpeechMachine(generation: 1, isHighEnd: false, memoryGB: 8),
            history: OnDeviceModelPreparationTests.MemoryHistory())
        XCTAssertEqual(estimator.timeLeft(elapsed: 60, kind: .firstCompile), .seconds(180))
        XCTAssertEqual(OnDeviceSpeechProgressText.timeLeft(estimator.timeLeft(elapsed: 200, kind: .firstCompile)),
                       "Less than a minute left")
        XCTAssertEqual(estimator.timeLeft(elapsed: 241, kind: .firstCompile), .longerThanUsual)
        XCTAssertEqual(OnDeviceSpeechProgressText.timeLeft(.longerThanUsual), "Taking longer than usual, still working")
    }

    func test_store_estimates_the_running_preparation_and_reuses_its_duration_next_time() async throws {
        let history = OnDeviceModelPreparationTests.MemoryHistory()
        let gate = Gate()
        let clock = Clock(start: 1_000)
        let store = OnDeviceSpeechModelStore(
            rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            idleEviction: .seconds(3600),
            filesPresent: { true },
            uptime: { clock.now },
            machine: OnDeviceSpeechMachine(generation: 1, isHighEnd: false, memoryGB: 8),
            history: history,
            downloadFiles: { _, _, _ in },
            loadModel: { _, _ in await gate.wait(); return AsrManager() }
        )
        let preparing = Task { await store.prepare() }
        await eventually { await store.preparationTimeLeft() != nil }
        XCTAssertEqual(store.currentPreparationTimeLeft(), .seconds(240), "first compile on an 8 GB M1")
        clock.now += 90
        XCTAssertEqual(store.currentPreparationTimeLeft(), .seconds(150))
        await gate.open()
        _ = await preparing.value
        XCTAssertNil(store.currentPreparationTimeLeft())
        XCTAssertTrue(history.hasCompiled)
        XCTAssertNotNil(history.lastDuration(.firstCompile), "the real duration is kept for the next estimate")
    }

    // MARK: - The same state in Settings, onboarding and the island

    func test_settings_and_onboarding_show_the_same_progress() {
        let downloading = OnDeviceSpeechModelStatus.downloading(0.42)
        let left = OnDeviceSpeechTimeLeft.seconds(170)
        XCTAssertEqual(OnDeviceSpeechCard.Presentation(downloading, timeLeft: left).detail,
                       "42% of about 470 MB · About 3 min left")
        XCTAssertEqual(OnboardingModelProgressStrip.line(downloading, timeLeft: left),
                       "Speech model · 42% · About 3 min left")
        XCTAssertEqual(OnboardingSpeechPage.Presentation(downloading, timeLeft: left).detail,
                       "Downloading · 42% · About 3 min left")
        XCTAssertEqual(OnDeviceSpeechCard.Presentation(downloading, timeLeft: left).accessibilityValue,
                       "42 percent, about 3 minutes left")

        let preparing = OnDeviceSpeechTimeLeft.longerThanUsual
        XCTAssertEqual(OnDeviceSpeechCard.Presentation(.preparing, timeLeft: preparing).detail,
                       "Taking longer than usual, still working. You can leave this tab.")
        XCTAssertEqual(OnboardingModelProgressStrip.line(.preparing, timeLeft: preparing),
                       "Speech model · preparing · Taking longer than usual, still working")
        XCTAssertEqual(OnboardingModelProgressStrip.line(.ready, timeLeft: nil), "Speech model ready · Drop works now")
        XCTAssertEqual(OnboardingModelStatusCard.hint(.seconds(30)),
                       "Less than a minute left. You can continue; Drop works as soon as it's ready.")
        XCTAssertEqual(OnboardingJourneyModel.modelNotReadyMessage(.preparing, timeLeft: .seconds(170)),
                       "The speech model is preparing · About 3 min left. Drop works as soon as it's ready.")
        XCTAssertEqual(OnDeviceSpeechCard.Presentation(.downloading(0.42), timeLeft: .stalled).detail,
                       "42% of about 470 MB · Stalled. Check your connection.")
    }

    func test_island_retry_message_says_when_the_model_will_be_ready() {
        XCTAssertEqual(ProviderFailure.localModelPreparingMessage(.seconds(170)), "Local model: about 3 min left")
        XCTAssertEqual(ProviderFailure.localModelPreparingMessage(.seconds(20)), "Local model: less than a minute left")
        XCTAssertEqual(ProviderFailure.localModelPreparingMessage(.longerThanUsual), "Local model still preparing, retry soon")
        XCTAssertEqual(ProviderFailure.localModelPreparingMessage(nil), "Local model still preparing, retry soon")
    }

    // MARK: - Helpers

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval
        init(start: TimeInterval) { value = start }
        var now: TimeInterval {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out")
    }
}
