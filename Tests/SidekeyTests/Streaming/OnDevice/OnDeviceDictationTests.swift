import XCTest
@testable import Sidekey

/// Dictation on this Mac, from the user's side: download the model, pick it
/// for Drop, dictate without a key or a network, lose the model and see the
/// feature go Not set instead of moving to a provider. No Core ML model is
/// loaded: the decoder is a fake, routes live in an isolated `UserDefaults`
/// suite and keys in an in-memory Keychain.
@MainActor
final class OnDeviceDictationTests: XCTestCase {
    /// Records what it was asked to decode and answers from a script.
    private actor FakeDecoder: OnDeviceSpeechDecoding {
        private(set) var calls: [(samples: Int, language: String?)] = []
        private let answer: @Sendable (Int) throws -> String

        init(answer: @escaping @Sendable (Int) throws -> String = { _ in "hello world" }) {
            self.answer = answer
        }

        func decode(samples: [Float], language: String?) async throws -> String {
            calls.append((samples.count, language))
            return try answer(samples.count)
        }
    }

    private struct DecodeFailure: Error {}

    private struct Env {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
    }

    private func makeEnv() -> Env {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let box = InMemoryTokenStore.Box()
        return Env(
            routing: AIRoutingStore(defaults: defaults),
            keys: ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        )
    }

    private let model = ModelRegistry.onDeviceSpeechModel

    private func pcm(seconds: Double) -> Data {
        Data(count: Int(seconds * 16_000) * 2)
    }

    // MARK: - Route

    func test_route_runs_without_any_key_once_the_model_is_downloaded() throws {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .dropFast)
        let resolver = FeatureRouteResolver(routing: env.routing, keys: env.keys, onDevice: .ready)

        let resolved = try resolver.resolve(.dropFast)

