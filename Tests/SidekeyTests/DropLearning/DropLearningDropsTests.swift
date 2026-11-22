import AppKit
import Carbon.HIToolbox
import SwiftUI
import Combine
import XCTest
@testable import Sidekey

/// A manual clock for the drops: scheduled work runs only when time is moved.
@MainActor
private final class FakeClock {
    struct Item { let id: Int; let at: TimeInterval; let work: @MainActor () -> Void }
    var time: TimeInterval = 0
    private var items: [Item] = []
    private var nextID = 0

    var now: Date { Date(timeIntervalSince1970: time) }

    func schedule(_ after: TimeInterval, _ work: @escaping @MainActor () -> Void) -> DropLearningDropsModel.Cancel {
        nextID += 1
        let id = nextID
        items.append(Item(id: id, at: time + after, work: work))
        return { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    func advance(_ seconds: TimeInterval) {
        let end = time + seconds
        while let next = items.filter({ $0.at <= end + 1e-9 }).min(by: { $0.at < $1.at }) {
            items.removeAll { $0.id == next.id }
            time = next.at
            next.work()
        }
        time = end
    }
}

@MainActor
private final class FakeKeys: DropLearningKeyCapturing {
    var started = 0
    var stopped = 0
    var capturing = false
    var onAnswer: ((DropLearningDropsModel.Button) -> Void)?
    var onControl: ((Bool) -> Void)?

    func start(onAnswer: @escaping @MainActor (DropLearningDropsModel.Button) -> Void,
               onControl: @escaping @MainActor (Bool) -> Void) {
        started += 1
        capturing = true
        self.onAnswer = onAnswer
        self.onControl = onControl
    }

    func stop() {
        stopped += 1
        capturing = false
    }
}

@MainActor
final class DropLearningDropsTests: XCTestCase {
    private var clock: FakeClock!
    private var reduceMotion = false
    private var outcomes: [(DropLearningCandidate, DropLearningDropsModel.Outcome)] = []
    private var visibility: [Bool] = []

    private let whytap = DropLearningSuggestion(candidate: .vocabAdd(term: "Whytap"), dryRun: false)
    private let typa = DropLearningSuggestion(candidate: .fillerRemove(term: "типа"), dryRun: false)

    override func setUp() {
        super.setUp()
        clock = FakeClock()
        reduceMotion = false
        outcomes = []
        visibility = []
    }

    private func model() -> DropLearningDropsModel {
        let model = DropLearningDropsModel(
            schedule: { [unowned self] in clock.schedule($0, $1) },
            now: { [unowned self] in clock.now },
            reduceMotion: { [unowned self] in reduceMotion }
        )
        model.onOutcome = { [unowned self] in outcomes.append(($0.candidate, $1)) }
        model.onVisibleChange = { [unowned self] in visibility.append($0) }
        return model
    }

    // MARK: - Chain and timing

    func testTheChainBudsOneDropAfterAnotherAndOpensUnderEightTenthsOfASecond() {
        let model = model()
        XCTAssertTrue(model.show(whytap))
        XCTAssertEqual(model.stage, .emerging)
        XCTAssertEqual(model.dropsOut, 1)
        XCTAssertEqual(visibility, [true])
        clock.advance(0.1); XCTAssertEqual(model.dropsOut, 2)
        clock.advance(0.1); XCTAssertEqual(model.dropsOut, 3)
        clock.advance(0.1); XCTAssertEqual(model.dropsOut, 4)
        clock.advance(0.4)
        XCTAssertEqual(model.stage, .open)
        XCTAssertLessThan(clock.time, 0.8)
    }

    func testAfterTenSecondsWithoutHoverTheDropsRetractInReverseAndCountAsLetGo() {
        let model = model()
        model.show(whytap)
        clock.advance(0.7)
        clock.advance(9.9)
        XCTAssertEqual(model.stage, .open)
        clock.advance(0.1)
        XCTAssertEqual(outcomes.map(\.1), [.expired])
        XCTAssertEqual(model.stage, .retracting)
        XCTAssertEqual(model.dropsOut, 3, "N goes first")
        clock.advance(0.1); XCTAssertEqual(model.dropsOut, 2)
        clock.advance(0.1); XCTAssertEqual(model.dropsOut, 1)
        clock.advance(0.1); XCTAssertEqual(model.dropsOut, 0)
        clock.advance(0.3)
        XCTAssertEqual(model.stage, .hidden)
        XCTAssertEqual(visibility, [true, false])
        XCTAssertNil(model.content)
    }

    func testHoveringPausesTheTenSecondsAndLeavingResumesWhatWasLeft() {
        let model = model()
        model.show(whytap)
        clock.advance(0.7)
        clock.advance(4)
        model.setHovered(true)
        clock.advance(60)
        XCTAssertEqual(model.stage, .open)
        XCTAssertTrue(outcomes.isEmpty)
        model.setHovered(false)
        clock.advance(5.9)
        XCTAssertEqual(model.stage, .open)
        clock.advance(0.2)
        XCTAssertEqual(outcomes.map(\.1), [.expired])
    }

    func testHoveringWhileTheChainBudsKeepsTheTimerPausedOnceOpen() {
        let model = model()
        model.show(whytap)
        model.setHovered(true)
        clock.advance(30)
        XCTAssertEqual(model.stage, .open)
        XCTAssertTrue(outcomes.isEmpty)
    }

    // MARK: - Answers

    func testYesAcceptsOnceConfirmsOnTheIconAndRetracts() {
        let model = model()
        model.show(whytap)
        clock.advance(0.7)
        model.answer(.yes)
        model.answer(.yes)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.1, .accepted)
        XCTAssertEqual(model.stage, .confirming)
        XCTAssertTrue(model.confirmed)
        clock.advance(0.55)
        XCTAssertEqual(model.stage, .retracting)
        clock.advance(1)
        XCTAssertEqual(model.stage, .hidden)
        XCTAssertEqual(outcomes.count, 1, "no expiry after an answer")
    }

    func testNoDeclinesAndRetractsAtOnce() {
        let model = model()
        model.show(typa)
        clock.advance(0.7)
        model.answer(.no)
        XCTAssertEqual(outcomes.map(\.1), [.declined])
        XCTAssertEqual(model.stage, .retracting)
        clock.advance(20)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testAnswersBeforeTheDropsAreOpenAreIgnored() {
        let model = model()
        model.show(whytap)
        model.answer(.yes)
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(model.stage, .emerging)
    }

    func testControlLightsYAndNOnlyWhileOpen() {
        let model = model()
        model.show(whytap)
        model.setControlHeld(true)
        XCTAssertFalse(model.controlHeld)
        clock.advance(0.7)
        model.setControlHeld(true)
        XCTAssertTrue(model.controlHeld)
        model.answer(.no)
        XCTAssertFalse(model.controlHeld)
    }

    // MARK: - One at a time, busy island

    func testASecondSuggestionWhileOneIsShownIsNotShown() {
        let model = model()
        model.show(whytap)
        XCTAssertFalse(model.show(typa))
        XCTAssertEqual(model.suggestion?.candidate, whytap.candidate)
    }

    func testABusyIslandPutsTheDropsOutAtOnceAndLetsTheSuggestionGo() {
        let model = model()
        model.show(whytap)
        clock.advance(0.7)
        model.dismissForBusyIsland()
        XCTAssertEqual(model.stage, .hidden)
        XCTAssertEqual(outcomes.map(\.1), [.expired])
        XCTAssertEqual(visibility, [true, false])
        clock.advance(20)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testABusyIslandAfterYesDoesNotUndoTheAnswer() {
        let model = model()
        model.show(whytap)
        clock.advance(0.7)
        model.answer(.yes)
        model.dismissForBusyIsland()
        XCTAssertEqual(outcomes.map(\.1), [.accepted])
        XCTAssertEqual(model.stage, .hidden)
    }

    // MARK: - Reduce Motion

    func testReduceMotionOnlyFades() {
        reduceMotion = true
        let model = model()
        model.show(whytap)
        XCTAssertEqual(model.dropsOut, 4)
        clock.advance(0.16)
        XCTAssertEqual(model.stage, .open)
        model.answer(.no)
        XCTAssertEqual(model.dropsOut, 0)
        clock.advance(0.16)
        XCTAssertEqual(model.stage, .hidden)
    }

    // MARK: - Controller

    func testControllerCapturesKeysOnlyWhileTheDropsAreOnScreenAndRoutesAnswers() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "drops-\(UUID().uuidString)"))
        let journal = DropLearningJournal(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("j.jsonl"))
        let vocabulary = VocabularyCache(defaults: defaults)
        let coordinator = DropLearningCoordinator(dependencies: .init(
            fieldAccess: NoField(), lexicon: NoWords(), defaults: defaults, now: Date.init, journal: journal,
            lists: { DropLearningLists(vocabulary: [], fillers: [], replacements: []) },
            sleep: { _ in }, isIdle: { true }, openVocabulary: {},
            vocabulary: vocabulary, fillers: FillerTermsStore(defaults: defaults),
            replacements: DropReplacementStore(defaults: defaults)
        ))
        let keys = FakeKeys()
        let phase = PassthroughSubject<AppPhase, Never>()
        var presented: [Bool] = []
        let model = model()
        let controller = DropLearningDropsController(
            coordinator: coordinator, model: model, keys: keys,
            present: { presented.append($0) }, phase: phase.eraseToAnyPublisher()
        )
        XCTAssertFalse(keys.capturing)

        coordinator.onSuggestion?(whytap)
        XCTAssertTrue(keys.capturing)
        XCTAssertEqual(presented, [true])
        clock.advance(0.7)
        keys.onControl?(true)
        XCTAssertTrue(model.controlHeld)
        keys.onAnswer?(.yes)
        XCTAssertTrue(vocabulary.terms.contains("Whytap"), "⌃Y saved through the Vocab store")
        clock.advance(2)
        XCTAssertFalse(keys.capturing)
        XCTAssertEqual(presented, [true, false])

        coordinator.onSuggestion?(typa)
        clock.advance(0.7)
        phase.send(.recording)
        XCTAssertFalse(keys.capturing)
        XCTAssertEqual(model.stage, .hidden)
        withExtendedLifetime(controller) {}
    }

