import FluidAudio
import XCTest
@testable import Sidekey

/// The field report behind these tests: a fresh M1, the model on this Mac
/// chosen for Drop, every take said "listening" and pasted nothing, until it
/// started working by itself tens of minutes later. The first Core ML load
/// (Neural Engine compilation) took longer than the take's 60 s deadline, the
/// loaded model was thrown away, and the next take started over.
///
/// The model load is a fake gated by the test, the clock is injected, and no
/// Core ML model is loaded.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
@MainActor
final class OnDeviceModelPreparationTests: XCTestCase {

    // MARK: - Fakes

    /// A load or a download the test finishes when it wants.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        private(set) var entered = 0
        var isOpen: Bool { opened }

        func wait() async {
            entered += 1
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func increment() { lock.lock(); value += 1; lock.unlock() }
    }

    private struct LoadFailure: Error {}

    /// The take's wait (45 s) and the batch wait (20 s) expire at once when
    /// `expireWaits` is set; idle eviction (an hour here) never fires.
    private static func sleep(expireWaits: Flag) -> OnDeviceSpeechModelStore.Sleep {
        { duration in
            if duration < .seconds(3600), expireWaits.isSet { return }
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private struct StoreFixture {
        let store: OnDeviceSpeechModelStore
        let files: Flag
        let loadGate: Gate
        let downloadGate: Gate
        let loads: Counter
        let loadFails: Flag
        let expireWaits: Flag
    }

    private func makeStore(filesPresent: Bool = true, loadOpen: Bool = false) async -> StoreFixture {
        let files = Flag(); files.set(filesPresent)
        let loadGate = Gate()
        if loadOpen { await loadGate.open() }
        let downloadGate = Gate()
        let loads = Counter()
        let loadFails = Flag()
        let expireWaits = Flag()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("on-device-prep-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = OnDeviceSpeechModelStore(
            rootDirectory: root,
            idleEviction: .seconds(3600),
            filesPresent: { files.isSet },
            sleep: Self.sleep(expireWaits: expireWaits),
            downloadFiles: { _, _, progress in
                // FluidAudio moves files in one by one: every folder can
                // exist before the download has finished.
                files.set(true)
                progress(0.5)
                await downloadGate.wait()
                try Task.checkCancellation()
            },
            loadModel: { _, _ in
                loads.increment()
                await loadGate.wait()
                if loadFails.isSet { throw LoadFailure() }
                return AsrManager()
            }
        )
        return StoreFixture(store: store, files: files, loadGate: loadGate, downloadGate: downloadGate,
                            loads: loads, loadFails: loadFails, expireWaits: expireWaits)
    }

    /// Waits until `condition` holds, yielding to the actors involved.
    private func eventually(
        _ message: String, timeout: TimeInterval = 5, _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out: \(message)")
    }

    // MARK: - Store: download, preparation, Ready

    func test_take_during_download_is_not_ready_even_when_the_folders_already_exist() async throws {
        let fixture = await makeStore(filesPresent: false)
        let download = Task { try await fixture.store.download(progress: nil) }
        await eventually("download started") { await fixture.downloadGate.entered == 1 }

        XCTAssertTrue(fixture.files.isSet, "the folders exist before the download ends")
        XCTAssertTrue(fixture.store.snapshot.isDownloading, "route readiness sees the running download")
        let status = await fixture.store.status()
        guard case .downloading = status else { return XCTFail("status \(status)") }
        do {
            _ = try await fixture.store.acquire(within: .seconds(45))
            XCTFail("a take must not load files that are still arriving")
        } catch {
            XCTAssertEqual(error as? OnDeviceSpeechError, .modelNotDownloaded)
        }
        XCTAssertEqual(fixture.loads.count, 0, "nothing loads while the files arrive")

        await fixture.downloadGate.open()
        try await download.value
        XCTAssertFalse(fixture.store.snapshot.isDownloading)
    }

    func test_settings_shows_downloading_then_preparing_then_ready_only_when_loaded() async {
        let fixture = await makeStore(filesPresent: false)
        let controller = OnDeviceSpeechModelController(store: fixture.store)

        let download = Task { await controller.download() }
        await eventually("download started") { await fixture.downloadGate.entered == 1 }
        guard case .downloading = controller.status else { return XCTFail("status \(controller.status)") }

        await fixture.downloadGate.open()
        await eventually("preparing after the files land") { controller.status == .preparing }
        XCTAssertEqual(fixture.loads.count, 1, "the download starts the preparation itself")
        let midway = await fixture.store.status()
        XCTAssertEqual(midway, .preparing, "not Ready while Core ML still loads")

        await fixture.loadGate.open()
        let filesInPlace = await download.value
        XCTAssertTrue(filesInPlace)
        XCTAssertEqual(controller.status, .ready)
        XCTAssertEqual(fixture.loads.count, 1)
    }

    func test_take_right_after_download_joins_the_preparation_and_decodes_when_it_lands() async throws {
        let fixture = await makeStore(filesPresent: true)
        let preparing = Task { await fixture.store.prepare() }
        await eventually("load started") { await fixture.loadGate.entered == 1 }

        let take = Task { try await fixture.store.acquire(within: .seconds(45)) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await fixture.loadGate.open()
        _ = try await take.value
        await fixture.store.release()

        let prepared = await preparing.value
        XCTAssertTrue(prepared)
        XCTAssertEqual(fixture.loads.count, 1, "one load for everyone, not one per caller")
    }

    func test_preparation_slower_than_the_take_wait_keeps_its_model_for_the_next_take() async throws {
        let fixture = await makeStore(filesPresent: true)
        fixture.expireWaits.set(true)

        do {
            _ = try await fixture.store.acquire(within: .seconds(45))
            XCTFail("the wait must end while the model still loads")
        } catch {
            XCTAssertEqual(error as? OnDeviceSpeechError, .modelPreparing)
        }
        let status = await fixture.store.status()
        XCTAssertEqual(status, .preparing, "the load goes on after the take stops waiting")

        await fixture.loadGate.open()
        await eventually("ready after the slow load") { await fixture.store.status() == .ready }
        _ = try await fixture.store.acquire(within: .seconds(45))
        await fixture.store.release()
        XCTAssertEqual(fixture.loads.count, 1, "the slow load's model is kept, not thrown away and loaded again")
    }

    func test_preparation_failure_is_reported_and_the_next_take_tries_again() async throws {
        let fixture = await makeStore(filesPresent: true, loadOpen: true)
        fixture.loadFails.set(true)

        do {
            _ = try await fixture.store.acquire(within: .seconds(45))
            XCTFail("a failed load must fail the take")
        } catch {
            XCTAssertEqual(error as? OnDeviceSpeechError, .modelLoadFailed)
        }
        let failed = await fixture.store.status()
        XCTAssertEqual(failed, .loadFailed)

        fixture.loadFails.set(false)
        _ = try await fixture.store.acquire(within: .seconds(45))
        await fixture.store.release()
        XCTAssertEqual(fixture.loads.count, 2)
        let ready = await fixture.store.status()
        XCTAssertEqual(ready, .ready)
    }

    func test_cold_launch_shows_preparing_and_settings_prepares_the_model() async {
        let fixture = await makeStore(filesPresent: true)
        let controller = OnDeviceSpeechModelController(store: fixture.store)

        let refresh = Task { await controller.refresh() }
        await eventually("preparing at launch") { controller.status == .preparing }
        await fixture.loadGate.open()
        await refresh.value
        XCTAssertEqual(controller.status, .ready)
    }

    func test_warm_model_decodes_without_waiting_or_loading_again() async throws {
        let fixture = await makeStore(filesPresent: true, loadOpen: true)
        let prepared = await fixture.store.prepare()
        XCTAssertTrue(prepared)
        let loaded = await fixture.store.isLoaded()
        XCTAssertTrue(loaded)

        // Waits that would expire at once prove no wait is entered.
        fixture.expireWaits.set(true)
        for _ in 0..<3 {
            _ = try await fixture.store.acquire(within: .seconds(45))
            await fixture.store.release()
        }
        XCTAssertEqual(fixture.loads.count, 1)
    }

    func test_a_caller_that_stops_waiting_leaves_the_preparation_running() async throws {
        let fixture = await makeStore(filesPresent: true)
        let take = Task { try await fixture.store.acquire(within: nil) }
        await eventually("load started") { await fixture.loadGate.entered == 1 }
        take.cancel()
        do {
            _ = try await take.value
            XCTFail("a cancelled take must not wait for the load")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        await fixture.loadGate.open()
        await eventually("ready after the cancelled wait") { await fixture.store.status() == .ready }
    }

    func test_removing_the_model_while_it_prepares_keeps_nothing() async throws {
        let fixture = await makeStore(filesPresent: true)
        let take = Task { try await fixture.store.acquire(within: nil) }
        await eventually("load started") { await fixture.loadGate.entered == 1 }

        fixture.files.set(false)
        try await fixture.store.delete()
        do {
            _ = try await take.value
            XCTFail("a take on removed files must fail")
        } catch {
            XCTAssertEqual(error as? OnDeviceSpeechError, .modelNotDownloaded)
        }
        await fixture.loadGate.open()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let status = await fixture.store.status()
        XCTAssertEqual(status, .notDownloaded)
        let loaded = await fixture.store.isLoaded()
        XCTAssertFalse(loaded)
    }

    // MARK: - Session: what a take does while the model loads

    /// A decoder over a model that is loaded when the test says so.
    private actor PreparingDecoder: OnDeviceSpeechDecoding {
        enum Outcome { case text(String), stillPreparing, loadFailed }

        private var loaded: Bool
        private let gate: Gate
        private let outcome: Outcome
        private(set) var prepareCalls = 0
        private(set) var decodes = 0

        init(loaded: Bool, gate: Gate, outcome: Outcome = .text("hello from this mac")) {
            self.loaded = loaded
            self.gate = gate
            self.outcome = outcome
        }

        func prepareModel() async { prepareCalls += 1 }
        func modelIsLoaded() async -> Bool { loaded }

        func decode(samples: [Float], language: String?) async throws -> String {
            decodes += 1
            if !loaded {
                switch outcome {
                case .stillPreparing: throw OnDeviceSpeechError.modelPreparing
                case .loadFailed: throw OnDeviceSpeechError.modelLoadFailed
                case .text:
                    // Like the store's wait: cancelling the take ends it at once.
                    while !(await gate.isOpen) { try await Task.sleep(nanoseconds: 1_000_000) }
                    loaded = true
                }
            }
            if case .text(let text) = outcome { return text }
            return ""
        }
    }

    private func pcm(seconds: Double) -> Data { Data(count: Int(seconds * 16_000) * 2) }

    func test_first_take_after_cold_launch_waits_visibly_then_pastes_the_kept_audio() async {
        let gate = Gate()
        let decoder = PreparingDecoder(loaded: false, gate: gate)
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 2))
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: "en")
        var preparingShown = 0
        session.onPreparingModel = { preparingShown += 1 }

        async let result = session.run()
        await Task.yield()
        // Speech while the model loads: no partial waits for it.
        audio.emit(pcm(seconds: 1))
        audio.emit(pcm(seconds: 1))
        await eventually("model load requested when the take starts") { await decoder.prepareCalls == 1 }
        await session.stop()
        audio.stop()
        await eventually("preparing shown after release") { preparingShown == 1 }
        await gate.open()
        let outcome = await result

        XCTAssertEqual(outcome, .transcript("hello from this mac"))
        let decodes = await decoder.decodes
        XCTAssertEqual(decodes, 1, "only the final pass; partials skip an unloaded model")
    }

    func test_take_whose_model_is_still_preparing_ends_with_its_reason_not_silence() async {
        let decoder = PreparingDecoder(loaded: false, gate: Gate(), outcome: .stillPreparing)
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 2))
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)
        var preparingShown = false
        session.onPreparingModel = { preparingShown = true }

        async let result = session.run()
        await Task.yield()
        await session.stop()
        audio.stop()
        let outcome = await result

        XCTAssertEqual(outcome, .failed(.localModelPreparing))
        XCTAssertTrue(preparingShown)
        XCTAssertEqual(session.capturedAudioPCM16().count, 64_000, "the audio stays for Retry")
    }

    func test_take_whose_model_failed_to_load_ends_with_that_reason() async {
        let decoder = PreparingDecoder(loaded: false, gate: Gate(), outcome: .loadFailed)
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 2))
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)

        async let result = session.run()
        await Task.yield()
        await session.stop()
        audio.stop()
        let outcome = await result

        XCTAssertEqual(outcome, .failed(.localModelFailed))
    }

    func test_warm_model_take_never_shows_preparing() async {
        let decoder = PreparingDecoder(loaded: true, gate: Gate())
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 2))
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)
        var preparingShown = false
        session.onPreparingModel = { preparingShown = true }

        async let result = session.run()
        await Task.yield()
        await session.stop()
        audio.stop()
        let outcome = await result

        XCTAssertEqual(outcome, .transcript("hello from this mac"))
        XCTAssertFalse(preparingShown)
    }

    func test_escape_while_the_model_prepares_cancels_without_decoding() async {
        let decoder = PreparingDecoder(loaded: false, gate: Gate())
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 2))
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)

        async let result = session.run()
        await Task.yield()
        await session.cancel()
        let outcome = await result

        XCTAssertEqual(outcome, .cancelled)
        let decodes = await decoder.decodes
        XCTAssertEqual(decodes, 0)
    }

    func test_cancel_during_the_preparing_wait_ends_the_take_at_once() async {
        let gate = Gate()
        let decoder = PreparingDecoder(loaded: false, gate: gate)
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 2))
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)
        var preparingShown = false
        session.onPreparingModel = { preparingShown = true }

        async let result = session.run()
        await Task.yield()
        await session.stop()
        audio.stop()
        await eventually("waiting for the model") { preparingShown }
        await session.cancel()
        let outcome = await result

        XCTAssertEqual(outcome, .cancelled, "quit or sleep does not wait for the model")
        await gate.open()
    }

    // MARK: - Delivery: a take never ends silently

    private final class SinkRecorder {
        var phases: [AppPhase] = []
        var reasons: [String] = []
        var retained: Data?
        var noted: [Error] = []
        var batchCalls = 0

        func sink() -> AppDelegate.DropBatchRecoverySink {
            AppDelegate.DropBatchRecoverySink(
                setPhase: { [weak self] in self?.phases.append($0) },
                deliver: { _ in true },
                retainForRetry: { [weak self] in self?.retained = $0 },
                clearPendingRetry: {},
                failTelemetry: { [weak self] in self?.reasons.append($0) },
                noteBatchFailure: { [weak self] in self?.noted.append($0) }
            )
        }
    }

    func test_still_preparing_take_skips_the_batch_rung_and_offers_retry_with_its_reason() async {
        let recorder = SinkRecorder()
        let audio = Data(count: 64_000)
        await AppDelegate.resolveDelivery(
            result: .failed(.localModelPreparing), capturedPCM: audio, lastPartial: "",
            hasBatchTranscriber: true,
            transcribe: { _ in recorder.batchCalls += 1; return "unused" },
            sink: recorder.sink()
        )

        XCTAssertEqual(recorder.batchCalls, 0, "the same model is not run again at once")
        XCTAssertEqual(recorder.phases.last, .deliveryFailed)
        XCTAssertEqual(recorder.retained, audio)
        XCTAssertEqual(recorder.reasons, ["local_model_preparing"])
        let failure = recorder.noted.first.flatMap(ProviderFailure.init)
        XCTAssertEqual(failure, .localModelPreparing)
        XCTAssertEqual(failure?.dropMessage(provider: "This Mac"), "Local model still preparing, retry soon")
        XCTAssertEqual(failure?.needsSettings, false)
    }

    func test_model_that_did_not_load_offers_retry_and_points_to_settings() async {
        let recorder = SinkRecorder()
        await AppDelegate.resolveDelivery(
            result: .failed(.localModelFailed), capturedPCM: Data(count: 64_000), lastPartial: "",
            hasBatchTranscriber: true,
            transcribe: { _ in recorder.batchCalls += 1; return "unused" },
            sink: recorder.sink()
        )

        XCTAssertEqual(recorder.batchCalls, 0)
        XCTAssertEqual(recorder.phases.last, .deliveryFailed)
        XCTAssertEqual(recorder.reasons, ["local_model_failed"])
        let failure = recorder.noted.first.flatMap(ProviderFailure.init)
        XCTAssertEqual(failure, .localModelFailed)
        XCTAssertEqual(failure?.dropMessage(provider: "This Mac"), "Local model didn't load")
        XCTAssertEqual(failure?.needsSettings, true)
    }

    func test_retry_while_the_model_still_prepares_names_the_reason() async {
        let decoder = PreparingDecoder(loaded: false, gate: Gate(), outcome: .stillPreparing)
        let batch = OnDeviceBatchTranscriber(readiness: .ready, decoder: decoder)
        do {
            _ = try await batch.transcribe(audio: Data(count: 64_000), language: nil)
            XCTFail("expected the model's reason")
        } catch {
            XCTAssertEqual(ProviderFailure(error), .localModelPreparing)
        }
    }

    func test_batch_waits_less_than_the_recovery_deadline() {
        XCTAssertLessThan(ParakeetSpeechDecoder.batchPreparationWait, .seconds(30),
                          "the model's reason must arrive before BatchRecoveryDeadline")
    }

    // MARK: - Island

    func test_island_says_preparing_after_release_instead_of_listening() {
        let flow = IslandAgentFlowStore(responseStore: AskResponseStore(), dropProviderBrand: { nil })
        flow.dropPhaseChanged(.recording)
        flow.dropLocalModelPreparing()
        XCTAssertEqual(flow.wing, .recording(transcript: ""), "while held, the take is listening")

        flow.dropPhaseChanged(.transcribing)
        flow.dropLocalModelPreparing()
        XCTAssertEqual(flow.wing, .acting)
        XCTAssertEqual(flow.activityLabel, "preparing local model…")

        flow.dropPhaseChanged(.deliveryFailed, failureMessage: "Local model still preparing, retry soon")
        XCTAssertEqual(flow.wing, .deliveryFailed(message: "Local model still preparing, retry soon"))

        flow.dropPhaseChanged(.transcribing)
        XCTAssertEqual(flow.wing, .recording(transcript: ""), "the next take starts without the label")
    }

    // MARK: - Warm-up: launch and route switches

    private func routingStore() -> AIRoutingStore {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AIRoutingStore(defaults: defaults)
    }

    func test_launch_prepares_only_when_a_feature_runs_on_this_mac() async {
        let routing = routingStore()
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v3"), for: .dropFast)
        let prepares = Counter()
        OnDeviceSpeechWarmup(routing: routing, readiness: .ready, prepare: { prepares.increment() }).start()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(prepares.count, 0, "a provider route loads nothing on this Mac")

        let localRouting = routingStore()
        localRouting.setRoute(FeatureRoute(account: .thisMac, model: ModelRegistry.onDeviceSpeechModel), for: .dropFast)
        let localPrepares = Counter()
        OnDeviceSpeechWarmup(routing: localRouting, readiness: .ready, prepare: { localPrepares.increment() }).start()
        await eventually("launch warm-up") { localPrepares.count == 1 }

        let missing = Counter()
        OnDeviceSpeechWarmup(routing: localRouting, readiness: .unavailable, prepare: { missing.increment() }).start()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(missing.count, 0, "no files, no load, no download")
    }

    func test_switching_between_a_provider_and_this_mac_prepares_on_each_switch_to_this_mac() async {
        let routing = routingStore()
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v3"), for: .dropFast)
        let prepares = Counter()
        let warmup = OnDeviceSpeechWarmup(routing: routing, readiness: .ready, prepare: { prepares.increment() })
        warmup.start()

        routing.setRoute(FeatureRoute(account: .thisMac, model: ModelRegistry.onDeviceSpeechModel), for: .dropFast)
        await eventually("switch to this Mac prepares") { prepares.count == 1 }
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v3"), for: .dropFast)
        routing.setRoute(FeatureRoute(account: .thisMac, model: ModelRegistry.onDeviceSpeechModel), for: .dropFast)
        await eventually("switching back prepares again") { prepares.count == 2 }
        withExtendedLifetime(warmup) {}
    }

    func test_provider_take_during_a_preparation_does_not_wait_for_the_model() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("soniox-key", account: XCTUnwrap(ProviderAccount.soniox.keychainAccount(in: routing)))
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v3"), for: .dropFast)
        struct AdapterReached: Error {}
        var onDeviceSessions = 0
        let factory = TranscriptionSessionFactory(
            resolver: FeatureRouteResolver(routing: routing, keys: keys, onDevice: .ready),
            vocab: VocabularyCache(defaults: UserDefaults(suiteName: "vocab.\(UUID().uuidString)")!),
            makeAdapter: { _ in throw AdapterReached() },
            makeOnDeviceSession: { language in
                onDeviceSessions += 1
                return OnDeviceTranscriptionSession(
                    audioEngine: CapturingStubAudioSource(captured: Data()),
                    decoder: PreparingDecoder(loaded: false, gate: Gate()), language: language)
            }
        )

        XCTAssertThrowsError(try factory.make(feature: .dropFast, language: "en")) {
            XCTAssertTrue($0 is AdapterReached, "the provider's own adapter is built")
        }
        XCTAssertEqual(onDeviceSessions, 0, "a provider route never joins the local model")
    }
}
