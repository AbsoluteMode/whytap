import ApplicationServices
import Combine
import XCTest
@testable import Sidekey

/// User scenarios for learning from edits after Drop: a take is pasted, the
/// user corrects the field and sends it (or leaves it); the text the field
/// held last before that is compared with the paste.
@MainActor
final class DropLearningScenarioTests: XCTestCase {
    private final class FakeField: DropEditFieldAccess {
        final class Watch: DropEditFieldWatch {
            var cancelled = false
            func cancel() { cancelled = true }
        }

        var capturable = true
        /// Focus is verifiably elsewhere: during the paste delay, or later.
        var focusMovedAfterCapture = false
        /// What the field holds at each read, in order; the last value
        /// repeats. nil is a field still focused that cannot be read.
        var reads: [String?] = [] { didSet { position = 0 } }
        private var position = 0
        private(set) var readCount = 0
        private(set) var captureCount = 0
        /// The AX notifications of the watched field.
        private(set) var onChange: (@MainActor (DropEditFieldChange) -> Void)?
        private(set) var watches: [Watch] = []
        /// The app needs its tree turned on (Electron, web views).
        var needsExposure = false
        private(set) var exposed = 0
        private(set) var released = 0

        var refusal = "secureField"
        var lastRefusal: String? { capturable ? nil : refusal }
        func capture(pid: pid_t) -> DropEditFieldHandle? {
            captureCount += 1
            return capturable ? DropEditFieldHandle(pid: pid, element: AXUIElementCreateApplication(pid)) : nil
        }
        func isStillFocused(_ handle: DropEditFieldHandle) -> Bool { !focusMovedAfterCapture }
        func read(_ handle: DropEditFieldHandle) -> DropEditFieldRead {
            readCount += 1
            if focusMovedAfterCapture { return .focusLeft }
            guard !reads.isEmpty else { return .unreadable }
            defer { position = min(position + 1, reads.count - 1) }
            return reads[position].map { .text($0) } ?? .unreadable
        }
        func watch(_ handle: DropEditFieldHandle,
                   onChange: @escaping @MainActor (DropEditFieldChange) -> Void) -> DropEditFieldWatch? {
            self.onChange = onChange
            let watch = Watch()
            watches.append(watch)
            return watch
        }
        func exposeFields(pid: pid_t) -> DropEditAccessibilityLease? {
            guard needsExposure else { return nil }
            exposed += 1
            return DropEditAccessibilityLease(pid: pid) { [unowned self] in released += 1 }
        }
    }

    private struct FakeLexicon: DropWordLexicon {
        var known: Set<String> = ["позвони", "завтра", "я", "приду", "напиши", "код", "в", "и", "ну",
                                  "типа", "короче", "скажи", "привет", "отправь", "отчёт", "отчет", "кот"]
        func isKnownWord(_ word: String) -> Bool { known.contains(word.lowercased()) }
    }

