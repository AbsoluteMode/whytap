import XCTest
@testable import Sidekey

/// On this Mac in every place the app transcribes, from the user's side: pick
/// the model for Meetings and Subtitles audio, keep the choice, run a meeting
/// and live subtitles with no network, lose the model, go back to a provider.
/// No Core ML model is loaded: the decoder is a fake, routes live in an
/// isolated `UserDefaults` suite and keys in an in-memory Keychain.
@MainActor
final class OnDeviceEverywhereTests: XCTestCase {
    /// Answers "phrase 1", "phrase 2", … in call order; records sample counts.
    private actor NumberingDecoder: OnDeviceSpeechDecoding {
        private(set) var calls: [Int] = []
        private let delay: Duration
        private let fails: Bool
        init(delay: Duration = .zero, fails: Bool = false) { self.delay = delay; self.fails = fails }
        func decode(samples: [Float], language: String?) async throws -> String {
            calls.append(samples.count)
            if delay > .zero { try await Task.sleep(for: delay) }
            if fails { throw DecodeFailure() }
            return "phrase \(calls.count)"
        }
    }

    private struct DecodeFailure: Error {}

    private final class ModelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var present = false
        func set(_ value: Bool) { lock.withLock { present = value } }
        var readiness: OnDeviceSpeechReadiness { .init { [self] in lock.withLock { present } } }
    }

    private let model = ModelRegistry.onDeviceSpeechModel

    private func makeStores() -> (routing: AIRoutingStore, keys: ProviderKeyStore, defaults: UserDefaults) {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let box = InMemoryTokenStore.Box()
        return (AIRoutingStore(defaults: defaults), ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) }), defaults)
    }

    // MARK: - Audio

    /// A 440 Hz tone well above the speech level.
    private static func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.3 }
    }

    private static func silence(seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * 16_000))
    }

    private static func pcm16(_ samples: [Float]) -> Data { SubtitleSegmenter.pcm16(samples) }

    // MARK: - Which features offer the model

    func test_every_speech_feature_offers_the_model_and_no_text_feature_does() {
        for feature in [AIFeature.dropFast, .dropSmart, .meetings, .agentVoice, .voiceSearch, .subtitlesAudio] {
            XCTAssertEqual(feature.modelUse(on: .onDevice), .realtimeSTT, "\(feature)")
            XCTAssertEqual(ModelRegistry.recommended(for: feature, kind: .onDevice), model, "\(feature)")
        }
        for feature in [AIFeature.dropSmartCleanup, .meetingNotes, .agent, .translation, .subtitlesTranslation] {
            XCTAssertNil(feature.modelUse(on: .onDevice), "\(feature) is text, not speech")
        }
    }

    private func makeSettings(_ flag: ModelFlag) -> (vm: APIAndModelsViewModel, routing: AIRoutingStore, keys: ProviderKeyStore, defaults: UserDefaults) {
        let (routing, keys, defaults) = makeStores()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let vm = APIAndModelsViewModel(
            routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: file), checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, inputLanguage: { nil },
            onDevice: flag.readiness
        )
        return (vm, routing, keys, defaults)
    }

    func test_user_picks_this_mac_for_meetings_and_subtitles_and_the_choice_survives_a_relaunch() async {
        let flag = ModelFlag()
        flag.set(true)
        let (vm, routing, _, defaults) = makeSettings(flag)

        for feature in [AIFeature.meetings, .subtitlesAudio] {
            let section = vm.sections(for: feature).first { $0.account == .thisMac }
            XCTAssertEqual(section?.title, "On this Mac", "\(feature)")
            XCTAssertEqual(section?.options.map(\.model), [model], "\(feature)")
            let picked = await vm.select(model: model, account: .thisMac, for: feature)
            XCTAssertTrue(picked, "\(feature)")
            XCTAssertEqual(vm.rows.first { $0.feature == feature }?.status, .ok, "\(feature)")
            XCTAssertEqual(vm.rows.first { $0.feature == feature }?.selectionLabel, "On this Mac · \(model)")
        }
        XCTAssertEqual(
            vm.sections(for: .meetings).first { $0.account == .thisMac }?.options.first?.hint,
            "without speakers", "Meetings says what it gives up"
        )

        // A relaunch reads the same defaults afresh.
        let relaunched = AIRoutingStore(defaults: defaults)
        XCTAssertEqual(relaunched.route(for: .meetings), FeatureRoute(account: .thisMac, model: model))
        XCTAssertEqual(relaunched.route(for: .subtitlesAudio), FeatureRoute(account: .thisMac, model: model))
        _ = routing
    }

    func test_download_offers_the_model_to_meetings_and_subtitles_too() {
        let flag = ModelFlag()
        let (vm, routing, _, _) = makeSettings(flag)

        flag.set(true)
        vm.onDeviceModelChanged()

        XCTAssertEqual(vm.proposal?.items.map(\.feature),
                       [.dropFast, .dropSmart, .meetings, .agentVoice, .voiceSearch, .subtitlesAudio])
        XCTAssertNil(routing.route(for: .meetings), "offered, not assigned")
    }

    func test_removing_the_model_unsets_meetings_and_subtitles_and_switching_back_to_a_provider_works() throws {
        let flag = ModelFlag()
        flag.set(true)
        let (vm, routing, keys, _) = makeSettings(flag)
        routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .meetings)
        routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .subtitlesAudio)
        try keys.save("dg-key", account: XCTUnwrap(ProviderAccount.deepgram.keychainAccount(in: routing)))

        flag.set(false)
        vm.onDeviceModelChanged()

        XCTAssertNil(routing.route(for: .meetings), "Not set, never moved to Deepgram on its own")
        XCTAssertNil(routing.route(for: .subtitlesAudio))

        // The user chooses Deepgram again: the provider's adapter, with its key.
        routing.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .subtitlesAudio)
        let resolved = try FeatureRouteResolver(routing: routing, keys: keys, onDevice: flag.readiness).resolve(.subtitlesAudio)
        XCTAssertEqual(resolved.apiKey, "dg-key")
        XCTAssertTrue(try RealtimeAdapterFactory.make(resolved) is DeepgramBYOKAdapter)
    }

    // MARK: - Adapter factory

    func test_factory_builds_the_on_device_adapter_without_costs_for_subtitles_and_meetings() throws {
        let subtitles = ResolvedRoute(feature: .subtitlesAudio, account: .thisMac, model: model, apiKey: nil, server: nil)
        let meetings = ResolvedRoute(feature: .meetings, account: .thisMac, model: model, apiKey: nil, server: nil)

        let live = try XCTUnwrap(RealtimeAdapterFactory.makeMetered(subtitles) as? OnDeviceStreamingAdapter,
                                 "no Costs wrapper: nothing is paid")
        let recorded = try XCTUnwrap(RealtimeAdapterFactory.makeMetered(meetings) as? OnDeviceStreamingAdapter)
        XCTAssertTrue(live.livePartials, "subtitles show the phrase in progress")
        XCTAssertFalse(recorded.livePartials, "a meeting reads only finished phrases")
        XCTAssertEqual(live.feature, .subtitlesAudio)
    }

    func test_without_the_model_nothing_opens_and_the_route_is_not_set() async throws {
        let (routing, keys, _) = makeStores()
        routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .subtitlesAudio)
        try keys.save("soniox-key", account: XCTUnwrap(ProviderAccount.soniox.keychainAccount(in: routing)))

        XCTAssertThrowsError(
            try FeatureRouteResolver(routing: routing, keys: keys, onDevice: .unavailable).resolve(.subtitlesAudio)
        ) { XCTAssertEqual($0 as? FeatureRouteError, .missingKey(.subtitlesAudio)) }

        let adapter = OnDeviceStreamingAdapter(feature: .subtitlesAudio, livePartials: true,
                                               readiness: .unavailable, decoder: NumberingDecoder())
        do {
            _ = try await adapter.open(language: nil, terms: [])
            XCTFail("expected missingKey")
        } catch {
            XCTAssertEqual(error as? FeatureRouteError, .missingKey(.subtitlesAudio))
        }
    }

    // MARK: - Phrases

    func test_phrases_split_at_pauses_cover_the_whole_stream_and_stay_under_the_model_window() {
        var segmenter = OnDevicePhraseSegmenter()
        let input = Self.speech(seconds: 2) + Self.silence(seconds: 1) + Self.speech(seconds: 30) + Self.silence(seconds: 0.2)
        var phrases = segmenter.append(input)
        if let rest = segmenter.finish() { phrases.append(rest) }

        XCTAssertEqual(phrases.reduce(0) { $0 + $1.count }, input.count, "nothing is dropped")
        XCTAssertGreaterThanOrEqual(phrases.count, 4, "a pause and two length cuts")
        XCTAssertTrue(phrases.allSatisfy { $0.count <= OnDevicePhraseSegmenter.maxSamples })
        XCTAssertLessThan(phrases[0].count, Int(3.5 * 16_000), "the first phrase ends at the pause")
    }

    func test_session_decodes_phrases_in_order_and_skips_digital_silence() async {
        let decoder = NumberingDecoder()
        let session = OnDeviceStreamingSession(decoder: decoder, language: "en", livePartials: false)
        let audio = Self.speech(seconds: 1.5) + Self.silence(seconds: 2) + Self.speech(seconds: 1.5) + Self.silence(seconds: 5)

        await feed(session, audio)
        await session.endInput()
        let events = await collect(session)

        XCTAssertEqual(events, [.final("phrase 1"), .final("phrase 2"), .done("")])
        let calls = await decoder.calls
        XCTAssertEqual(calls.count, 2, "the trailing silence is never decoded")
    }

    func test_live_partials_show_the_phrase_in_progress_only_when_asked() async {
        for live in [true, false] {
            let decoder = NumberingDecoder()
            let session = OnDeviceStreamingSession(decoder: decoder, language: nil, livePartials: live)
            for second in 0..<4 {
                await feed(session, Self.speech(seconds: 1))
                if second < 3 { try? await Task.sleep(for: .milliseconds(30)) }
            }
            await session.endInput()
            let events = await collect(session)
            let partials = events.filter { if case .partial = $0 { return true }; return false }
            if live {
                XCTAssertFalse(partials.isEmpty, "subtitles get live text")
            } else {
                XCTAssertTrue(partials.isEmpty, "meetings spend no decode on live text")
            }
            XCTAssertEqual(events.last, .done(""))
        }
    }

    /// Speech-like audio: 100 ms of tone, then a 100 ms dip, like syllables.
    private static func syllables(seconds: Double) -> [Float] {
        let tone = speech(seconds: seconds)
        return tone.enumerated().map { ($0.offset / 1_600) % 2 == 0 ? $0.element : $0.element * 0.05 }
    }

    func test_a_pause_right_after_a_length_cut_still_ends_the_phrase_on_time() {
        var segmenter = OnDevicePhraseSegmenter()
        let input = Self.syllables(seconds: 10) + Self.silence(seconds: 0.02)
            + Self.syllables(seconds: 1.34) + Self.silence(seconds: 1)
        let phrases = segmenter.append(input)

        XCTAssertEqual(phrases.count, 2)
        XCTAssertEqual(phrases.first?.count, Int(10.02 * 16_000), "the length cut sits at the quietest frame")
        XCTAssertLessThan(phrases.last?.count ?? .max, Int(2.2 * 16_000),
                          "the quiet already seen before the cut counts toward the pause")
    }

    func test_a_short_tail_at_the_end_is_decoded_not_dropped() async {
        let decoder = NumberingDecoder()
        let session = OnDeviceStreamingSession(decoder: decoder, language: nil, livePartials: false)
        await feed(session, Self.speech(seconds: 0.2))
        await session.endInput()

        let events = await collect(session)

        XCTAssertEqual(events, [.final("phrase 1"), .done("")])
        let calls = await decoder.calls
        XCTAssertEqual(calls, [OnDeviceStreamingSession.minFinalSamples], "padded to the model's minimum")
    }

    private actor PreviewFailingDecoder: OnDeviceSpeechDecoding {
        private(set) var calls = 0
        func decode(samples: [Float], language: String?) async throws -> String {
            calls += 1
            if calls == 1 { throw DecodeFailure() }
            return "kept"
        }
    }

    func test_a_failed_live_preview_does_not_lose_the_phrase() async {
        let session = OnDeviceStreamingSession(decoder: PreviewFailingDecoder(), language: nil, livePartials: true)
        await feed(session, Self.speech(seconds: 1.2))
        await session.endInput()

        let events = await collect(session)

        XCTAssertEqual(events, [.final("kept"), .done("")])
    }

    func test_a_phrase_that_decodes_to_nothing_clears_the_live_text() async {
        let session = OnDeviceStreamingSession(decoder: EmptyDecoder(), language: nil, livePartials: true)
        await feed(session, Self.speech(seconds: 0.5) + Self.silence(seconds: 1))
        await session.endInput()

        let events = await collect(session)

        XCTAssertEqual(Array(events.suffix(2)), [.partial(""), .done("")], "the final clears the line")
        XCTAssertFalse(events.contains { if case .final = $0 { return true }; return false })
    }

    private struct EmptyDecoder: OnDeviceSpeechDecoding {
        func decode(samples: [Float], language: String?) async throws -> String { "" }
    }

    func test_decode_failure_ends_the_stream_with_an_error() async {
        let session = OnDeviceStreamingSession(decoder: NumberingDecoder(fails: true), language: nil, livePartials: false)
        await feed(session, Self.speech(seconds: 1) + Self.silence(seconds: 1))
        await session.endInput()
        let events = await collect(session)
        XCTAssertEqual(events.count, 1)
        guard case .error = events.first else { return XCTFail("expected .error, got \(events)") }
    }

    func test_a_fast_reader_waits_for_the_decoder_instead_of_piling_up_audio() async {
        let decoder = NumberingDecoder(delay: .milliseconds(20))
        let session = OnDeviceStreamingSession(decoder: decoder, language: nil, livePartials: false)
        var phrase: [Float] = []
        for _ in 0..<8 { phrase += Self.speech(seconds: 0.6) + Self.silence(seconds: 0.8) }

        await feed(session, phrase)
        // Feeding returns only once at most two phrases are still waiting.
        let decodedWhileFeeding = await decoder.calls.count
        XCTAssertGreaterThanOrEqual(decodedWhileFeeding, 5)
        await session.endInput()
        let finals = await collect(session).filter { if case .final = $0 { return true }; return false }
        XCTAssertEqual(finals.count, 8)
    }

    // MARK: - Subtitles

    func test_subtitles_on_this_mac_show_and_translate_each_phrase_without_a_provider() async throws {
        let audio = FixtureSubtitleAudio()
        let decoder = NumberingDecoder()
        let adapter = OnDeviceStreamingAdapter(feature: .subtitlesAudio, livePartials: true, readiness: .ready, decoder: decoder)
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { audio },
                                      open: { try await adapter.open(language: $0, terms: []) },
                                      makeService: { FixtureTranslator() })
        model.sourceCode = "en"
        let task = try XCTUnwrap(model.start())
        await waitUntil { model.phase == .listening }

        for chunk in [Self.speech(seconds: 1), Self.silence(seconds: 1), Self.speech(seconds: 1), Self.silence(seconds: 0.2)] {
            audio.pair.continuation.yield(chunk)
        }
        await waitUntil { await decoder.calls.count >= 1 }
        model.stop()
        await task.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.issue)
        let sources = model.lines.map(\.source).joined(separator: " ")
        XCTAssertTrue(sources.contains("phrase"), "decoded phrases became subtitle lines: \(sources)")
        XCTAssertTrue(model.lines.allSatisfy { $0.translation?.hasPrefix("Перевод: ") == true })
    }

    func test_subtitles_without_the_model_point_to_the_subtitles_audio_row() async throws {
        let audio = FixtureSubtitleAudio()
        let adapter = OnDeviceStreamingAdapter(feature: .subtitlesAudio, livePartials: true,
                                               readiness: .unavailable, decoder: NumberingDecoder())
        let model = LiveSubtitleModel(makeAudio: { audio }, open: { try await adapter.open(language: $0, terms: []) },
                                      makeService: { FixtureTranslator() })
        let task = try XCTUnwrap(model.start())
        await task.value

        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.issue?.feature, .subtitlesAudio)
        XCTAssertEqual(audio.started, 0, "system audio is never captured without the model")
    }

    // MARK: - Meetings

    func test_meeting_on_this_mac_is_transcribed_offline_and_gets_notes() async throws {
        let root = try temporaryRoot()
        let (routing, keys, defaults) = makeStores()
        routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .meetings)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/auto"), for: .meetingNotes)
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        let decoder = NumberingDecoder()
        let notes = NotesSpy()
        let processor = MeetingBYOKProcessor(
            routing: routing, keys: keys, vocab: VocabularyCache(defaults: defaults),
            notesRoute: DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys),
            openRouterClient: notes, sonioxSession: Self.refusingSession(),
            makeAdapter: { route in
                // The production factory's choice, with the fake decoder.
                let built = try XCTUnwrap(RealtimeAdapterFactory.make(route) as? OnDeviceStreamingAdapter)
                return OnDeviceStreamingAdapter(feature: built.feature, livePartials: built.livePartials,
                                                readiness: .ready, decoder: decoder)
            },
            onDevice: .ready
        )
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(Self.speech(seconds: 2) + Self.silence(seconds: 1) + Self.speech(seconds: 2)).write(to: chunk)
        let event = MeetingRecorder.FinalizedEvent(meetingId: UUID(), chunkURLs: [chunk], totalDurationSeconds: 5, reason: .user)

        let id = try await processor.process(event: event, startedAt: Date(timeIntervalSince1970: 1_000),
                                             language: "ru", meetingsStore: store)

        let transcript = try await store.transcript(id: id)
        XCTAssertEqual(transcript?.map(\.text).joined(), "phrase 1 phrase 2")
        XCTAssertNil(transcript?.first?.speaker, "no speaker labels on this Mac")
        XCTAssertEqual(notes.transcripts.count, 1)
        XCTAssertTrue(notes.transcripts[0].contains("phrase 1 phrase 2"))
        let meta = try await store.list().first { $0.id == id }
        XCTAssertEqual(meta?.progressStatus, .ready)
        await store.close()
    }

    func test_meeting_on_this_mac_without_the_model_fails_as_a_missing_credential() async throws {
        let root = try temporaryRoot()
        let (routing, keys, defaults) = makeStores()
        routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: .meetings)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/auto"), for: .meetingNotes)
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        let processor = MeetingBYOKProcessor(
            routing: routing, keys: keys, vocab: VocabularyCache(defaults: defaults),
            notesRoute: DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys),
            openRouterClient: NotesSpy(), sonioxSession: Self.refusingSession(),
            onDevice: .unavailable
        )
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(Self.speech(seconds: 1)).write(to: chunk)
        let event = MeetingRecorder.FinalizedEvent(meetingId: UUID(), chunkURLs: [chunk], totalDurationSeconds: 1, reason: .user)

        do {
            _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected missingTranscriptionKey")
        } catch {
            XCTAssertEqual(error as? MeetingBYOKProcessingError, .missingTranscriptionKey)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path), "the recording stays for a retry")
        await store.close()
    }

    // MARK: - Helpers

    private final class NotesSpy: OpenRouterLLMClienting, @unchecked Sendable {
        private(set) var transcripts: [String] = []
        func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] { [] }
        func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
            transcripts.append(messages.last?.content ?? "")
            return "<!-- protocol:v1 -->\n# Planning"
        }
    }

    private func feed(_ session: OnDeviceStreamingSession, _ samples: [Float]) async {
        let data = Self.pcm16(samples)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 3_200, data.count)
            await session.sendAudio(data.subdata(in: offset..<end))
            offset = end
        }
    }

    private func collect(_ session: OnDeviceStreamingSession) async -> [BYOKStreamEvent] {
        var events: [BYOKStreamEvent] = []
        for await event in session.events { events.append(event) }
        return events
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out", file: file, line: line)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private static func wav(_ samples: [Float]) -> Data {
        let body = pcm16(samples)
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(body.count + 36)); data.append(Data("WAVEfmt ".utf8)); append(16)
        data.append(contentsOf: [1, 0, 1, 0]); append(16000); append(32000)
        data.append(contentsOf: [2, 0, 16, 0]); data.append(Data("data".utf8)); append(UInt32(body.count))
        data.append(body)
        return data
    }

    /// Every request fails the test: on-device paths must not make one.
    private static func refusingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingProtocol.self]
        return URLSession(configuration: configuration)
    }

    private final class RefusingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            XCTFail("an on-device path made a network request")
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }
}