    // MARK: - Content

    func testEachSuggestionSaysItsListSignAndAction() {
        let vocab = DropLearningDropContent.make(.vocabAdd(term: "Whytap"))
        XCTAssertEqual(vocab.list, .vocab)
        XCTAssertTrue(vocab.adds)
        XCTAssertEqual(vocab.accessibilityLabel, "Add “Whytap”?")

        XCTAssertEqual(DropLearningDropContent.make(.vocabRemove(term: "Exodia")).accessibilityLabel, "Forget “Exodia”?")
        let replace = DropLearningDropContent.make(.replaceAdd(DropReplacement(heard: "вайтап", wanted: "Whytap")))
        XCTAssertEqual(replace.list, .replace)
        XCTAssertEqual(replace.runs, [.plain("вайтап"), .arrow, .emphasis("Whytap")])
        let stopReplacing = DropLearningDropContent.make(.replaceRemove(DropReplacement(heard: "ок", wanted: "OK")))
        XCTAssertFalse(stopReplacing.adds)
        XCTAssertEqual(stopReplacing.accessibilityLabel, "Stop replacing “ок”?")
        XCTAssertEqual(DropLearningDropContent.make(.fillerAdd(term: "короче")).accessibilityLabel, "Cut “короче”?")
        let stopCutting = DropLearningDropContent.make(.fillerRemove(term: "типа"))
        XCTAssertEqual(stopCutting.list, .filler)
        XCTAssertFalse(stopCutting.adds)
        XCTAssertEqual(stopCutting.accessibilityLabel, "Stop cutting “типа”?")
    }