    private var defaults: UserDefaults!
    private var field: FakeField!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var idle = true
    private var suggestions: [DropLearningSuggestion] = []
    private var vocabOpened = 0
    private var journalURL: URL!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "drop.learning.\(UUID().uuidString)")!
        defaults.set(true, forKey: DropLearningSettings.enabledKey)
        field = FakeField()
        journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-learning-\(UUID().uuidString)").appendingPathComponent("calibration.jsonl")
    }

    /// Return or Enter in the watched app.
    private var pressReturn: (@MainActor () -> Void)?
    private var returnWatchStops = 0

    private func makeCoordinator(sleep: @escaping (Double) async throws -> Void = { _ in }) -> DropLearningCoordinator {
        let coordinator = DropLearningCoordinator(dependencies: .init(
            fieldAccess: field, lexicon: FakeLexicon(), defaults: defaults, now: { [unowned self] in now },
            journal: DropLearningJournal(url: journalURL),
            lists: { [unowned self] in
                DropLearningLists(
                    vocabulary: VocabularyCache(defaults: defaults).terms,
                    fillers: FillerTermsStore(defaults: defaults).terms(),
                    replacements: DropReplacementStore(defaults: defaults).replacements()
                )
            },
            // Every sleep moves the clock, so the deadlines are seconds.
            sleep: { [unowned self] seconds in
                try await sleep(seconds)
                now += seconds
            },
            isIdle: { [unowned self] in idle },
            openVocabulary: { [unowned self] in vocabOpened += 1 },
            vocabulary: VocabularyCache(defaults: defaults),
            fillers: FillerTermsStore(defaults: defaults),
            replacements: DropReplacementStore(defaults: defaults),
            watchReturn: { [unowned self] onReturn in
                pressReturn = onReturn
                return { [unowned self] in
                    returnWatchStops += 1
                    pressReturn = nil
                }
            },
            clock: { [unowned self] in now.timeIntervalSince1970 },
            appID: { _ in "com.anthropic.claudefordesktop" }
        ))
        coordinator.onSuggestion = { [unowned self] in suggestions.append($0); return true }
        return coordinator
    }

    /// Sleeps until the observation is stopped: the test drives every read.
    private static let held: (Double) async throws -> Void = { _ in
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }

    private func take(
        pasted: String, raw: String? = nil, mode: TranscriptionMode = .fast, translated: Bool = false,
        fired: [DropReplacement] = [], fillers: [String] = [], transport: VocabularyTransport = .deepgram
    ) -> DropLearningTake {
        DropLearningTake(pasted: pasted, raw: raw ?? pasted, mode: mode, translated: translated,
                         firedReplacements: fired, firedFillers: fillers, vocabTransport: transport)
    }

    /// The paste lands, the user edits it to `text` and sends it: the field
    /// empties.
    private func run(_ coordinator: DropLearningCoordinator, _ take: DropLearningTake, field text: String?) async {
        field.reads = text.map { [take.pasted, $0, ""] } ?? [nil]
        await runReads(coordinator, take)
    }

    private func runReads(_ coordinator: DropLearningCoordinator, _ take: DropLearningTake) async {
        let handle = coordinator.prepareDelivery(targetPID: 4242)
        coordinator.delivered(take, handle: handle)
        await waitForObservation(coordinator)
    }

    /// Waits for the watch to end, but fails instead of hanging: a test whose
    /// clock is held never times the watch out on its own.
    private func waitForObservation(_ coordinator: DropLearningCoordinator,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let watched = Task { await coordinator.waitForObservation() }
        let deadline = Date().addingTimeInterval(5)
        while coordinator.isObserving, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        if coordinator.isObserving {
            XCTFail("the field is still watched", file: file, line: line)
            coordinator.stopWatching()
        }
        await watched.value
    }

    /// Lets the observation's first read run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: - Repeated correction

    func testOneCorrectionIsNotEnoughTheSecondBecomesAVocabSuggestion() async {
        let coordinator = makeCoordinator()
        let first = take(pasted: "Позвони клоду завтра")
        await run(coordinator, first, field: "Позвони Claude завтра")
        XCTAssertTrue(suggestions.isEmpty, "one edit can be a one-off")
        now += 86_400 * 3
        await run(coordinator, take(pasted: "Напиши клоду"), field: "Напиши Claude")
        XCTAssertEqual(suggestions, [DropLearningSuggestion(candidate: .vocabAdd(term: "Claude"), dryRun: false)])
    }

    func testAcceptingAVocabSuggestionSavesThroughTheVocabStoreAndAnOpenEditorSeesIt() async {
        let cache = VocabularyCache(defaults: defaults)
        let sharedEditor = IslandVocabularyViewModel(vocabulary: cache)
        await sharedEditor.loadIfNeeded()
        let coordinator = DropLearningCoordinator(dependencies: .init(
            fieldAccess: field, lexicon: FakeLexicon(), defaults: defaults, now: { [unowned self] in now },
            journal: DropLearningJournal(url: journalURL),
            lists: { DropLearningLists(vocabulary: cache.terms, fillers: [], replacements: []) },
            sleep: { _ in }, isIdle: { true }, openVocabulary: {},
            vocabulary: cache, fillers: FillerTermsStore(defaults: defaults),
            replacements: DropReplacementStore(defaults: defaults)
        ))
        coordinator.accept(DropLearningSuggestion(candidate: .vocabAdd(term: "Claude"), dryRun: false))
        XCTAssertEqual(cache.terms, ["Claude"])
        for _ in 0..<50 where sharedEditor.terms.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(sharedEditor.terms, ["Claude"], "the editor must not save over the new term later")
    }

    func testCorrectionsOutsideTheFourteenDayWindowDoNotAddUp() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        now += 86_400 * 15
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertTrue(suggestions.isEmpty)
    }

    /// Build 1722, Claude desktop: the provider wrote "Джефф" for "jev" and
    /// added a made-up tail. The user fixed the word, cut the tail and sent.
    /// Cutting the tail is not a rewrite, and the cut words are not part of
    /// the substitution; "Джефф" and "jev" sound alike (dzh = j, ff = v).
    func testFixingAWordAndCuttingAMadeUpTailCountsTheFix() async {
        let coordinator = makeCoordinator()
        await run(coordinator,
                  take(pasted: "Я думаю, что нам стоит подключить джефф-модели. Искусства и спорта. Есть ещё один способ заработать. Общественные работы."),
                  field: "Я думаю, что нам стоит подключить jev-модели.")
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "jev")), 1)
        await run(coordinator,
                  take(pasted: "Я думаю, что в этом направлении лучше использовать Джефф. Как, впрочем, и зовут"),
                  field: "Я думаю, что в этом направлении лучше использовать jev.")
        XCTAssertEqual(suggestions, [DropLearningSuggestion(candidate: .vocabAdd(term: "jev"), dryRun: false)])
        let stats = DropLearningStats(defaults: defaults).counts
        XCTAssertEqual(stats["end.cleared"], 2)
        XCTAssertEqual(stats["candidate.vocabAdd"], 2)
        XCTAssertEqual(stats["suggested"], 1)
        XCTAssertEqual(stats["cut.long"], 2, "both made-up tails are cuts, not edits")
    }

    /// The counters tell why nothing was learned, without any of the words.
    func testReasonCountersExplainARejectWithoutWords() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Позвони клоду завтра"), field: "Позвони маме завтра")
        let stats = DropLearningStats(defaults: defaults).counts
        XCTAssertEqual(stats["sub.notSoundAlike"], 1)
        XCTAssertEqual(stats["end.cleared"], 1)
        let text = String(describing: defaults.dictionary(forKey: DropLearningStats.key) ?? [:])
        for word in ["клоду", "маме", "Позвони", "завтра"] { XCTAssertFalse(text.contains(word), word) }
        XCTAssertNil(ConfigBackupRegistry.entries[DropLearningStats.key], "never in backup or sync")
    }

    func testSwitchingLearningOffDeletesTheCounters() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertFalse(DropLearningStats(defaults: defaults).counts.isEmpty)
        coordinator.settingsChanged()
        XCTAssertFalse(DropLearningStats(defaults: defaults).counts.isEmpty, "still on: kept")
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        coordinator.settingsChanged()
        XCTAssertTrue(DropLearningStats(defaults: defaults).counts.isEmpty)
    }

    /// Cutting most of a take and typing something else is still a rewrite.
    func testKeepingOneWordAndTypingAnotherMessageIsStillARewrite() async {
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "Позвони клоду завтра утром и скажи про отчёт"),
                      field: "Позвони мне когда сможешь")
        }
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testTheSameTakeCountsOnceEvenWithTwoCorrections() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "клоду и клоду"), field: "Claude и Claude")
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: - Filler

    func testDeletingTheSameFillerTwiceOffersToCutIt() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Типа я приду завтра"), field: "Я приду завтра")
        await run(coordinator, take(pasted: "Скажи типа привет"), field: "Скажи привет")
        XCTAssertEqual(suggestions.map(\.candidate), [.fillerAdd(term: "типа")])
    }

    func testTypingBackACutFillerOffersToStopCuttingIt() async {
        let coordinator = makeCoordinator()
        // Filler removed "типа" before paste; the user types it back.
        await run(coordinator, take(pasted: "Я приду завтра", raw: "типа я приду завтра", fillers: ["типа"]),
                  field: "Типа я приду завтра")
        await run(coordinator, take(pasted: "Скажи привет", raw: "скажи типа привет", fillers: ["типа"]),
                  field: "Скажи типа привет")
        XCTAssertEqual(suggestions.map(\.candidate), [.fillerRemove(term: "типа")])
    }

    func testDeletingAWordThatWasNeverSpokenIsNotAFiller() async {
        let coordinator = makeCoordinator()
        // Smart added "короче"; deleting it says nothing about the user's speech.
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "Короче я приду", raw: "я приду", mode: .smart), field: "Я приду")
        }
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: - Refusal

    func testNIsRememberedForever() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        let offered = try! XCTUnwrap(suggestions.first)
        coordinator.decline(offered)
        suggestions = []
        for day in 1...40 {
            now += 86_400 * Double(day % 3 == 0 ? 1 : 0)
            await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        }
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testIgnoredSuggestionStartsCountingOver() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        coordinator.expired(suggestions[0])
        suggestions = []
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertTrue(suggestions.isEmpty)
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertEqual(suggestions.count, 1)
    }

    // MARK: - Vocab limit and routes

    func testFullElevenLabsListOffersReplaceForANonWord() async {
        VocabularyCache(defaults: defaults).setTerms((1...50).map { "term\($0)" })
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "Позвони клоду", transport: .elevenLabsRealtime), field: "Позвони Claude")
        }
        XCTAssertEqual(suggestions.map(\.candidate), [.replaceAdd(DropReplacement(heard: "клоду", wanted: "Claude"))])
    }

    func testFullListWithADictionaryWordShowsTheLimitAndYOpensVocab() async {
        VocabularyCache(defaults: defaults).setTerms((1...50).map { "term\($0)" })
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "Отправь в кот", transport: .elevenLabsRealtime), field: "Отправь в Kotlin")
        }
        guard case .vocabFull(let term, let usage)? = suggestions.first?.candidate else {
            return XCTFail("expected Vocab full, got \(suggestions)")
        }
        XCTAssertEqual(term, "Kotlin")
        XCTAssertEqual(usage, VocabularyBudget.Usage(used: 50, limit: 50, unit: .terms))
        coordinator.accept(suggestions[0])
        XCTAssertEqual(vocabOpened, 1)
        XCTAssertEqual(VocabularyCache(defaults: defaults).terms.count, 50, "Y on a full list changes nothing")
    }

    func testOnThisMacOffersReplaceBecauseVocabNeverReachesIt() async {
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "Позвони клоду", transport: .none), field: "Позвони Claude")
        }
        XCTAssertEqual(suggestions.map(\.candidate), [.replaceAdd(DropReplacement(heard: "клоду", wanted: "Claude"))])
    }

    func testATermAlreadyInVocabThatStillFailsBecomesReplace() async {
        VocabularyCache(defaults: defaults).setTerms(["Claude"])
        let coordinator = makeCoordinator()
        for _ in 0..<2 { await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude") }
        XCTAssertEqual(suggestions.map(\.candidate), [.replaceAdd(DropReplacement(heard: "клоду", wanted: "Claude"))])
    }

    func testAVocabTermWrittenWhereItWasNotSaidOffersRemoval() async {
        VocabularyCache(defaults: defaults).setTerms(["Kotlin"])
        let coordinator = makeCoordinator()
        for _ in 0..<2 { await run(coordinator, take(pasted: "Отправь Kotlin"), field: "Отправь кот") }
        XCTAssertEqual(suggestions.map(\.candidate), [.vocabRemove(term: "Kotlin")])
    }

    func testUndoingOurReplacementOffersToRemoveIt() async {
        let rule = DropReplacement(heard: "клоду", wanted: "Claude")
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "Позвони Claude", raw: "позвони клоду", fired: [rule]), field: "Позвони Клоду")
        }
        XCTAssertEqual(suggestions.map(\.candidate), [.replaceRemove(rule)])
    }

    // MARK: - Smart and translation

    func testSmartOnlyErrorIsReplaceNotVocab() async {
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            // The provider heard "Claude"; Smart rewrote it.
            await run(coordinator, take(pasted: "Позвони клоду", raw: "позвони Claude", mode: .smart), field: "Позвони Claude")
        }
        XCTAssertEqual(suggestions.map(\.candidate), [.replaceAdd(DropReplacement(heard: "клоду", wanted: "Claude"))])
    }

    func testTranslatedTakesTeachNothing() async {
        let coordinator = makeCoordinator()
        for _ in 0..<3 {
            await run(coordinator, take(pasted: "Call clod tomorrow", raw: "позвони клоду завтра", mode: .smart, translated: true),
                      field: "Call Claude tomorrow")
        }
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 0)
    }

    func testGrammarFixesAndRewritesAreNotRecognitionErrors() async {
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "Позвони Севе"), field: "Позвони Севой")
            await run(coordinator, take(pasted: "Отправь отчёт"), field: "Отправь презентацию")
        }
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testAHeavyRewriteOfTheWholeTakeIsIgnored() async {
        let coordinator = makeCoordinator()
        for _ in 0..<2 { await run(coordinator, take(pasted: "Позвони клоду завтра"), field: "Совсем другой текст про Claude") }
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: - Field safety

    func testPasswordAndUnreadableFieldsAreNeverRead() {
        let base = DropEditFieldFacts(bundleID: "com.tinyspeck.slackmacgap", isOwnProcess: false, role: "AXTextArea",
                                      subrole: nil, secureEventInput: false, accessibilityError: false)
        XCTAssertTrue(DropEditFieldGate.allowsRead(base))
        var secure = base; secure.subrole = "AXSecureTextField"
        var secureInput = base; secureInput.secureEventInput = true
        var terminal = base; terminal.bundleID = "com.googlecode.iterm2"
        var manager = base; manager.bundleID = "com.1password.1password"
        var own = base; own.isOwnProcess = true
        var axError = base; axError.accessibilityError = true
        var webArea = base; webArea.role = "AXWebArea"
        var unknownApp = base; unknownApp.bundleID = nil
        var button = base; button.role = "AXButton"
        for facts in [secure, secureInput, terminal, manager, own, axError, webArea, unknownApp, button] {
            XCTAssertFalse(DropEditFieldGate.allowsRead(facts), "\(facts)")
        }
    }

    func testAFieldThatCannotBeCapturedIsNeverRead() async {
        field.capturable = false
        let coordinator = makeCoordinator()
        for _ in 0..<2 { await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude") }
        XCTAssertEqual(field.readCount, 0)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testAFieldFocusedDuringThePasteDelayIsNeverRead() async {
        field.focusMovedAfterCapture = true
        let coordinator = makeCoordinator()
        for _ in 0..<2 { await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude") }
        XCTAssertEqual(field.captureCount, 2, "captured before Cmd+V")
        XCTAssertEqual(field.readCount, 0)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testTurningLearningOffWhileAFieldIsWatchedStopsReadingAndCountsNothing() async {
        let coordinator = makeCoordinator(sleep: { [unowned self] _ in
            defaults.set(false, forKey: DropLearningSettings.enabledKey)
        })
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertEqual(field.readCount, 1, "no read after opt-out")
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key))
        XCTAssertTrue(field.watches.allSatisfy(\.cancelled))
    }

    /// On by default: a user who never touched the switch (no key) learns;
    /// one who switched it off stays off; switching it on again works.
    func testLearningIsOnUntilTheUserSwitchesItOff() async {
        defaults.removeObject(forKey: DropLearningSettings.enabledKey)
        XCTAssertTrue(DropLearningSettings.isEnabled(in: defaults))
        let coordinator = makeCoordinator()
        XCTAssertTrue(coordinator.capturesFields)
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        let reads = field.readCount
        XCTAssertGreaterThan(reads, 0)
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)

        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        XCTAssertFalse(DropLearningSettings.isEnabled(in: defaults))
        XCTAssertFalse(coordinator.capturesFields)
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertEqual(field.readCount, reads)

        defaults.set(true, forKey: DropLearningSettings.enabledKey)
        XCTAssertTrue(coordinator.capturesFields)
    }

    /// With learning and calibration off the paste engine gets no capture
    /// callback at all, so its ordinary path is unchanged.
    func testFieldsAreCapturedOnlyWhileLearningOrCalibrationIsOn() {
        let coordinator = makeCoordinator()
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        XCTAssertFalse(coordinator.capturesFields)
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        XCTAssertTrue(coordinator.capturesFields)
        defaults.set(false, forKey: DropLearningSettings.calibrationKey)
        defaults.set(true, forKey: DropLearningSettings.enabledKey)
        XCTAssertTrue(coordinator.capturesFields)
    }

    func testTurningCalibrationOffWhileAFieldIsWatchedStopsTheReadsAndJournal() async {
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator(sleep: { [unowned self] _ in
            defaults.set(false, forKey: DropLearningSettings.calibrationKey)
        })
        await run(coordinator, take(pasted: "Позвони клоду завтра"), field: "Позвони Claude завтра")
        XCTAssertEqual(field.readCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testTurningCalibrationOffBetweenReadsStopsBeforeTheJournalEntry() async throws {
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        var sleeps = 0
        let coordinator = makeCoordinator(sleep: { [unowned self] _ in
            sleeps += 1
            if sleeps == 3 { defaults.set(false, forKey: DropLearningSettings.calibrationKey) }
        })
        field.reads = ["Позвони клоду", "Позвони Cl", "Позвони Claude"]
        await runReads(coordinator, take(pasted: "Позвони клоду"))
        XCTAssertEqual(field.readCount, 3, "no read after opt-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path), "opt-out deletes the journal")
    }

    func testExpiredCalibrationIsCleanedWithoutAnotherDrop() {
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator()
        coordinator.performMaintenance()
        DropLearningJournal(url: journalURL).append(["event": "x"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        now += 86_400 * 14 + 1
        coordinator.performMaintenance()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertFalse(defaults.bool(forKey: DropLearningSettings.calibrationKey))
        XCTAssertEqual(field.captureCount, 0)
    }

    func testJournalMakesAnExistingFilePrivateBeforeWriting() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("prior data\n".utf8).write(to: journalURL)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journalURL.path)
        DropLearningJournal(url: journalURL).append(["synthetic": "private text"])
        let permissions = try manager.attributesOfItem(atPath: journalURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    /// A hard link would turn the journal write into a write to another
    /// named file: neither its text nor its mode may change.
    func testJournalNeverWritesThroughAHardLink() throws {
        let manager = FileManager.default
        let directory = journalURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let other = directory.appendingPathComponent("ordinary-document.txt")
        let original = Data("synthetic document".utf8)
        try original.write(to: other)
        try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: other.path)
        try manager.linkItem(at: other, to: journalURL)
        DropLearningJournal(url: journalURL).append(["synthetic": "private correction"])
        XCTAssertEqual(try Data(contentsOf: other), original)
        let permission = try manager.attributesOfItem(atPath: other.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permission?.intValue, 0o640)
    }

    func testJournalNeverFollowsALink() throws {
        let manager = FileManager.default
        let directory = journalURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let elsewhere = directory.appendingPathComponent("elsewhere.txt")
        try Data("other file\n".utf8).write(to: elsewhere)
        try manager.createSymbolicLink(at: journalURL, withDestinationURL: elsewhere)
        DropLearningJournal(url: journalURL).append(["synthetic": "private text"])
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "other file\n")
    }

    func testAFieldThatChangedOrClosedBeforeTheReadCountsNothing() async {
        let coordinator = makeCoordinator()
        for _ in 0..<3 { await run(coordinator, take(pasted: "Позвони клоду"), field: nil) }
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 0)
    }

    /// The field never showed the paste (it was sent before the first read,
    /// or the app keeps its text elsewhere): nothing is learned.
    func testAFieldThatNeverShowsThePasteCountsNothing() async {
        let coordinator = makeCoordinator()
        for _ in 0..<3 {
            field.reads = [""]
            await runReads(coordinator, take(pasted: "Позвони клоду"))
        }
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key))
        XCTAssertEqual(field.readCount, 3 * Int(DropLearningCoordinator.alignSeconds / DropLearningCoordinator.pollInterval),
                       "gives up 5 s after the paste")
    }

    // MARK: - Watching the field until it is sent

    /// The chat case (Claude, Slack, Telegram): the user fixes the word by
    /// hand and presses Return; the field empties as the message goes. The
    /// text before it emptied is what counts.
    func testFixingAWordAndSendingWithReturnCountsTheFix() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        for day in 0..<2 {
            now += 86_400 * Double(day)
            field.reads = ["Позвони клоду"]
            coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
            await settle()
            field.reads = ["Позвони Cl"]
            field.onChange?(.value)
            field.reads = ["Позвони Claude"]
            field.onChange?(.value)
            XCTAssertNotNil(pressReturn, "Return is watched only while a field is")
            field.reads = [""]
            pressReturn?()
            await waitForObservation(coordinator)
            XCTAssertNil(pressReturn, "the Return watch is removed with the observation")
        }
        XCTAssertEqual(suggestions, [DropLearningSuggestion(candidate: .vocabAdd(term: "Claude"), dryRun: false)])
        XCTAssertEqual(returnWatchStops, 2)
    }

    /// Return that only adds a line (Shift-Return, a notes app) keeps the
    /// field watched; it ends when the field empties later.
    func testReturnThatDoesNotSendKeepsWatching() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        field.reads = ["Позвони клоду"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        field.reads = ["Позвони Claude\n"]
        pressReturn?()
        await settle()
        XCTAssertNotNil(pressReturn, "still watching")
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 0)
        field.reads = [""]
        field.onChange?(.value)
        await waitForObservation(coordinator)
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)
    }

    /// The user fixes the word and clicks elsewhere (or the send button takes
    /// focus): the last text counts.
    func testLeavingTheFieldAfterTheFixCountsIt() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        field.reads = ["Позвони клоду"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        field.reads = ["Позвони Claude"]
        field.onChange?(.value)
        field.focusMovedAfterCapture = true
        field.onChange?(.focusLeft)
        await waitForObservation(coordinator)
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)
        XCTAssertTrue(field.watches.allSatisfy(\.cancelled))
    }

    func testAFieldThatGoesAwayAfterTheFixCountsIt() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        field.reads = ["Позвони клоду"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        field.reads = ["Позвони Claude"]
        field.onChange?(.value)
        field.onChange?(.removed)
        await waitForObservation(coordinator)
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)
    }

    /// The user deletes the take and writes another message: no correction.
    func testReplacingTheTakeWithAnotherMessageCountsNothing() async {
        let coordinator = makeCoordinator()
        field.reads = ["Позвони клоду", "Позвони Claude", "Совсем другое сообщение без этой фразы вообще"]
        await runReads(coordinator, take(pasted: "Позвони клоду"))
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key))
    }

    /// A field nobody sends (a document) is watched for 2 minutes at most.
    func testAFieldIsWatchedForTwoMinutesAtMost() async {
        let coordinator = makeCoordinator()
        field.reads = ["Позвони клоду", "Позвони Claude"]
        await runReads(coordinator, take(pasted: "Позвони клоду"))
        XCTAssertEqual(field.readCount, Int(DropLearningCoordinator.maxObserveSeconds / DropLearningCoordinator.pollInterval))
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)
        XCTAssertTrue(field.watches.allSatisfy(\.cancelled))
    }

    /// The next take counts what the field holds before its paste lands.
    func testANewTakeCountsTheWatchedFieldBeforeItsPaste() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        field.reads = ["Позвони клоду"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 1))
        await settle()
        field.reads = ["Позвони Claude"]
        field.onChange?(.value)
        let reads = field.readCount
        coordinator.takeStarted(targetPID: 1)
        await waitForObservation(coordinator)
        XCTAssertEqual(field.readCount, reads, "nothing is read after the new take starts")
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)
    }

    // MARK: - What a watch may trust

    /// Still focused but no longer readable (an AX error, the gate now says
    /// no, the text grew past the bound): the text kept earlier is dropped.
    func testAnUnreadableStillFocusedFieldDoesNotCountTheKeptEdit() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        for _ in 0..<2 {
            field.reads = ["Позвони клоду"]
            coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
            await settle()
            field.reads = ["Позвони Claude"]
            field.onChange?(.value)
            field.reads = [nil]
            field.onChange?(.value)
            await waitForObservation(coordinator)
        }
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 0)
        XCTAssertTrue(field.watches.allSatisfy(\.cancelled))
    }

    /// The deadline is the clock, not a count of polls: a poll that is late
    /// does not let a notification read past 2 minutes.
    func testTheTwoMinuteDeadlineHoldsForNotificationsEvenIfThePollIsLate() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        field.reads = ["Позвони клоду"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        XCTAssertEqual(field.readCount, 1)
        now += DropLearningCoordinator.maxObserveSeconds + 1
        field.reads = ["Позвони Claude"]
        field.onChange?(.value)
        pressReturn?()
        XCTAssertEqual(field.readCount, 1, "no read after the deadline")
        XCTAssertTrue(field.watches.allSatisfy(\.cancelled))
        XCTAssertNil(pressReturn)
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 0)
    }

    /// No paste seen 5 s after delivery: a late notification reads nothing.
    func testTheAlignDeadlineHoldsForNotificationsToo() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        field.reads = [""]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        now += DropLearningCoordinator.alignSeconds
        field.reads = ["Позвони Claude"]
        field.onChange?(.value)
        XCTAssertEqual(field.readCount, 1)
        XCTAssertTrue(field.watches.allSatisfy(\.cancelled))
    }

    /// The field already held the corrected text (a draft), and the paste
    /// never landed: no edit was made during the watch, nothing counts.
    func testTextAlreadyInTheFieldIsNotTheUsersEdit() async {
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            field.reads = ["Позвони Claude", ""]
            await runReads(coordinator, take(pasted: "Позвони клоду"))
        }
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 0)
    }

    /// Only the corrections made during the watch count, not the ones that
    /// were already there when the paste showed up.
    func testOnlyTheCorrectionMadeDuringTheWatchCounts() async {
        let coordinator = makeCoordinator()
        field.reads = ["Позвони Claude завтра", "Позвони Claude в код", ""]
        await runReads(coordinator, take(pasted: "Позвони клоду завтра"))
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 0)
    }

    // MARK: - Electron and web fields

    /// An Electron or web app gets its fields exposed when the take starts
    /// (so the field can be captured at the paste) and turned off again when
    /// the field is no longer watched.
    func testAnAppAskedToExposeItsFieldsIsRestoredAfterTheObservation() async {
        field.needsExposure = true
        let coordinator = makeCoordinator(sleep: Self.held)
        coordinator.takeStarted(targetPID: 4242)
        XCTAssertEqual(field.exposed, 1)
        field.reads = ["Позвони клоду"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        XCTAssertEqual(field.released, 0, "on while the field is watched")
        field.reads = [""]
        field.onChange?(.value)
        await waitForObservation(coordinator)
        XCTAssertEqual(field.released, 1)
    }

    func testATakeThatIsNeverPastedTurnsTheExposureOff() async {
        field.needsExposure = true
        let coordinator = makeCoordinator()
        coordinator.takeStarted(targetPID: 4242)
        await settle()
        XCTAssertEqual(field.released, 1, "after the longest take, with no paste")
        coordinator.takeStarted(targetPID: 4242)
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: nil)
        XCTAssertEqual(field.released, 2, "no field to watch: off at once")
    }

    func testTheSameAppIsNotExposedAgainForTheNextTake() async {
        field.needsExposure = true
        let coordinator = makeCoordinator(sleep: Self.held)
        coordinator.takeStarted(targetPID: 4242)
        field.reads = ["Позвони Claude"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        coordinator.takeStarted(targetPID: 4242)
        XCTAssertEqual(field.exposed, 1)
        XCTAssertEqual(field.released, 0, "kept for the next take into the same app")
        coordinator.takeStarted(targetPID: 5151)
        XCTAssertEqual(field.released, 1)
    }

    /// Quitting Whytap mid-watch: the app's tree is turned off, nothing counts.
    func testQuittingMidWatchUndoesTheExposureAndCountsNothing() async {
        field.needsExposure = true
        let coordinator = makeCoordinator(sleep: Self.held)
        coordinator.takeStarted(targetPID: 4242)
        field.reads = ["Позвони Claude"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        coordinator.stopWatching()
        XCTAssertEqual(field.released, 1)
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key))
        XCTAssertNil(pressReturn)
    }

    /// Switching learning off releases the exposure at once, even before
    /// the paste (the take is still being recorded).
    func testSwitchingLearningOffReleasesTheExposureBeforeThePaste() {
        field.needsExposure = true
        let coordinator = makeCoordinator(sleep: Self.held)
        coordinator.takeStarted(targetPID: 4242)
        XCTAssertEqual(field.exposed, 1)
        coordinator.settingsChanged()
        XCTAssertEqual(field.released, 0, "still on: nothing to release")
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        coordinator.settingsChanged()
        XCTAssertEqual(field.released, 1)
        XCTAssertNil(coordinator.prepareDelivery(targetPID: 4242))
    }

    func testSwitchingLearningOffMidWatchEndsItAndReleases() async {
        field.needsExposure = true
        let coordinator = makeCoordinator(sleep: Self.held)
        coordinator.takeStarted(targetPID: 4242)
        field.reads = ["Позвони клоду"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        field.reads = ["Позвони Claude"]
        field.onChange?(.value)
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        coordinator.settingsChanged()
        XCTAssertEqual(field.released, 1)
        XCTAssertTrue(field.watches.allSatisfy(\.cancelled))
        XCTAssertNil(pressReturn)
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key))
    }

    func testNothingIsExposedWhileLearningIsOff() {
        field.needsExposure = true
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        let coordinator = makeCoordinator()
        coordinator.takeStarted(targetPID: 4242)
        XCTAssertEqual(field.exposed, 0)
    }

    func testDisabledFeatureCapturesNothing() async {
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        let coordinator = makeCoordinator()
        for _ in 0..<2 { await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude") }
        XCTAssertEqual(field.readCount, 0)
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key))
    }

    func testASuggestionNeverAppearsOverAnotherTakeAndWaitsForTheNextOne() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        idle = false
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertTrue(suggestions.isEmpty)
        idle = true
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertEqual(suggestions.count, 1)
    }

    // MARK: - Storage

    func testTheLedgerStoresNoWords() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        let stored = try! XCTUnwrap(defaults.data(forKey: DropLearningLedger.key))
        let text = String(decoding: stored, as: UTF8.self)
        for word in ["Claude", "клоду", "vocab", "Позвони"] { XCTAssertFalse(text.contains(word), word) }
        XCTAssertNil(ConfigBackupRegistry.entries[DropLearningLedger.key], "never in backup or sync")
    }

    // MARK: - Calibration

    /// Calibration with learning on is the developer journal: real learning
    /// goes on (the suggestion is real) and every take gets an entry with the
    /// app, how the watch ended, every refusal reason and the edited words.
    func testCalibrationWithLearningOnJournalsBesideRealLearning() async throws {
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator()
        await run(coordinator,
                  take(pasted: "Я думаю, что нам стоит подключить джефф-модели. Искусства и спорта. Есть ещё один способ заработать."),
                  field: "Я думаю, что нам стоит подключить jev-модели.")
        await run(coordinator, take(pasted: "Лучше использовать Джефф. Как, впрочем, и зовут"), field: "Лучше использовать jev.")
        field.capturable = false
        await run(coordinator, take(pasted: "Пароль"), field: "Пароль")
        XCTAssertEqual(suggestions, [DropLearningSuggestion(candidate: .vocabAdd(term: "jev"), dryRun: false)])
        let lines = try String(contentsOf: journalURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        let entries = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(entries[0]["app"] as? String, "com.anthropic.claudefordesktop")
        XCTAssertEqual(entries[0]["reason"] as? String, "cleared")
        XCTAssertEqual(entries[0]["dryRun"] as? Bool, false)
        XCTAssertEqual(entries[0]["counts"] as? [Int], [1])
        XCTAssertTrue((entries[0]["notes"] as? [String])?.contains("cut.long") == true)
        XCTAssertTrue(lines[0].contains("jev"), "the developer journal keeps the edited words")
        XCTAssertEqual(entries[1]["shown"] as? String, "suggested")
        XCTAssertEqual(entries[2]["event"] as? String, "skipped")
        XCTAssertEqual(entries[2]["reason"] as? String, "secureField")
        XCTAssertEqual(DropLearningStats(defaults: defaults).counts["field.secureField"], 1)
    }

    /// Without calibration nothing is journaled, whatever happens.
    func testWithoutCalibrationNothingIsJournaled() async {
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        field.capturable = false
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testCalibrationWatchesTheFieldJournalsAndSavesNothing() async throws {
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            field = FakeField()
            field.reads = ["Позвони клоду", "Позвони Cl", "Позвони Claude", ""]
            let rebuilt = makeCoordinator()
            await runReads(rebuilt, take(pasted: "Позвони клоду"))
        }
        _ = coordinator
        XCTAssertEqual(suggestions, [DropLearningSuggestion(candidate: .vocabAdd(term: "Claude"), dryRun: true)])
        XCTAssertEqual(field.readCount, 4, "read until the field emptied")
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key), "the real counters are untouched")
        makeCoordinator().accept(suggestions[0])
        XCTAssertEqual(VocabularyCache(defaults: defaults).terms, [], "dry run")
        let journal = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertTrue(journal.contains("\"reason\":\"cleared\""))
        XCTAssertTrue(journal.contains("\"event\":\"observed\""))
        let attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCalibrationEndsItselfAfterFourteenDaysAndDeletesItsData() async {
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let journal = DropLearningJournal(url: journalURL)
        journal.append(["event": "x"])
        var settings = DropLearningSettings(defaults: defaults, now: { [unowned self] in now }, journal: journal)
        XCTAssertTrue(settings.isCalibrating())
        defaults.set(Data([1]), forKey: DropLearningSettings.calibrationLedgerKey)
        now += 86_400 * 14 + 1
        settings = DropLearningSettings(defaults: defaults, now: { [unowned self] in now }, journal: journal)
        XCTAssertFalse(settings.isCalibrating())
        XCTAssertFalse(defaults.bool(forKey: DropLearningSettings.calibrationKey))
        XCTAssertNil(defaults.object(forKey: DropLearningSettings.calibrationLedgerKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }
}

// MARK: - Builder review #449 scenarios


private final class NoDropKeys: DropLearningKeyCapturing {
    func start(onAnswer: @escaping @MainActor (DropLearningDropsModel.Button) -> Void,
               onControl: @escaping @MainActor (Bool) -> Void) {}
    func stop() {}
}

extension DropLearningScenarioTests {
    func testAFixNextToACutHeadCounts() async {
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "made up filler tokens Jeb keep model"), field: "Jev keep model")
        }
        XCTAssertEqual(suggestions.map(\.candidate), [.vocabAdd(term: "Jev")])
    }

    func testDeletingTheWholeTakeTeachesNothingFromTheDraftAroundIt() async {
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator()
        let original = "Open Kepler Jeb"
        let draft = "Kepler Jev needs another report"
        for _ in 0..<2 {
            field.reads = [original + " " + draft, draft, ""]
            await runReads(coordinator, take(pasted: original))
        }
        XCTAssertTrue(suggestions.isEmpty)
        let log = try? String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertFalse(log?.contains("Jev") ?? false, "no correction words come from a surviving draft")
    }

    func testAFixBeforeACutTailInsideADraftCounts() async {
        let coordinator = makeCoordinator()
        let original = "keep model Jeb made up filler tokens"
        for _ in 0..<2 {
            field.reads = ["earlier note " + original + " following draft sentence",
                           "earlier note keep model Jev following draft sentence", ""]
            await runReads(coordinator, take(pasted: original))
        }
        XCTAssertEqual(suggestions.map(\.candidate), [.vocabAdd(term: "Jev")])
    }

    func testUndoingAWholeHyphenatedRuleOffersItsRemoval() async {
        let oldRule = DropReplacement(heard: "geff-model", wanted: "jev-model")
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            await run(coordinator,
                      take(pasted: "Keep jev-model here", raw: "Keep geff-model here", fired: [oldRule]),
                      field: "Keep geff-model here")
        }
        XCTAssertEqual(suggestions.map(\.candidate), [.replaceRemove(oldRule)])
    }

    func testUndoingAWholeHyphenatedVocabTermOffersItsRemoval() async {
        VocabularyCache(defaults: defaults).add("jev-model")
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "Keep jev-model here"), field: "Keep geff-model here")
        }
        XCTAssertEqual(suggestions.map(\.candidate), [.vocabRemove(term: "jev-model")])
    }

    func testCountersSayNotShownWhenAnAgentAnswerHidesTheDrops() async throws {
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator()
        let model = DropLearningDropsModel(schedule: { _, _ in {} })
        let controller = DropLearningDropsController(
            coordinator: coordinator, model: model, keys: NoDropKeys(), present: { _ in },
            phase: Just(AppPhase.idle).eraseToAnyPublisher(),
            agentPhase: Just(AgentPhase.idle).eraseToAnyPublisher(),
            agentAnswerVisible: Just(true).eraseToAnyPublisher()
        )
        for _ in 0..<2 {
            await run(coordinator, take(pasted: "Open model Jeb"), field: "Open model Jev")
        }
        withExtendedLifetime(controller) { XCTAssertFalse(model.isVisible) }
        let text = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertFalse(text.contains("\"shown\":\"suggested\""))
        XCTAssertNil(DropLearningStats(defaults: defaults).counts["suggested"], "no UI was visible")
    }

    func testRefusedDeletionsAndInsertionsHaveReasons() async throws {
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator()
        await run(coordinator, take(pasted: "Open model 42 today"), field: "Open model today")
        await run(coordinator, take(pasted: "Open model today"), field: "Open next model today")
        let log = try String(contentsOf: journalURL, encoding: .utf8).split(separator: "\n")
        for line in log {
            let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let notes = try XCTUnwrap(entry["notes"] as? [String])
            XCTAssertGreaterThan(notes.count, 1, "a changed hunk failed a classifier gate; the log must say why")
        }
    }

    func testAReadableFieldWithoutThePasteIsReadableButNotAligned() async throws {
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator()
        field.reads = ["The editor is open and readable"]
        await runReads(coordinator, take(pasted: "Open model Jeb"))
        let text = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"reason\":\"notPasted\""))
        XCTAssertTrue(text.contains("\"readable\":true"), "the field transfer succeeded; alignment failed")
    }
}