        XCTAssertEqual(resolved.account, .thisMac)
        XCTAssertEqual(resolved.model, model)
        XCTAssertNil(resolved.apiKey)
        XCTAssertNil(resolved.server)
    }

    func test_route_without_the_model_fails_closed_even_with_a_provider_key_stored() throws {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .dropFast)
        try env.keys.save("soniox-key", account: XCTUnwrap(ProviderAccount.soniox.keychainAccount(in: env.routing)))
        let resolver = FeatureRouteResolver(routing: env.routing, keys: env.keys, onDevice: .unavailable)

        XCTAssertThrowsError(try resolver.resolve(.dropFast)) {
            XCTAssertEqual($0 as? FeatureRouteError, .missingKey(.dropFast))
        }
    }

    func test_route_rejects_an_unknown_model_and_features_it_cannot_serve() {
        let env = makeEnv()
        let resolver = FeatureRouteResolver(routing: env.routing, keys: env.keys, onDevice: .ready)

        XCTAssertThrowsError(try resolver.resolve(FeatureRoute(account: .thisMac, model: "whisper-large"), for: .dropFast)) {
            XCTAssertEqual($0 as? FeatureRouteError, .notSet(.dropFast))
        }
        for feature in [AIFeature.meetings, .subtitlesAudio, .agent, .dropSmartCleanup] {
            XCTAssertNil(feature.modelUse(on: .onDevice), "\(feature)")
            XCTAssertThrowsError(try resolver.resolve(FeatureRoute(account: .thisMac, model: model), for: feature)) {
                XCTAssertEqual($0 as? FeatureRouteError, .notSet(feature))
            }
        }
    }

    func test_microphone_features_are_offered_the_model() {
        for feature in [AIFeature.dropFast, .dropSmart, .agentVoice, .voiceSearch] {
            XCTAssertEqual(feature.modelUse(on: .onDevice), .realtimeSTT, "\(feature)")
            XCTAssertEqual(ModelRegistry.recommended(for: feature, kind: .onDevice), model)
            XCTAssertTrue(ModelRegistry.isVerified(model, kind: .onDevice, use: .realtimeSTT))
        }
        XCTAssertNil(ModelRegistry.recommended(for: .meetings, kind: .onDevice))
    }

    func test_account_survives_storage_and_has_no_keychain_account() {
        let env = makeEnv()
        XCTAssertEqual(ProviderAccount(storageID: "thisMac"), .thisMac)
        XCTAssertEqual(ProviderAccount.thisMac.storageID, "thisMac")
        XCTAssertNil(ProviderAccount.thisMac.keychainAccount(in: env.routing))
    }

    // MARK: - Settings

    /// The model's presence, flipped by the test like a download or a removal.
    private final class ModelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var present = false
        func set(_ value: Bool) { lock.withLock { present = value } }
        var readiness: OnDeviceSpeechReadiness { .init { [self] in lock.withLock { present } } }
    }

    private func makeSettings(_ flag: ModelFlag) -> (vm: APIAndModelsViewModel, env: Env) {
        let env = makeEnv()
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let vm = APIAndModelsViewModel(
            routing: env.routing, keys: env.keys,
            catalogs: ModelCatalogStore(fileURL: file), checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, inputLanguage: { nil },
            onDevice: flag.readiness
        )
        return (vm, env)
    }

    func test_fresh_user_downloads_the_model_and_is_offered_it_for_every_microphone_feature() {
        let flag = ModelFlag()
        let (vm, env) = makeSettings(flag)
        XCTAssertTrue(vm.chips.isEmpty)
        XCTAssertTrue(vm.sections(for: .dropFast).isEmpty, "nothing to pick before the download")
        XCTAssertFalse(vm.addableKinds.contains(.onDevice), "it is not a key to add")

        flag.set(true)
        vm.onDeviceModelChanged()

        XCTAssertEqual(vm.chips.map(\.account), [.thisMac])
        XCTAssertEqual(vm.chips.first?.statusText, "Model downloaded")
        XCTAssertEqual(vm.proposal?.title, "Use On this Mac for")
        XCTAssertEqual(vm.proposal?.items.map(\.feature), [.dropFast, .dropSmart, .agentVoice, .voiceSearch])
        XCTAssertNil(env.routing.route(for: .dropFast), "offered, not assigned")

        vm.applyProposal(selected: [.dropFast])

        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .thisMac, model: model))
        XCTAssertNil(env.routing.route(for: .dropSmart))
        XCTAssertEqual(vm.rows.first { $0.feature == .dropFast }?.status, .ok)
        XCTAssertEqual(vm.rows.first { $0.feature == .dropFast }?.selectionLabel, "On this Mac · \(model)")
    }

    func test_download_never_moves_a_feature_that_already_has_a_provider() throws {
        let flag = ModelFlag()
        let (vm, env) = makeSettings(flag)
        let soniox = FeatureRoute(account: .soniox, model: "stt-rt-v5")
        env.routing.setRoute(soniox, for: .dropFast)
        try env.keys.save("soniox-key", account: XCTUnwrap(ProviderAccount.soniox.keychainAccount(in: env.routing)))

        flag.set(true)
        vm.onDeviceModelChanged()

        XCTAssertEqual(env.routing.route(for: .dropFast), soniox)
        XCTAssertEqual(vm.proposal?.items.map(\.feature), [.dropSmart, .agentVoice, .voiceSearch])
        let section = vm.sections(for: .dropFast).first { $0.account == .thisMac }
        XCTAssertEqual(section?.title, "On this Mac")
        XCTAssertEqual(section?.options.map(\.model), [model])
        XCTAssertEqual(section?.options.first?.state, .verified)
        XCTAssertNil(vm.sections(for: .meetings).first { $0.account == .thisMac }, "not offered to Meetings")
    }

    func test_download_finishing_does_not_replace_another_providers_open_offer() {
        let flag = ModelFlag()
        let (vm, _) = makeSettings(flag)
        vm.proposeSetup(for: .soniox)
        XCTAssertEqual(vm.proposal?.title, "Use Soniox for")

        flag.set(true)
        vm.onDeviceModelChanged()

        XCTAssertEqual(vm.proposal?.title, "Use Soniox for")
        XCTAssertEqual(vm.proposal?.items.map(\.account), Array(repeating: .soniox, count: vm.proposal?.items.count ?? 0))
        XCTAssertEqual(vm.chips.map(\.account), [.thisMac], "the model is still listed")
    }

    func test_user_picks_the_model_in_the_picker_without_a_probe() async {
        let flag = ModelFlag()
        flag.set(true)
        let (vm, env) = makeSettings(flag)

        let picked = await vm.select(model: model, account: .thisMac, for: .dropFast)

        XCTAssertTrue(picked)
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .thisMac, model: model))
    }

    func test_removing_the_model_unsets_its_features_and_moves_nothing_to_a_provider() throws {
        let flag = ModelFlag()
        flag.set(true)
        let (vm, env) = makeSettings(flag)
        try env.keys.save("soniox-key", account: XCTUnwrap(ProviderAccount.soniox.keychainAccount(in: env.routing)))
        env.routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .dropFast)
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .agentVoice)

        flag.set(false)
        vm.onDeviceModelChanged()

        XCTAssertNil(env.routing.route(for: .dropFast), "Not set, never switched to Soniox")
        XCTAssertEqual(env.routing.route(for: .agentVoice)?.account, .soniox)
        XCTAssertEqual(vm.chips.map(\.account), [.soniox])
        XCTAssertEqual(vm.rows.first { $0.feature == .dropFast }?.status, .notSet)
    }

    func test_model_files_lost_outside_the_app_show_the_feature_as_not_set() {
        let flag = ModelFlag()
        flag.set(true)
        let (vm, env) = makeSettings(flag)
        env.routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .dropFast)

        flag.set(false)
        let resolver = ModelStatusResolver(
            routing: env.routing, keys: env.keys, catalogs: ModelCatalogStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            checks: ModelCheckStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            keyStatuses: KeyStatusStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            onDevice: flag.readiness
        )

        XCTAssertEqual(resolver.status(for: .dropFast), .notSet)
        XCTAssertNotNil(env.routing.route(for: .dropFast), "the choice is kept for when the model returns")
        _ = vm
    }

    // MARK: - Session factory

    func test_factory_builds_the_on_device_session_and_no_provider_adapter() throws {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .dropFast)
        var adapters = 0
        var languages: [String?] = []
        let factory = TranscriptionSessionFactory(
            resolver: FeatureRouteResolver(routing: env.routing, keys: env.keys, onDevice: .ready),
            vocab: VocabularyCache(defaults: UserDefaults(suiteName: "vocab.\(UUID().uuidString)")!),
            makeAdapter: { route in
                adapters += 1
                return try RealtimeAdapterFactory.make(route)
            },
            makeOnDeviceSession: { language in
                languages.append(language)
                return OnDeviceTranscriptionSession(
                    audioEngine: CapturingStubAudioSource(captured: Data()), decoder: FakeDecoder(), language: language
                )
            }
        )

        let session = try factory.make(feature: .dropFast, language: "ru", resilient: true)

        XCTAssertTrue(session is OnDeviceTranscriptionSession)
        XCTAssertEqual(adapters, 0, "nothing may be built toward a provider")
        XCTAssertEqual(languages, ["ru"])
    }

    func test_factory_without_the_model_opens_nothing() {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .dropFast)
        var built = 0
        let factory = TranscriptionSessionFactory(
            resolver: FeatureRouteResolver(routing: env.routing, keys: env.keys, onDevice: .unavailable),
            vocab: VocabularyCache(defaults: UserDefaults(suiteName: "vocab.\(UUID().uuidString)")!),
            makeAdapter: { built += 1; return try RealtimeAdapterFactory.make($0) },
            makeOnDeviceSession: { _ in built += 1; return OnDeviceTranscriptionSession(decoder: FakeDecoder(), language: nil) }
        )

        XCTAssertThrowsError(try factory.make(feature: .dropFast, language: nil)) {
            XCTAssertEqual($0 as? FeatureRouteError, .missingKey(.dropFast))
        }
        XCTAssertEqual(built, 0)
    }

    func test_realtime_adapter_factory_never_builds_a_socket_for_this_mac() {
        let route = ResolvedRoute(feature: .dropFast, account: .thisMac, model: model, apiKey: nil, server: nil)
        XCTAssertThrowsError(try RealtimeAdapterFactory.make(route))
    }

    // MARK: - Session

    func test_take_is_decoded_whole_on_stop_and_pasted() async {
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 2))
        let decoder = FakeDecoder { _ in "open the pull request" }
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: "en")
        var live: [String] = []
        session.onTranscriptUpdate = { live.append($0) }

        async let result = session.run()
        await Task.yield()
        await session.stop()
        audio.stop()
        let outcome = await result

        XCTAssertEqual(outcome, .transcript("open the pull request"))
        XCTAssertEqual(live.last, "open the pull request")
        let calls = await decoder.calls
        XCTAssertEqual(calls.last?.samples, 32_000, "the final pass covers the whole take")
        XCTAssertEqual(calls.last?.language, "en")
        XCTAssertEqual(session.capturedAudioPCM16().count, 64_000, "audio stays available for Retry")
    }

    func test_silence_or_a_too_short_take_pastes_nothing_and_is_not_a_failure() async {
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 0.1))
        let decoder = FakeDecoder()
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)

        async let result = session.run()
        await Task.yield()
        await session.stop()
        audio.stop()
        let outcome = await result

        XCTAssertEqual(outcome, .transcript(""))
        let calls = await decoder.calls
        XCTAssertTrue(calls.isEmpty, "the model is not asked about audio it would reject")
    }

    func test_decode_failure_fails_the_take_so_delivery_can_retry_from_kept_audio() async {
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 1))
        let session = OnDeviceTranscriptionSession(
            audioEngine: audio, decoder: FakeDecoder { _ in throw DecodeFailure() }, language: nil
        )

        async let result = session.run()
        await Task.yield()
        await session.stop()
        audio.stop()
        let outcome = await result

        XCTAssertEqual(outcome, .failed(.transportFailed))
        XCTAssertEqual(session.capturedAudioPCM16().count, 32_000)
    }

    func test_escape_cancels_without_decoding() async {
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 1))
        let decoder = FakeDecoder()
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)

        async let result = session.run()
        await Task.yield()
        await session.cancel()
        let outcome = await result

        XCTAssertEqual(outcome, .cancelled)
        let calls = await decoder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func test_dead_microphone_fails_the_take() async {
        let audio = CapturingStubAudioSource(captured: Data())
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: FakeDecoder(), language: nil)

        async let result = session.run()
        await Task.yield()
        audio.emitFailure(.invalidInputFormat)
        let outcome = await result

        XCTAssertEqual(outcome, .failed(.audioEngineFailed))
    }

    func test_live_text_redecodes_a_bounded_window_of_a_long_take() async {
        // 20 s captured: longer than the 14 s window a partial may decode.
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 20))
        let decoder = FakeDecoder { "decoded \($0)" }
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)
        let partial = expectation(description: "a live partial")
        partial.assertForOverFulfill = false
        session.onTranscriptUpdate = { _ in partial.fulfill() }

        async let result = session.run()
        await Task.yield()
        audio.emit(Data(count: 25_600))
        await fulfillment(of: [partial], timeout: 5)
        await session.stop()
        audio.stop()
        _ = await result

        let calls = await decoder.calls
        XCTAssertEqual(calls.first?.samples, OnDeviceTranscriptionSession.partialWindowSamples)
        XCTAssertEqual(calls.last?.samples, 320_000, "the final pass is the whole take")
    }

    /// Answers each decode with the next line of a script.
    private actor ScriptedDecoder: OnDeviceSpeechDecoding {
        private var lines: [String]
        private(set) var count = 0
        init(_ lines: [String]) { self.lines = lines }
        func decode(samples: [Float], language: String?) async throws -> String {
            count += 1
            return lines.isEmpty ? "" : lines.removeFirst()
        }
    }

    private func waitForDecodes(_ expected: Int, _ decoder: ScriptedDecoder) async {
        for _ in 0..<500 {
            if await decoder.count >= expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("expected \(expected) decodes")
    }

    func test_take_longer_than_the_engine_buffer_is_pasted_whole() async {
        // The engine's turn buffer stopped early (it is capped); the stream did not.
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 1))
        let decoder = FakeDecoder { "decoded \($0)" }
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)

        async let result = session.run()
        await Task.yield()
        for _ in 0..<30 { audio.emit(pcm(seconds: 0.1)) }
        await session.stop()
        audio.stop()
        let outcome = await result

        XCTAssertEqual(outcome, .transcript("decoded 48000"), "all 3 s of the stream, not the 1 s the engine kept")
        XCTAssertEqual(session.capturedAudioPCM16().count, 96_000, "Retry gets the whole take too")
    }

    func test_live_text_holds_still_while_only_the_window_scrolls() async {
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 1))
        let spoken = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
        let decoder = ScriptedDecoder([
            spoken,
            "gamma delta epsilon zeta eta theta iota kappa",  // a pause: only the head fell off
            "delta epsilon zeta eta theta iota kappa lambda",  // new speech
            "final text",
        ])
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)
        var live: [String] = []
        session.onTranscriptUpdate = { live.append($0) }

        async let result = session.run()
        await Task.yield()
        for tick in 1...3 {
            audio.emit(Data(count: 25_600))
            await waitForDecodes(tick, decoder)
        }
        await Task.yield()
        let beforeStop = live
        await session.stop()
        audio.stop()
        _ = await result

        XCTAssertEqual(beforeStop, [spoken, "delta epsilon zeta eta theta iota kappa lambda"],
                       "a scrolled window is not new text: Drop auto-stop can see the pause")
    }

    func test_no_partial_is_decoded_after_stop() async {
        let audio = CapturingStubAudioSource(captured: pcm(seconds: 1))
        let decoder = ScriptedDecoder(["final text"])
        let session = OnDeviceTranscriptionSession(audioEngine: audio, decoder: decoder, language: nil)

        async let result = session.run()
        await Task.yield()
        await session.stop()
        // The word tail still arrives after the key is released.
        audio.emit(Data(count: 25_600))
        audio.emit(Data(count: 25_600))
        audio.stop()
        let outcome = await result

        XCTAssertEqual(outcome, .transcript("final text"))
        let decodes = await decoder.count
        XCTAssertEqual(decodes, 1, "only the final pass")
    }

    // MARK: - Script filter

    func test_cyrillic_languages_keep_latin_terms_and_latin_languages_keep_their_filter() {
        XCTAssertNil(ParakeetSpeechDecoder.scriptFilter(for: nil))
        XCTAssertNil(ParakeetSpeechDecoder.scriptFilter(for: "ru"), "a Russian take may contain GitHub")
        XCTAssertNil(ParakeetSpeechDecoder.scriptFilter(for: "uk-UA"))
        XCTAssertNil(ParakeetSpeechDecoder.scriptFilter(for: "ja"), "a language the model has no filter for")
        XCTAssertEqual(ParakeetSpeechDecoder.scriptFilter(for: "en-US")?.rawValue, "en")
        XCTAssertEqual(ParakeetSpeechDecoder.scriptFilter(for: "pl")?.rawValue, "pl")
    }

    // MARK: - Batch (recovery, Retry, agent batch voice)

    func test_batch_take_of_an_on_device_route_stays_on_this_mac() async throws {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .agentVoice)
        let decoder = FakeDecoder { _ in "recovered text" }
        let transcriber = ProviderBatchTranscriber.forFeature(
            .agentVoice,
            resolver: FeatureRouteResolver(routing: env.routing, keys: env.keys, onDevice: .ready),
            session: Self.refusingSession(),
            onDevice: OnDeviceBatchTranscriber(readiness: .ready, decoder: decoder)
        )

        let available = await transcriber.isAvailable()
        let text = try await transcriber.transcribe(audio: pcm(seconds: 1), language: "ru")

        XCTAssertTrue(available)
        XCTAssertEqual(text, "recovered text")
        let calls = await decoder.calls
        XCTAssertEqual(calls.map(\.samples), [16_000])
    }

    func test_batch_take_latched_on_this_mac_ignores_a_later_switch_to_a_provider() async throws {
        let env = makeEnv()
        let take = DropTake()
        take.begin(mode: .fast, route: FeatureRoute(account: .thisMac, model: model))
        // The user switches Drop Fast to Soniox while the take is being recovered.
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        try env.keys.save("soniox-key", account: XCTUnwrap(ProviderAccount.soniox.keychainAccount(in: env.routing)))
        let transcriber = ProviderBatchTranscriber.forDrop(
            take: take,
            resolver: FeatureRouteResolver(routing: env.routing, keys: env.keys, onDevice: .ready),
            session: Self.refusingSession(),
            onDevice: OnDeviceBatchTranscriber(readiness: .ready, decoder: FakeDecoder { _ in "stayed local" })
        )

        let text = try await transcriber.transcribe(audio: pcm(seconds: 1), language: nil)

        XCTAssertEqual(text, "stayed local")
    }

    func test_batch_without_the_model_is_unavailable_and_sends_nothing() async {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .agentVoice)
        let transcriber = ProviderBatchTranscriber.forFeature(
            .agentVoice,
            resolver: FeatureRouteResolver(routing: env.routing, keys: env.keys, onDevice: .unavailable),
            session: Self.refusingSession()
        )

        let available = await transcriber.isAvailable()
        XCTAssertFalse(available)
        do {
            _ = try await transcriber.transcribe(audio: pcm(seconds: 1), language: nil)
            XCTFail("expected BatchTranscriptionUnavailable")
        } catch {
            XCTAssertTrue(error is BatchTranscriptionUnavailable)
        }
    }

    func test_batch_reads_a_wav_file_and_treats_a_blip_as_silence() async throws {
        let decoder = FakeDecoder()
        let transcriber = OnDeviceBatchTranscriber(readiness: .ready, decoder: decoder)
        var wav = Data("RIFF".utf8) + Data(count: 4) + Data("WAVE".utf8)
        wav += Data("fmt ".utf8) + Data([16, 0, 0, 0]) + Data(count: 16)
        let body = pcm(seconds: 1)
        var size = UInt32(body.count).littleEndian
        wav += Data("data".utf8) + Data(bytes: &size, count: 4) + body

        let text = try await transcriber.transcribe(audio: wav, language: nil)
        let blip = try await transcriber.transcribe(audio: pcm(seconds: 0.1), language: nil)

        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(blip, "")
        let calls = await decoder.calls
        XCTAssertEqual(calls.map(\.samples), [16_000], "the header is not decoded as audio")
    }

    /// A URL session whose every request fails the test: on-device paths must
    /// not make one.
    private static func refusingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingProtocol.self]
        return URLSession(configuration: configuration)
    }

    private final class RefusingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            XCTFail("an on-device take made a network request")
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }
}