    func testAFullVocabShowsTheRoutesRealLimitAndYesOpensVocab() {
        let terms = DropLearningDropContent.make(.vocabFull(
            term: "Whytap", usage: .init(used: 50, limit: 50, unit: .terms)))
        XCTAssertEqual(terms.detail, "Vocab full 50/50")
        XCTAssertTrue(terms.yesOpens)
        let tokens = DropLearningDropContent.make(.vocabFull(
            term: "Whytap", usage: .init(used: 450, limit: 450, unit: .tokens)))
        XCTAssertEqual(tokens.detail, "Vocab full ≈450/450")
    }

    // MARK: - Review images

    /// Review images of the real view: every kind at rest, Y and N under the
    /// pointer and ⌃ held, light and dark, over a wallpaper-like backdrop.
    func testOffscreenDropsRenders() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_DROPS_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_DROPS_RENDER_DIR for drops review images")
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let cases: [(String, DropLearningCandidate, DropLearningDropsModel.Button?, Bool)] = [
            ("vocab-add", .vocabAdd(term: "Whytap"), nil, false),
            ("vocab-add-hover-y", .vocabAdd(term: "Whytap"), .yes, false),
            ("vocab-add-hover-n", .vocabAdd(term: "Whytap"), .no, false),
            ("vocab-add-ctrl", .vocabAdd(term: "Whytap"), nil, true),
            ("vocab-remove", .vocabRemove(term: "Exodia"), nil, false),
            ("replace-add", .replaceAdd(DropReplacement(heard: "вайтап", wanted: "Whytap")), nil, false),
            ("replace-remove", .replaceRemove(DropReplacement(heard: "ок", wanted: "OK")), nil, false),
            ("filler-add", .fillerAdd(term: "короче"), nil, false),
            ("filler-remove", .fillerRemove(term: "типа"), nil, false),
            ("vocab-full", .vocabFull(term: "Whytap", usage: .init(used: 50, limit: 50, unit: .terms)), .yes, false),
        ]
        for (name, candidate, hover, control) in cases {
            for dark in [false, true] {
                let model = model()
                model.show(DropLearningSuggestion(candidate: candidate, dryRun: false))
                clock.advance(1)
                model.setHovered(hover != nil)
                model.setHoveredButton(hover)
                model.setControlHeld(control)
                let size = NSSize(width: 540, height: 40)
                let content = ZStack(alignment: .leading) {
                    LinearGradient(colors: dark ? [Color(red: 0.11, green: 0.15, blue: 0.28), Color(red: 0.05, green: 0.06, blue: 0.11)]
                                                : [Color(red: 0.50, green: 0.57, blue: 0.79), Color(red: 0.79, green: 0.82, blue: 0.92)],
                                   startPoint: .top, endPoint: .bottom)
                    // The island's right end the first drop buds from.
                    UnevenRoundedRectangle(bottomTrailingRadius: 13).fill(.black)
                        .frame(width: 40, height: 32).offset(x: -24)
                    DropLearningDropsView(model: model).frame(height: 32)
                }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                      styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
                host.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                // Draw text in the window's appearance, as on screen.
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    host.cacheDisplay(in: host.bounds, to: image)
                }
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent("drops-\(name)-\(dark ? "dark" : "light").png"))
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    // MARK: - Reserved keys