extension DropLearningScenarioTests {
    func testAnAbandonedCaptureNeverExplainsALaterDelivery() async throws {
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator()
        field.capturable = false
        _ = coordinator.prepareDelivery(targetPID: 4242)
        // The first paste aborts after its capture hook. The next delivery
        // had no hook (the preference was off at dispatch), then it enables.
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        defaults.set(false, forKey: DropLearningSettings.calibrationKey)
        coordinator.takeStarted(targetPID: 4343)
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        coordinator.delivered(take(pasted: "Open model Jeb"), handle: nil)
        let text = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"reason\":\"noCapture\""))
        XCTAssertFalse(text.contains("\"reason\":\"secureField\""))
    }
}

extension DropLearningScenarioTests {
    func testAnEditSeenWhileCalibrationWasOffIsNeverJournaled() async throws {
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator(sleep: Self.held)
        let original = "Open model Jeb"
        field.reads = [original]
        let handle = coordinator.prepareDelivery(targetPID: 4242)
        coordinator.delivered(take(pasted: original), handle: handle)
        await settle()
        defaults.set(false, forKey: DropLearningSettings.calibrationKey)
        coordinator.settingsChanged()
        field.reads = ["Open model Jev"]
        field.onChange?(.value)
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        coordinator.settingsChanged()
        field.reads = [""]
        field.onChange?(.value)
        await waitForObservation(coordinator)
        let text = (try? String(contentsOf: journalURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("Jev"), "edits observed while calibration was off must not be journaled")
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Jev")), 1,
                       "ordinary learning remains enabled")
    }
}
