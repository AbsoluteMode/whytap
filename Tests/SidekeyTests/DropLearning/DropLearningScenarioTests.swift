import ApplicationServices
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
        /// The user moved to another field during the paste delay.
        var focusMovedAfterCapture = false
        /// What the field holds at each read, in order; the last value repeats.
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

        func capture(pid: pid_t) -> DropEditFieldHandle? {
            captureCount += 1
            return capturable ? DropEditFieldHandle(pid: pid, element: AXUIElementCreateApplication(pid)) : nil
        }
        func isStillFocused(_ handle: DropEditFieldHandle) -> Bool { !focusMovedAfterCapture }
        func read(_ handle: DropEditFieldHandle) -> String? {
            readCount += 1
            guard !reads.isEmpty else { return nil }
            defer { position = min(position + 1, reads.count - 1) }
            return reads[position]
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
            sleep: sleep,
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
            }
        ))
        coordinator.onSuggestion = { [unowned self] in suggestions.append($0) }
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

    /// The user leaves `text` in the field and sends it: the field empties.
    private func run(_ coordinator: DropLearningCoordinator, _ take: DropLearningTake, field text: String?) async {
        field.reads = text.map { [$0, ""] } ?? [nil]
        await runReads(coordinator, take)
    }

    private func runReads(_ coordinator: DropLearningCoordinator, _ take: DropLearningTake) async {
        let handle = coordinator.prepareDelivery(targetPID: 4242)
        coordinator.delivered(take, handle: handle)
        await coordinator.waitForObservation()
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
            await coordinator.waitForObservation()
            XCTAssertNil(pressReturn, "the Return watch is removed with the observation")
        }
        XCTAssertEqual(suggestions, [DropLearningSuggestion(candidate: .vocabAdd(term: "Claude"), dryRun: false)])
        XCTAssertEqual(returnWatchStops, 2)
    }

    /// Return that only adds a line (Shift-Return, a notes app) keeps the
    /// field watched; it ends when the field empties later.
    func testReturnThatDoesNotSendKeepsWatching() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        field.reads = ["Позвони Claude"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        field.reads = ["Позвони Claude\n"]
        pressReturn?()
        await settle()
        XCTAssertNotNil(pressReturn, "still watching")
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 0)
        field.reads = [""]
        field.onChange?(.value)
        await coordinator.waitForObservation()
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
        field.reads = [nil]
        field.onChange?(.focusLeft)
        await coordinator.waitForObservation()
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)
        XCTAssertTrue(field.watches.allSatisfy(\.cancelled))
    }

    func testAFieldThatGoesAwayAfterTheFixCountsIt() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        field.reads = ["Позвони Claude"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        field.onChange?(.removed)
        await coordinator.waitForObservation()
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)
    }

    /// The user deletes the take and writes another message: no correction.
    func testReplacingTheTakeWithAnotherMessageCountsNothing() async {
        let coordinator = makeCoordinator()
        field.reads = ["Позвони Claude", "Совсем другое сообщение без этой фразы вообще"]
        await runReads(coordinator, take(pasted: "Позвони клоду"))
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key))
    }

    /// A field nobody sends (a document) is watched for 2 minutes at most.
    func testAFieldIsWatchedForTwoMinutesAtMost() async {
        let coordinator = makeCoordinator()
        field.reads = ["Позвони Claude"]
        await runReads(coordinator, take(pasted: "Позвони клоду"))
        XCTAssertEqual(field.readCount, Int(DropLearningCoordinator.maxObserveSeconds / DropLearningCoordinator.pollInterval))
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)
        XCTAssertTrue(field.watches.allSatisfy(\.cancelled))
    }

    /// The next take counts what the field holds before its paste lands.
    func testANewTakeCountsTheWatchedFieldBeforeItsPaste() async {
        let coordinator = makeCoordinator(sleep: Self.held)
        field.reads = ["Позвони Claude"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 1))
        await settle()
        let reads = field.readCount
        coordinator.takeStarted(targetPID: 1)
        await coordinator.waitForObservation()
        XCTAssertEqual(field.readCount, reads, "nothing is read after the new take starts")
        XCTAssertEqual(DropLearningLedger(defaults: defaults).count(.vocabAdd(term: "Claude")), 1)
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
        field.reads = ["Позвони Claude"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 4242))
        await settle()
        XCTAssertEqual(field.released, 0, "on while the field is watched")
        field.reads = [""]
        field.onChange?(.value)
        await coordinator.waitForObservation()
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
