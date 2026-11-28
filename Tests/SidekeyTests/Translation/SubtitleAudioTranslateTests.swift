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

    private var choice: SubtitleAudioTranslate.Choice { SubtitleAudioTranslate.Choice(defaults: defaults) }

    private func engine(_ keys: ProviderKeyStore) throws -> SubtitleAudioTranslate.Engine {
        try SubtitleAudioTranslate.engineAndKey(saved: choice.saved, from: keys).0
    }

    // MARK: - Engine choice

    /// Someone with only an OpenAI key has a complete setup: OpenAI, its key.
    func testOnlyAnOpenAIKeyRunsOpenAI() throws {
        let result = try SubtitleAudioTranslate.engineAndKey(saved: nil, from: keyStore(openAI: "openai-synthetic"))
        XCTAssertEqual(result.0, .openAI)
        XCTAssertEqual(result.1, "openai-synthetic")
    }

    func testOnlyASonioxKeyRunsSoniox() throws {
        let result = try SubtitleAudioTranslate.engineAndKey(saved: nil, from: keyStore(soniox: "soniox-synthetic"))
        XCTAssertEqual(result.0, .soniox)
        XCTAssertEqual(result.1, "soniox-synthetic")
    }

    /// An install updating from 2.2.27 (OpenAI only) that already has a
    /// Soniox key for Drop keeps sending Subtitles audio to OpenAI.
    func testBothKeysWithoutAChoiceStayOnOpenAI() throws {
        let keys = try keyStore(openAI: "openai-synthetic", soniox: "soniox-synthetic")
        let result = try SubtitleAudioTranslate.engineAndKey(saved: nil, from: keys)
        XCTAssertEqual(result.0, .openAI)
        XCTAssertEqual(result.1, "openai-synthetic")
    }

    func testBothKeysFollowEachExplicitChoice() throws {
        let keys = try keyStore(openAI: "openai-synthetic", soniox: "soniox-synthetic")
        choice.saved = .soniox
        XCTAssertEqual(try SubtitleAudioTranslate.engineAndKey(saved: choice.saved, from: keys).1, "soniox-synthetic")
        choice.saved = .openAI
        XCTAssertEqual(try SubtitleAudioTranslate.engineAndKey(saved: choice.saved, from: keys).1, "openai-synthetic")
    }

    /// Removing the chosen engine's key never moves audio to the other one.
    func testTheChosenEnginesRemovedKeyIsNamedAndTheOtherIsNotUsed() throws {
        let keys = try keyStore(openAI: "openai-synthetic", soniox: "soniox-synthetic")
        choice.saved = .soniox
        XCTAssertEqual(try engine(keys), .soniox)
        try keys.delete(account: BYOKKeyStore.account(for: .soniox))
        XCTAssertThrowsError(try engine(keys)) { error in
            XCTAssertEqual(error as? SubtitleAudioTranslate.Unavailable, .chosenKeyMissing(.soniox))
        }
        choice.saved = .openAI
        try keys.delete(account: SubtitleAudioTranslate.keychainAccount)
        try keys.save("soniox-synthetic", account: BYOKKeyStore.account(for: .soniox))
        XCTAssertThrowsError(try engine(keys)) { error in
            XCTAssertEqual(error as? SubtitleAudioTranslate.Unavailable, .chosenKeyMissing(.openAI))
        }
        let issue = TranslationIssue.from(SubtitleAudioTranslate.Unavailable.chosenKeyMissing(.openAI), feature: .subtitlesAudio)
        XCTAssertEqual(issue.message, "Subtitles are set to OpenAI and need its API key. Add it or choose another model in Keys & models.")
        XCTAssertEqual(issue.feature, .subtitlesAudio)
    }

    /// An unreadable key is named, never replaced by the other engine; without
    /// a choice an unreadable OpenAI key still means OpenAI.
    func testAnUnreadableKeyIsNamedAndNotReplaced() {
        XCTAssertNil(SubtitleAudioTranslate.engine(saved: .soniox, soniox: .unreadable, openAI: .present))
        XCTAssertEqual(SubtitleAudioTranslate.unavailable(saved: .soniox, soniox: .unreadable, openAI: .present),
                       .unreadableKey(.soniox))
        XCTAssertNil(SubtitleAudioTranslate.engine(saved: nil, soniox: .present, openAI: .unreadable))
        XCTAssertEqual(SubtitleAudioTranslate.unavailable(saved: nil, soniox: .present, openAI: .unreadable),
                       .unreadableKey(.openAI))
        XCTAssertEqual(SubtitleAudioTranslate.unavailable(saved: nil, soniox: .unreadable, openAI: .missing),
                       .unreadableKey(.soniox))
        XCTAssertEqual(SubtitleAudioTranslate.unavailable(saved: nil, soniox: .missing, openAI: .missing), .missingKey)
        XCTAssertEqual(SubtitleAudioTranslate.Engine.soniox.label, "Soniox · stt-rt-v6")
        XCTAssertEqual(SubtitleAudioTranslate.Engine.openAI.label, "OpenAI · gpt-realtime-translate")
    }

    /// The choice lives in UserDefaults: a new process (relaunch) reads it.
    func testAChoiceSurvivesRelaunch() throws {
        choice.saved = .soniox
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(SubtitleAudioTranslate.Choice(defaults: relaunched).saved, .soniox)
        XCTAssertEqual(relaunched.string(forKey: "sidekey.translation.subtitleEngine"), "soniox")
        // A value from a newer build reads as no choice and is kept.
        relaunched.set("future-engine", forKey: SubtitleAudioTranslate.Choice.defaultsKey)
        XCTAssertNil(choice.saved)
        SubtitleAudioTranslate.pinDefault(.openAI, savedAtStart: nil, choice: choice)
        XCTAssertEqual(defaults.string(forKey: SubtitleAudioTranslate.Choice.defaultsKey), "future-engine")
    }

    /// The default an opened session used is saved, so adding the other key
    /// later does not move the audio; an explicit choice is never overwritten.
    func testTheDefaultIsPinnedOnceSubtitlesOpen() throws {
        SubtitleAudioTranslate.pinDefault(.soniox, savedAtStart: nil, choice: choice)
        XCTAssertEqual(choice.saved, .soniox)
        let keys = try keyStore(openAI: "openai-synthetic", soniox: "soniox-synthetic")
        XCTAssertEqual(try engine(keys), .soniox, "the OpenAI key added later changes nothing")
        // The user chose meanwhile: the pin does not override it.
        choice.saved = .openAI
        SubtitleAudioTranslate.pinDefault(.soniox, savedAtStart: nil, choice: choice)
        XCTAssertEqual(choice.saved, .openAI)
    }

    /// Start with the chosen engine's key gone: a named issue, no capture.
    func testStartWithTheChosenKeyGoneSaysWhichAndCapturesNothing() async throws {
        let audio = FixtureSubtitleAudio()
        let keys = try keyStore(openAI: "openai-synthetic")
        choice.saved = .soniox
        let model = LiveSubtitleModel(makeAudio: { audio }, openTranslator: { [choice] source, target in
            try await SubtitleAudioTranslate.open(source: source, target: target, keys: keys, choice: choice)
        })
        await model.start()?.value
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.issue?.message,
                       "Subtitles are set to Soniox and need its API key. Add it or choose another model in Keys & models.")
        XCTAssertEqual(model.issue?.feature, .subtitlesAudio)
        XCTAssertEqual(audio.started, 0)
        XCTAssertEqual(choice.saved, .soniox, "the failed start keeps the choice")
    }

    // MARK: - Backup

    /// An archive from before the choice existed leaves it as it is; a newer
    /// archive restores it. Restore decides through the one rule for keys an
    /// archive's writer did not know (`ArtifactSettingsPayload.keysUnknownToWriter`).
    /// WHY: .project-docs/decisions/2026-11-28-backup-keys-unknown-to-the-writer.md
    func testAnOlderBackupKeepsTheChoiceAndANewerOneRestoresIt() throws {
        func restore(_ payload: ArtifactSettingsPayload) throws {
            try ConfigBackupRegistry.apply(payload.values, sections: payload.appliedSections,
                                           preservingMissingKeys: payload.keysUnknownToWriter, to: defaults)
        }
        choice.saved = .soniox
        defaults.set("de", forKey: "sidekey.translation.subtitleTarget")
        try restore(ArtifactSettingsPayload(values: ["sidekey.translation.subtitleTarget": .string("fr")],
                                            selectedSections: [.models]))
        XCTAssertEqual(choice.saved, .soniox)
        XCTAssertEqual(defaults.string(forKey: "sidekey.translation.subtitleTarget"), "fr")
        XCTAssertNil(defaults.object(forKey: "sidekey.translation.source"), "other absent keys still clear as before")
        let captured = try ConfigBackupRegistry.capture(defaults)
        XCTAssertEqual(captured[SubtitleAudioTranslate.Choice.defaultsKey], .string("soniox"))
        choice.saved = .openAI
        try restore(ArtifactSettingsPayload(values: captured.filter { ConfigBackupRegistry.entries[$0.key]?.section == .models },
                                            selectedSections: [.models], knownKeys: ConfigBackupRegistry.entries.keys.sorted()))
        XCTAssertEqual(choice.saved, .soniox)
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

    func testStartWithoutTheKeySaysWhyAndCapturesNothing() async throws {
        let audio = FixtureSubtitleAudio()
        let model = LiveSubtitleModel(makeAudio: { audio },
                                      openTranslator: { _, _ in throw SubtitleAudioTranslate.Unavailable.missingKey })
        await model.start()?.value
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.issue?.message, "Subtitles need a Soniox or OpenAI key. Add one in Keys & models.")
        XCTAssertEqual(model.issue?.feature, .subtitlesAudio)
        XCTAssertEqual(audio.started, 0)
        XCTAssertEqual(SubtitleAudioTranslate.KeyState(.unreadable), .unreadable)
        XCTAssertEqual(SubtitleAudioTranslate.KeyState(.absent), .missing)
    }

    func testAnUnreadableKeyNamesItsProvider() {
        let issue = TranslationIssue.from(SubtitleAudioTranslate.Unavailable.unreadableKey(.soniox), feature: .subtitlesAudio)
        XCTAssertEqual(issue.message, "Whytap couldn't read the Soniox key from the Keychain. Check it in Keys & models.")
        XCTAssertEqual(issue.feature, .subtitlesAudio)
    }

    // MARK: - One-hour limit

    /// A deadline that runs out fails the test instead of passing late.
    private func wait(_ condition: @autoclosure () -> Bool, seconds: Double = 30,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
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

    private func makeViewModel(openAIKey: Bool, sonioxKey: Bool = false,
                               keys existing: ProviderKeyStore? = nil) throws -> APIAndModelsViewModel {
        let routing = AIRoutingStore(defaults: defaults)
        let keys = try existing ?? keyStore(openAI: openAIKey ? "synthetic" : nil, soniox: sonioxKey ? "synthetic" : nil)
        try keys.save("synthetic", account: XCTUnwrap(ProviderAccount.elevenLabs.keychainAccount(in: routing)))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        try Data("{}".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let stub = SlotNoNetwork()
        return APIAndModelsViewModel(routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: file, fetcher: stub), checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults), keyChecker: stub, probe: stub, endpoints: stub,
            inputLanguage: { nil }, onDevice: OnDeviceSpeechReadiness(isReady: { false }),
            subtitleEngine: choice)
    }

    private func subtitles(_ vm: APIAndModelsViewModel) throws -> FeatureGroup {
        try XCTUnwrap(vm.groups.first { $0.title == "Subtitles" })
    }

    private func pickerRows(_ slot: AudioTranslateSlot) -> [(String, Bool, Bool)] {
        ModelPickerSearch.results(in: slot.sections, query: "").map {
            ($0.providerTitle, $0.isEnabled, $0.option.isSelected)
        }
    }

    func testWithOnlyTheOpenAIKeyOpenAIIsSelectedAndSonioxNamesItsKey() throws {
        let vm = try makeViewModel(openAIKey: true)
        let group = try subtitles(vm)
        XCTAssertEqual(group.rows, [])
        let slot = try XCTUnwrap(group.audioTranslate)
        XCTAssertEqual(slot.label, "OpenAI · gpt-realtime-translate")
        XCTAssertEqual(group.summary, "gpt-realtime-translate")
        XCTAssertFalse(group.needsSetup)
        XCTAssertNil(slot.issue)
        XCTAssertTrue(group.covers(.subtitlesAudio))
        XCTAssertTrue(group.covers(.subtitlesTranslation))
        XCTAssertFalse(vm.rows.contains { $0.feature == .subtitlesAudio || $0.feature == .subtitlesTranslation })
        XCTAssertNil(vm.groups.first { $0.title != "Subtitles" && $0.audioTranslate != nil })
        // Soniox is listed first, disabled, with what it needs.
        XCTAssertEqual(pickerRows(slot).map(\.0), ["Soniox", "OpenAI"])
        XCTAssertEqual(pickerRows(slot).map(\.1), [false, true])
        XCTAssertEqual(pickerRows(slot).map(\.2), [false, true])
        XCTAssertEqual(slot.sections.first?.options.first?.state,
                       .notSupported(reason: "Add a Soniox key in API keys to use it"))
        XCTAssertFalse(vm.selectSubtitleEngine(.soniox), "an engine without a key can't be chosen")
        XCTAssertNil(choice.saved)
    }

    func testWithOnlyTheSonioxKeySonioxIsSelected() throws {
        let slot = try XCTUnwrap(subtitles(makeViewModel(openAIKey: false, sonioxKey: true)).audioTranslate)
        XCTAssertEqual(slot.engine, .soniox)
        XCTAssertEqual(slot.label, "Soniox · stt-rt-v6")
        XCTAssertEqual(pickerRows(slot).map(\.1), [true, false])
        XCTAssertEqual(slot.sections.last?.options.first?.state,
                       .notSupported(reason: "Add an OpenAI key in API keys to use it"))
    }

    /// Both keys and no choice: OpenAI; picking Soniox saves it, the row and
    /// a new Settings window (relaunch) show it.
    func testWithBothKeysTheRowDefaultsToOpenAIAndFollowsAPick() throws {
        let vm = try makeViewModel(openAIKey: true, sonioxKey: true)
        XCTAssertEqual(try subtitles(vm).audioTranslate?.engine, .openAI)
        XCTAssertEqual(try subtitles(vm).summary, "gpt-realtime-translate")
        XCTAssertTrue(vm.selectSubtitleEngine(.soniox))
        XCTAssertEqual(choice.saved, .soniox)
        XCTAssertEqual(try subtitles(vm).audioTranslate?.label, "Soniox · stt-rt-v6")
        XCTAssertEqual(try subtitles(vm).summary, "stt-rt-v6")
        let slot = try XCTUnwrap(subtitles(vm).audioTranslate)
        XCTAssertEqual(pickerRows(slot).map(\.2), [true, false])
        XCTAssertEqual(AudioTranslateSlot.engine(account: .openAI, model: "gpt-realtime-translate"), .openAI)
        XCTAssertEqual(AudioTranslateSlot.engine(account: .soniox, model: "stt-rt-v6"), .soniox)
        XCTAssertNil(AudioTranslateSlot.engine(account: .soniox, model: "gpt-realtime-translate"))
        let reopened = try makeViewModel(openAIKey: true, sonioxKey: true)
        XCTAssertEqual(try subtitles(reopened).audioTranslate?.engine, .soniox)
        XCTAssertTrue(reopened.selectSubtitleEngine(.openAI))
        XCTAssertEqual(choice.saved, .openAI)
    }

    /// The chosen engine's key removed: the row keeps it, asks for setup and
    /// counts as missing; the other engine stays selectable.
    func testTheChosenEnginesRemovedKeyNeedsSetupWithoutSwitching() throws {
        let keys = try keyStore(openAI: "synthetic", soniox: "synthetic")
        choice.saved = .soniox
        try keys.delete(account: BYOKKeyStore.account(for: .soniox))
        let vm = try makeViewModel(openAIKey: true, keys: keys)
        let group = try subtitles(vm)
        let slot = try XCTUnwrap(group.audioTranslate)
        XCTAssertEqual(slot.intended, .soniox)
        XCTAssertNil(slot.engine)
        XCTAssertEqual(slot.label, "Soniox · stt-rt-v6")
        XCTAssertEqual(slot.issue, "Needs a Soniox key")
        XCTAssertTrue(group.needsSetup)
        XCTAssertEqual(pickerRows(slot).map(\.1), [false, true])
        let unset = vm.rows.filter { $0.status == .notSet }.count + 1
        XCTAssertEqual(vm.unsetBanner, unset == 1 ? "1 feature has no model" : "\(unset) features have no model")
    }

    func testAnUnreadableKeyIsShownAndCannotBeChosen() throws {
        let box = InMemoryTokenStore.Box()
        let sonioxAccount = BYOKKeyStore.account(for: .soniox)
        let keys = ProviderKeyStore(makeStore: { account in
            account == sonioxAccount ? UnreadableTokenStore() as any TokenStore : InMemoryTokenStore(account: account, box: box)
        })
        try keys.save("synthetic", account: SubtitleAudioTranslate.keychainAccount)
        choice.saved = .soniox
        let vm = try makeViewModel(openAIKey: true, keys: keys)
        let slot = try XCTUnwrap(subtitles(vm).audioTranslate)
        XCTAssertEqual(slot.issue, "Couldn't read the Soniox key")
        XCTAssertEqual(slot.sections.first?.keyProblem, "Couldn't read the key")
        XCTAssertEqual(pickerRows(slot).map(\.1), [false, true])
        XCTAssertFalse(vm.selectSubtitleEngine(.soniox))
        XCTAssertThrowsError(try SubtitleAudioTranslate.engineAndKey(saved: choice.saved, from: keys)) { error in
            XCTAssertEqual(error as? SubtitleAudioTranslate.Unavailable, .unreadableKey(.soniox))
        }
    }

    func testWithoutAnyKeyTheRowLooksUnsetAndCountsAsMissing() throws {
        let vm = try makeViewModel(openAIKey: false)
        let group = try subtitles(vm)
        let slot = try XCTUnwrap(group.audioTranslate)
        XCTAssertFalse(slot.isActive)
        XCTAssertEqual(slot.label, "Choose a model")
        XCTAssertNil(slot.issue)
        XCTAssertEqual(slot.sections, [], "the picker shows its Add a key state")
        XCTAssertTrue(group.needsSetup)
        let unset = vm.rows.filter { $0.status == .notSet }.count + 1
        XCTAssertEqual(vm.unsetBanner, unset == 1 ? "1 feature has no model" : "\(unset) features have no model")
    }
}

private struct UnreadableTokenStore: TokenStore {
    struct Locked: Error {}
    func save(_ token: String) throws { throw Locked() }
    func read() throws -> String? { throw Locked() }
    func delete() throws { throw Locked() }
    func exists() -> Bool { true }
}

private struct SlotNoNetwork: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        throw CatalogFetchError.offline
    }
    func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
    func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
    func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
}
