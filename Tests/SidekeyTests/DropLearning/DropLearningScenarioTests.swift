import ApplicationServices
import XCTest
@testable import Sidekey

/// User scenarios for learning from edits after Drop: a take is pasted, the
/// user corrects the field, the read 5 s later finds the correction.
@MainActor
final class DropLearningScenarioTests: XCTestCase {
    private final class FakeField: DropEditFieldAccess {
        var capturable = true
        /// The user moved to another field during the paste delay.
        var focusMovedAfterCapture = false
        /// What each read returns, in order; the last value repeats.
        var reads: [String?] = []
        private(set) var readCount = 0
        private(set) var captureCount = 0
        func capture(pid: pid_t) -> DropEditFieldHandle? {
            captureCount += 1
            return capturable ? DropEditFieldHandle(pid: pid, element: AXUIElementCreateApplication(pid)) : nil
        }
        func isStillFocused(_ handle: DropEditFieldHandle) -> Bool { !focusMovedAfterCapture }
        func read(_ handle: DropEditFieldHandle) -> String? {
            defer { readCount += 1 }
            guard !reads.isEmpty else { return nil }
            return reads[min(readCount, reads.count - 1)]
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
            replacements: DropReplacementStore(defaults: defaults)
        ))
        coordinator.onSuggestion = { [unowned self] in suggestions.append($0) }
        return coordinator
    }

    private func take(
        pasted: String, raw: String? = nil, mode: TranscriptionMode = .fast, translated: Bool = false,
        fired: [DropReplacement] = [], fillers: [String] = [], transport: VocabularyTransport = .deepgram
    ) -> DropLearningTake {
        DropLearningTake(pasted: pasted, raw: raw ?? pasted, mode: mode, translated: translated,
                         firedReplacements: fired, firedFillers: fillers, vocabTransport: transport)
    }

    private func run(_ coordinator: DropLearningCoordinator, _ take: DropLearningTake, field text: String?) async {
        field.reads = [text]
        await runReads(coordinator, take)
    }

    private func runReads(_ coordinator: DropLearningCoordinator, _ take: DropLearningTake) async {
        let handle = coordinator.prepareDelivery(targetPID: 4242)
        coordinator.delivered(take, handle: handle)
        await coordinator.waitForPendingRead()
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

    func testTurningLearningOffDuringTheDelayStopsTheRead() async {
        let coordinator = makeCoordinator(sleep: { [unowned self] _ in
            defaults.set(false, forKey: DropLearningSettings.enabledKey)
        })
        await run(coordinator, take(pasted: "Позвони клоду"), field: "Позвони Claude")
        XCTAssertEqual(field.readCount, 0)
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key))
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

    func testTurningCalibrationOffDuringTheDelayStopsTheReadAndJournal() async {
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator(sleep: { [unowned self] _ in
            defaults.set(false, forKey: DropLearningSettings.calibrationKey)
        })
        await run(coordinator, take(pasted: "Позвони клоду завтра"), field: "Позвони Claude завтра")
        XCTAssertEqual(field.readCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testTurningCalibrationOffBetweenReadsStopsBeforeTheSettledEntry() async throws {
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        var sleeps = 0
        let coordinator = makeCoordinator(sleep: { [unowned self] _ in
            sleeps += 1
            if sleeps == 3 { defaults.set(false, forKey: DropLearningSettings.calibrationKey) }
        })
        field.reads = ["Позвони клоду", "Позвони Cl", "Позвони Claude"]
        await runReads(coordinator, take(pasted: "Позвони клоду"))
        XCTAssertEqual(field.readCount, 2, "no read after opt-out")
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

    func testAnEmptiedFieldAfterSendCountsNothing() async {
        let coordinator = makeCoordinator()
        for _ in 0..<3 { await run(coordinator, take(pasted: "Позвони клоду"), field: "") }
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testANewTakeCancelsThePendingRead() async {
        var release: CheckedContinuation<Void, Never>?
        let coordinator = DropLearningCoordinator(dependencies: .init(
            fieldAccess: field, lexicon: FakeLexicon(), defaults: defaults, now: { Date() },
            journal: DropLearningJournal(url: journalURL),
            lists: { DropLearningLists(vocabulary: [], fillers: [], replacements: []) },
            sleep: { _ in await withCheckedContinuation { release = $0 } },
            isIdle: { true }, openVocabulary: {},
            vocabulary: VocabularyCache(defaults: defaults), fillers: FillerTermsStore(defaults: defaults),
            replacements: DropReplacementStore(defaults: defaults)
        ))
        field.reads = ["Позвони Claude"]
        coordinator.delivered(take(pasted: "Позвони клоду"), handle: coordinator.prepareDelivery(targetPID: 1))
        await Task.yield()
        coordinator.takeStarted()
        release?.resume()
        await coordinator.waitForPendingRead()
        XCTAssertEqual(field.readCount, 0)
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

    func testCalibrationReadsUntilTheFieldSettlesJournalsAndSavesNothing() async throws {
        defaults.set(false, forKey: DropLearningSettings.enabledKey)
        defaults.set(true, forKey: DropLearningSettings.calibrationKey)
        let coordinator = makeCoordinator()
        for _ in 0..<2 {
            field = FakeField()
            field.reads = ["Позвони клоду", "Позвони Cl", "Позвони Claude"]
            let rebuilt = makeCoordinator()
            await runReads(rebuilt, take(pasted: "Позвони клоду"))
        }
        _ = coordinator
        XCTAssertEqual(suggestions, [DropLearningSuggestion(candidate: .vocabAdd(term: "Claude"), dryRun: true)])
        XCTAssertGreaterThan(field.readCount, 3, "kept reading until stable")
        XCTAssertNil(defaults.data(forKey: DropLearningLedger.key), "the real counters are untouched")
        makeCoordinator().accept(suggestions[0])
        XCTAssertEqual(VocabularyCache(defaults: defaults).terms, [], "dry run")
        let journal = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertTrue(journal.contains("missedByFirstRead"))
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
