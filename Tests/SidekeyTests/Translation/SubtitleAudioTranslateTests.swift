import XCTest
@testable import Sidekey

/// Subtitles run on Soniox live translation with the Soniox key, or on
/// OpenAI gpt-realtime-translate without it: key gating, the retired
/// Speech/LLM routes, the Models card and Start without a key.
@MainActor
final class SubtitleAudioTranslateTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "audio-translate-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func keyStore(openAI: String? = nil, soniox: String? = nil) throws -> ProviderKeyStore {
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        if let openAI { try keys.save(openAI, account: SubtitleAudioTranslate.keychainAccount) }
        if let soniox { try keys.save(soniox, account: BYOKKeyStore.account(for: .soniox)) }
        return keys
    }

    /// The Soniox key Drop uses runs Subtitles on Soniox; without it the
    /// OpenAI key runs them on OpenAI; without either Start names the fix.
    func testTheSonioxKeyChoosesSonioxAndOpenAIIsTheFallback() throws {
        let both = try SubtitleAudioTranslate.engineAndKey(from: keyStore(openAI: "openai-synthetic", soniox: "soniox-synthetic"))
        XCTAssertEqual(both.0, .soniox)
        XCTAssertEqual(both.1, "soniox-synthetic")
        let soniox = try SubtitleAudioTranslate.engineAndKey(from: keyStore(soniox: "soniox-synthetic"))
        XCTAssertEqual(soniox.0, .soniox)
        let openAI = try SubtitleAudioTranslate.engineAndKey(from: keyStore(openAI: "openai-synthetic"))
        XCTAssertEqual(openAI.0, .openAI)
        XCTAssertEqual(openAI.1, "openai-synthetic")
        XCTAssertThrowsError(try SubtitleAudioTranslate.engineAndKey(from: keyStore())) { error in
            XCTAssertEqual(error as? SubtitleAudioTranslate.Unavailable, .missingKey)
        }
        // An unreadable Soniox key falls back to a readable OpenAI one, and
        // is named when there is none.
        XCTAssertEqual(SubtitleAudioTranslate.engine(soniox: .unreadable, openAI: .present), .openAI)
        XCTAssertNil(SubtitleAudioTranslate.engine(soniox: .unreadable, openAI: .missing))
        XCTAssertEqual(SubtitleAudioTranslate.unavailable(soniox: .unreadable, openAI: .missing), .unreadableKey)
        XCTAssertEqual(SubtitleAudioTranslate.unavailable(soniox: .missing, openAI: .missing), .missingKey)
        XCTAssertEqual(SubtitleAudioTranslate.Engine.soniox.label, "Soniox · stt-rt-v6")
        XCTAssertEqual(SubtitleAudioTranslate.Engine.openAI.label, "OpenAI · gpt-realtime-translate")
    }

    /// A refusal while opening names the engine that refused.
    func testAnOpeningFailureNamesItsProvider() async throws {
        let model = LiveSubtitleModel(makeAudio: { FixtureSubtitleAudio() }, openTranslator: { _, _ in
            throw SubtitleAudioTranslate.EngineFailure(failure: .refusedKey, provider: "Soniox")
        })
        await model.start()?.value
        XCTAssertEqual(model.issue?.message, "Soniox refused the API key. Check it in Keys & models.")
        XCTAssertEqual(model.issue?.feature, .subtitlesAudio)
        let language = TranslationIssue.speechTranslation(.unsupportedLanguage, target: "ru", provider: "Soniox")
        XCTAssertEqual(language.message, "Soniox live translation does not support Russian. Choose another target language.")
    }

    // MARK: - Key

    func testTheOpenAIKeyIsTheOnlyRequirement() throws {
        XCTAssertEqual(try SubtitleAudioTranslate.key(from: keyStore(openAI: "synthetic")), "synthetic")
        XCTAssertThrowsError(try SubtitleAudioTranslate.key(from: keyStore())) { error in
            XCTAssertEqual(error as? SubtitleAudioTranslate.Unavailable, .missingKey)
        }
        XCTAssertEqual(SubtitleAudioTranslate.KeyState(.unreadable), .unreadable)
        XCTAssertEqual(SubtitleAudioTranslate.KeyState(.absent), .missing)
    }

    func testStartWithoutTheKeySaysWhyAndCapturesNothing() async throws {
        let audio = FixtureSubtitleAudio()
        let model = LiveSubtitleModel(makeAudio: { audio },
                                      openTranslator: { _, _ in throw SubtitleAudioTranslate.Unavailable.missingKey })
        await model.start()?.value
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.issue?.message, "Subtitles need a Soniox or OpenAI key. Add one in Keys & models.")
        XCTAssertEqual(model.issue?.feature, .subtitlesAudio)
        XCTAssertEqual(audio.started, 0)
    }

    func testAnUnreadableKeyIsNamedToo() {
        let issue = TranslationIssue.from(SubtitleAudioTranslate.Unavailable.unreadableKey, feature: .subtitlesAudio)
        XCTAssertEqual(issue.message, "Whytap couldn't read the Subtitles key from the Keychain. Check it in Keys & models.")
        XCTAssertEqual(issue.feature, .subtitlesAudio)
    }

    // MARK: - One-hour limit

    private func wait(_ condition: @autoclosure () -> Bool, seconds: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testTheLimitIsOneHour() {
        XCTAssertEqual(LiveSubtitleModel.maxSessionDuration, .seconds(3_600))
    }

    func testASessionStopsQuietlyAtTheLimitLikeStopAndClosesTheSocket() async throws {
        let audio = FixtureSubtitleAudio()
        let session = FakeSpeechTranslation()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), maxSessionDuration: .milliseconds(80),
                                      makeAudio: { audio }, openTranslator: { _, _ in session })
        let task = try XCTUnwrap(model.start())
        try await wait(model.phase == .listening)
        session.pair.continuation.yield(.source("Hello there.", elapsedMs: 1_000))
        session.pair.continuation.yield(.translation("Привет.", elapsedMs: 1_200))
        await task.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.issue, "no message: the same as pressing Stop")
        XCTAssertEqual(session.endInputCount, 1, "a graceful finish, not a cancel")
        XCTAssertGreaterThanOrEqual(session.closeCount, 1, "the socket is closed")
        XCTAssertEqual(audio.finished, 1, "system audio capture ended")
        XCTAssertEqual(model.lines.map(\.translation), ["Привет."], "pairs said before the limit stay")
    }

    func testStartingAgainBeginsANewHour() async throws {
        var sessions: [FakeSpeechTranslation] = []
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), maxSessionDuration: .seconds(2),
                                      makeAudio: { FixtureSubtitleAudio() },
                                      openTranslator: { _, _ in let s = FakeSpeechTranslation(); sessions.append(s); return s })
        let first = try XCTUnwrap(model.start())
        try await wait(model.phase == .listening)
        try await Task.sleep(for: .milliseconds(900))
        model.stop()
        await first.value
        XCTAssertEqual(model.phase, .idle)
        let second = try XCTUnwrap(model.start())
        try await wait(model.phase == .listening)
        let listening = ContinuousClock.now
        // The first session's deadline has passed, but the second still has
        // time left. Give the scheduler room on both sides of that boundary.
        try await Task.sleep(for: .milliseconds(1_200))
        let phase = model.phase
        if ContinuousClock.now - listening >= .milliseconds(1_900) {
            // A loaded Mac overslept into the second session's own limit: this
            // run cannot tell the two deadlines apart, so it judges nothing.
            await second.value
            throw XCTSkip("The scheduler overslept past the second session's limit")
        }
        XCTAssertEqual(phase, .listening)
        await second.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map(\.endInputCount), [1, 1])
    }

    func testClosingTheWindowEndsTheSessionAndTheTimerWithIt() async throws {
        let session = FakeSpeechTranslation()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), maxSessionDuration: .milliseconds(100),
                                      makeAudio: { FixtureSubtitleAudio() }, openTranslator: { _, _ in session })
        let task = try XCTUnwrap(model.start())
        try await wait(model.phase == .listening)
        await model.cancel().value
        await task.value
        XCTAssertGreaterThanOrEqual(session.closeCount, 1)
        XCTAssertEqual(session.endInputCount, 0, "a cancel does not wait for the provider")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(session.endInputCount, 0, "the stale timer does nothing")
    }

    // MARK: - Retired routes

    func testSubtitlesHaveNoSpeechOrLLMRouteAndSavedOnesAreIgnoredButKept() throws {
        XCTAssertFalse(AIFeature.activeCases.contains(.subtitlesAudio))
        XCTAssertFalse(AIFeature.activeCases.contains(.subtitlesTranslation))
        for kind in AIProviderKind.allCases {
            XCTAssertNil(AIFeature.subtitlesAudio.modelUse(on: kind), kind.rawValue)
            XCTAssertNil(AIFeature.subtitlesTranslation.modelUse(on: kind), kind.rawValue)
        }
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(FeatureRoute(account: .soniox, model: ModelRegistry.sonioxRealtimeModel), for: .dropFast)
        // A saved document from an older build: Subtitles routes inside.
        var state = routing.state
        state.routes[AIFeature.subtitlesAudio.rawValue] = FeatureRoute(account: .elevenLabs, model: ModelRegistry.elevenLabsRealtimeModel)
        state.routes[AIFeature.subtitlesTranslation.rawValue] = FeatureRoute(account: .anthropic, model: ModelRegistry.anthropicAgentModel)
        defaults.set(try JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)
        let reloaded = AIRoutingStore(defaults: defaults)
        XCTAssertNil(reloaded.route(for: .subtitlesAudio))
        XCTAssertNil(reloaded.route(for: .subtitlesTranslation))
        // An edit elsewhere keeps them for a rollback build.
        reloaded.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .dropFast)
        XCTAssertEqual(AIRoutingStore(defaults: defaults).state.routes[AIFeature.subtitlesAudio.rawValue]?.account, .elevenLabs)
    }

    func testCostsStillGroupSubtitlesSessions() {
        let context = AIUsageContext(feature: .subtitlesAudio, account: .openAI, model: SubtitleAudioTranslate.model)
        let rows = AIUsageCostRow.grouped([AIUsageEvent.speech(context, seconds: 3_600)])
        XCTAssertEqual(rows.map(\.title), ["Subtitles"])
    }

    // MARK: - Models card

    private func makeViewModel(openAIKey: Bool, sonioxKey: Bool = false) throws -> APIAndModelsViewModel {
        let routing = AIRoutingStore(defaults: defaults)
        let keys = try keyStore(openAI: openAIKey ? "synthetic" : nil, soniox: sonioxKey ? "synthetic" : nil)
        try keys.save("synthetic", account: XCTUnwrap(ProviderAccount.elevenLabs.keychainAccount(in: routing)))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        try Data("{}".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let stub = SlotNoNetwork()
        return APIAndModelsViewModel(routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: file, fetcher: stub), checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults), keyChecker: stub, probe: stub, endpoints: stub,
            inputLanguage: { nil }, onDevice: OnDeviceSpeechReadiness(isReady: { false }))
    }

    private func subtitles(_ vm: APIAndModelsViewModel) throws -> FeatureGroup {
        try XCTUnwrap(vm.groups.first { $0.title == "Subtitles" })
    }

    func testWithTheKeySubtitlesShowOnlyTheLitSlot() throws {
        let vm = try makeViewModel(openAIKey: true)
        let group = try subtitles(vm)
        XCTAssertEqual(group.rows, [])
        XCTAssertEqual(group.audioTranslate, AudioTranslateSlot(soniox: .missing, openAI: .present))
        XCTAssertEqual(group.audioTranslate?.label, "OpenAI · gpt-realtime-translate")
        XCTAssertEqual(group.summary, "gpt-realtime-translate")
        XCTAssertFalse(group.needsSetup)
        XCTAssertTrue(group.covers(.subtitlesAudio))
        XCTAssertTrue(group.covers(.subtitlesTranslation))
        XCTAssertFalse(vm.rows.contains { $0.feature == .subtitlesAudio || $0.feature == .subtitlesTranslation })
        XCTAssertNil(vm.groups.first { $0.title != "Subtitles" && $0.audioTranslate != nil })
    }

    func testWithTheSonioxKeySubtitlesShowSoniox() throws {
        let vm = try makeViewModel(openAIKey: true, sonioxKey: true)
        let group = try subtitles(vm)
        XCTAssertEqual(group.audioTranslate?.engine, .soniox)
        XCTAssertEqual(group.audioTranslate?.label, "Soniox · stt-rt-v6")
        XCTAssertEqual(group.summary, "stt-rt-v6")
        XCTAssertFalse(group.needsSetup)
        let only = try subtitles(makeViewModel(openAIKey: false, sonioxKey: true))
        XCTAssertEqual(only.audioTranslate?.engine, .soniox, "Soniox alone is enough")
    }

    func testWithoutTheKeyTheSlotIsDimmedAndCountsAsMissing() throws {
        let vm = try makeViewModel(openAIKey: false)
        let group = try subtitles(vm)
        XCTAssertEqual(group.audioTranslate?.isActive, false)
        XCTAssertTrue(group.needsSetup)
        let unset = vm.rows.filter { $0.status == .notSet }.count + 1
        XCTAssertEqual(vm.unsetBanner, unset == 1 ? "1 feature has no model" : "\(unset) features have no model")
    }
}

private struct SlotNoNetwork: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        throw CatalogFetchError.offline
    }
    func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
    func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
    func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
}