    func testControlYAndControlNCannotBeGivenToATool() {
        var configuration = HotkeyConfiguration.defaults
        configuration.toolShortcuts[HoverTool.allCases[0]] = .combo(DropLearningKeyCombos.yes)
        XCTAssertTrue(configuration.conflicts.contains { $0.actionTitles.contains("Suggestion yes") })
        configuration.toolShortcuts[HoverTool.allCases[0]] = .combo(DropLearningKeyCombos.no)
        XCTAssertTrue(configuration.conflicts.contains { $0.actionTitles.contains("Suggestion no") })
        XCTAssertTrue(HotkeyConfiguration.defaults.conflicts.isEmpty)
    }

    func testHelpShowsControlYAndControlN() {
        let rows = HelpWindowContent.hotkeyRows(for: .defaults)
        XCTAssertEqual(rows.first { $0.title == "Suggestion — yes" }?.contents, DropLearningKeyCombos.yes.contents)
        XCTAssertEqual(rows.first { $0.title == "Suggestion — no" }?.contents, DropLearningKeyCombos.no.contents)
    }
}

@MainActor
private final class NoField: DropEditFieldAccess {
    func capture(pid: pid_t) -> DropEditFieldHandle? { nil }
    func isStillFocused(_ handle: DropEditFieldHandle) -> Bool { false }
    func read(_ handle: DropEditFieldHandle) -> String? { nil }
}

@MainActor
private struct NoWords: DropWordLexicon {
    func isKnownWord(_ word: String) -> Bool { false }
}
