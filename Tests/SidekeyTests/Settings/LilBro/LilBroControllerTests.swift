import Combine
import XCTest
@testable import Sidekey

/// Lil Bro as the person meets him: he lives on his sidebar entry, is
/// caught with a click, answers in his balloon, and only when the answer
/// names a place runs to the row that opens it and presses it through the
/// same calls the row makes. He stands still while the balloon is open and
/// goes home once it is closed. Every question goes to whytap.ai; there are
/// no scripted answers on this Mac (REV 10).
@MainActor
final class LilBroControllerTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "LilBro-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// whytap.ai as the tests see it: what was asked, and a fixed reply or,
    /// without one, what the model is told to do: name a place only when the
    /// question asks to go somewhere or set something up.
    private final class Remote: LilBroBrain {
        var reply: LilBroReply?
        private(set) var asked: [LilBroQuestion] = []
        init(_ reply: LilBroReply? = nil) { self.reply = reply }
        func reply(to question: LilBroQuestion) async -> LilBroReply {
            asked.append(question)
            return reply ?? Self.model(question.text)
        }

        static func model(_ text: String) -> LilBroReply {
            let q = text.lowercased()
            let places: [(String, LilBroDestination)] = [
                ("dictat", .feature(.drop)), ("meeting", .feature(.meetings)), ("hotkey", .tab(.hotkeys)), ("key", .apiKeys),
            ]
            let asksToGo = ["set up", "turn on", "how do i", "open", "change", "where"].contains { q.contains($0) }
            let place = places.first { q.contains($0.0) }?.1
            return .answer(LilBroAnswer(paragraphs: ["Here you go."], bullets: ["One thing to know"],
                                        destination: asksToGo ? place : nil))
        }
    }

    /// The window at its smallest: sidebar rows, his entry, the Features
    /// list with Drop's row, and two cards in the pane.
    private func map() -> (spots: [LilBroSpot: CGRect], blocks: [CGRect]) {
        var spots: [LilBroSpot: CGRect] = [
            .home: CGRect(x: 10, y: 470, width: 200, height: 34),
            .sidebar: CGRect(x: 0, y: 0, width: 220, height: 460),
            .pane: CGRect(x: 221, y: 0, width: 739, height: 560),
            .feature(.drop): CGRect(x: 245, y: 92, width: 690, height: 50),
            .feature(.meetings): CGRect(x: 245, y: 192, width: 690, height: 50),
        ]
        for (index, tab) in SettingsWindowTab.availableCases.enumerated() {
            spots[.tab(tab)] = CGRect(x: 10, y: 10 + CGFloat(index) * 34, width: 200, height: 30)
        }
        return (spots, [CGRect(x: 245, y: 90, width: 690, height: 300), CGRect(x: 245, y: 420, width: 690, height: 100)])
    }

    private func make(selection given: SettingsWindowSelection? = nil,
                      remote: LilBroBrain? = nil, mascot: Bool = true,
                      reduceMotion: Bool = false,
                      sleep: ((TimeInterval) async -> Void)? = nil) -> LilBroController {
        let selection = given ?? SettingsWindowSelection()
        let preferences = LilBroPreferences(defaults: defaults)
        preferences.mascotVisible = mascot
        let controller = LilBroController(selection: selection, preferences: preferences,
                                          remote: remote ?? Remote(),
                                          reduceMotion: { reduceMotion }, sleep: sleep ?? { _ in await Task.yield() })
        let (spots, blocks) = map()
        controller.update(bounds: CGRect(x: 0, y: 0, width: 960, height: 560))
        controller.update(blocks: blocks)
        controller.update(spots: spots)
        return controller
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func test_he_appears_standing_on_his_sidebar_entry() {
        let controller = make()
        XCTAssertTrue(controller.placed)
        XCTAssertEqual(controller.feet, CGPoint(x: 176, y: 471))
        XCTAssertEqual(controller.bubble, .closed)
    }

    func test_a_click_catches_him_and_opens_the_balloon() async {
        let controller = make()
        controller.catchHim()
        XCTAssertEqual(controller.pose, .caught)
        await until { controller.bubble == .full }
        XCTAssertEqual(controller.pose, .idle)
        XCTAssertTrue(controller.turns.isEmpty, "the greeting with starter questions")
    }

    func test_asked_to_set_up_dictation_he_runs_to_drop_presses_it_and_stays_with_the_balloon_open() async {
        let selection = SettingsWindowSelection()
        let controller = make(selection: selection)
        controller.catchHim()
        await until { controller.bubble == .full }

        controller.ask("how do I dictate")
        XCTAssertEqual(controller.bubble, .thinking)
        await until { controller.bubble == .full }

        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .drop, "pressed the Drop row")
        XCTAssertEqual(controller.turns.last?.opened, "Drop")
        XCTAssertEqual(controller.pose, .point)
        XCTAssertNotNil(controller.target, "the block he brought you to is outlined")
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.segment, "standing still while the balloon is open")
        let standing = controller.feet
        XCTAssertEqual(standing.y, 91, "on top of the screen's first card")

        // A layout pass with the balloon open does not move him.
        let (spots, blocks) = map()
        controller.update(blocks: blocks)
        controller.update(spots: spots)
        XCTAssertEqual(controller.feet, standing)
    }

    func test_from_another_tab_he_first_presses_features_in_the_sidebar() async {
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        let controller = make(selection: selection)
        controller.ask("Turn on meeting notes")
        await until { controller.bubble == .full }
        // Meeting Notes opens its present place, as its row does.
        XCTAssertEqual(controller.turns.last?.opened, "Meeting Notes")
        if case .tab(let tab) = FeatureCatalog.info(for: .meetings).place {
            XCTAssertEqual(selection.selectedTab, tab.resolved)
        } else {
            XCTAssertEqual(selection.shownFeature, .meetings)
        }
    }

    func test_closing_the_balloon_sends_him_home() async {
        let controller = make()
        controller.ask("Set up dictation")
        await until { controller.bubble == .full }
        XCTAssertNotEqual(controller.feet, CGPoint(x: 176, y: 471))

        controller.close()
        XCTAssertNil(controller.target)
        await until { controller.feet.y == 471 && !controller.isBusy }
        XCTAssertEqual(controller.bubble, .closed)
        XCTAssertTrue((26...196).contains(controller.feet.x))
    }

    func test_closing_while_he_is_on_his_way_stops_him_cleanly() async {
        let slow = LilBroController(selection: SettingsWindowSelection(),
                                    preferences: LilBroPreferences(defaults: defaults), remote: Remote(),
                                    reduceMotion: { false },
                                    sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) })
        let (spots, blocks) = map()
        slow.update(bounds: CGRect(x: 0, y: 0, width: 960, height: 560))
        slow.update(blocks: blocks)
        slow.update(spots: spots)
        slow.ask("how do I dictate")
        await until { if case .tag = slow.bubble { return true }; return false }
        slow.close()
        XCTAssertEqual(slow.bubble, .closed)
        XCTAssertNil(slow.ladder)
        XCTAssertNil(slow.flash)
        slow.stopWandering()
    }

    func test_without_the_little_guy_the_place_opens_at_once() async {
        let selection = SettingsWindowSelection(selectedTab: .permissions)
        let controller = make(selection: selection, mascot: false)
        controller.toggleFromSidebar()
        XCTAssertEqual(controller.bubble, .full)
        controller.ask("Set up dictation")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(selection.shownFeature, .drop)
        XCTAssertEqual(controller.feet, CGPoint(x: 176, y: 471), "nobody ran")
    }

    func test_with_reduced_motion_he_appears_at_the_place() async {
        let selection = SettingsWindowSelection()
        let controller = make(selection: selection, reduceMotion: true)
        controller.ask("Set up dictation")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(selection.shownFeature, .drop)
        XCTAssertNil(controller.segment)
        XCTAssertEqual(controller.feet.y, 91)
    }

    func test_offline_he_is_sad_and_nothing_changes() async {
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        let controller = make(selection: selection, remote: Remote(.offline))
        controller.ask("how do I dictate")
        await until { controller.bubble == .full }
        XCTAssertEqual(controller.pose, .sad)
        XCTAssertEqual(selection.selectedTab, .hotkeys)
        XCTAssertNil(controller.turns.last?.opened)
    }

    func test_hiding_the_little_guy_is_remembered() {
        let controller = make()
        controller.setMascotVisible(false)
        XCTAssertFalse(LilBroPreferences(defaults: defaults).mascotVisible)
        controller.setMascotVisible(true)
        XCTAssertTrue(LilBroPreferences(defaults: defaults).mascotVisible)
    }

    func test_an_empty_question_is_not_sent() {
        let controller = make()
        controller.ask("   ")
        XCTAssertTrue(controller.turns.isEmpty)
        XCTAssertEqual(controller.bubble, .closed)
    }

    func test_he_waits_at_home_when_his_block_scrolls_away() async {
        let controller = make()
        controller.ask("Set up dictation")
        await until { controller.bubble == .full }
        let (spots, _) = map()
        controller.update(blocks: [CGRect(x: 245, y: -400, width: 690, height: 300)])
        controller.update(spots: spots)
        XCTAssertNil(controller.target)
        XCTAssertEqual(controller.feet, CGPoint(x: 176, y: 471))
    }

    func test_the_route_to_a_feature_presses_the_rows_a_person_would() {
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        let controller = make(selection: selection)
        XCTAssertEqual(controller.stops(for: .feature(.drop)).map(\.spot), [.tab(.features), .feature(.drop)])
        selection.select(.features)
        XCTAssertEqual(controller.stops(for: .feature(.drop)).map(\.spot), [.feature(.drop)])
        selection.open(.drop)
        XCTAssertTrue(controller.stops(for: .feature(.drop)).isEmpty, "already there")
        XCTAssertEqual(controller.stops(for: .apiKeys).map(\.spot), [.tab(.apiAndModels)])
        let record = LilBroRow.named("hotkeys.meetingRecord")!
        XCTAssertEqual(controller.stops(for: .row(record)).map(\.spot), [.tab(.hotkeys)], "the tab first")
        selection.select(.hotkeys)
        XCTAssertTrue(controller.stops(for: .row(record)).isEmpty, "already on the tab: only the scroll")
        XCTAssertEqual(controller.stops(for: .tab(.agentMode)).map(\.spot), [.tab(SettingsWindowTab.agentMode.resolved)])
        // REV 14: a row on a feature's screen goes the feature's way.
        let duck = LilBroRow.named("drop.lowerOtherAudio")!
        selection.select(.hotkeys)
        XCTAssertEqual(controller.stops(for: .row(duck)).map(\.spot), [.tab(.features), .feature(.drop)])
        selection.open(.drop)
        XCTAssertTrue(controller.stops(for: .row(duck)).isEmpty, "already on Drop: only the scroll")
        let hold = LilBroRow.named("toolbox.holdBrightness")!
        XCTAssertEqual(controller.stops(for: .row(hold)).map(\.spot), [.tab(.features)], "Toolbox opens with its tool")
    }

    // MARK: Answers from whytap.ai

    /// REV 13 (the maintainer's decision, 2026-11-26): every question goes to
    /// whytap.ai; there is no switch. An "off" saved by an earlier build
    /// (1770–1772) no longer stops it.
    func test_every_question_goes_to_whytap_even_after_an_old_off_choice() async {
        let defaults = UserDefaults(suiteName: "lilbro-old-off-\(UUID().uuidString)")!
        defaults.set(false, forKey: "lilBro.answersFromWhytap")
        let remote = Remote()
        let controller = LilBroController(selection: SettingsWindowSelection(),
                                          preferences: LilBroPreferences(defaults: defaults),
                                          remote: remote, reduceMotion: { true },
                                          sleep: { _ in await Task.yield() })
        XCTAssertTrue(remote.asked.isEmpty, "nothing is sent before a question")
        controller.ask("can I talk instead of typing")
        await until { !remote.asked.isEmpty && !controller.isBusy }
        XCTAssertEqual(remote.asked.first?.text, "can I talk instead of typing", "no card first: the question goes out")
    }

    /// REV 10: the model decides. A question answered in words stays in the
    /// balloon; nothing opens and he does not run.
    func test_a_question_answered_in_words_opens_nothing() async {
        let remote = Remote()
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        let controller = make(selection: selection, remote: remote)
        controller.ask("does dictation work offline")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(remote.asked.map(\.text), ["does dictation work offline"])
        guard case .answer(let answer) = controller.turns.last?.reply else { return XCTFail("an answer") }
        XCTAssertNil(answer.destination)
        XCTAssertNil(controller.turns.last?.opened)
        XCTAssertEqual(selection.selectedTab, .hotkeys, "nothing opened")
        XCTAssertNil(selection.shownFeature)
        XCTAssertNil(controller.target)
        XCTAssertEqual(controller.feet, CGPoint(x: 176, y: 471), "he stayed home")
    }

    func test_he_asks_whytap_with_the_screen_and_earlier_answers() async {
        let answer = LilBroAnswer(paragraphs: ["Drop types what you say."], bullets: ["Hold its shortcut"],
                                  destination: .feature(.drop))
        let remote = Remote(.answer(answer))
        let selection = SettingsWindowSelection()
        let controller = make(selection: selection, remote: remote, reduceMotion: true)
        controller.ask("can I talk instead of typing")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(remote.asked.first, LilBroQuestion(text: "can I talk instead of typing", screen: "features"))
        XCTAssertEqual(selection.shownFeature, .drop, "he opened the place whytap.ai named")
        XCTAssertEqual(controller.turns.last?.opened, "Drop")

        controller.ask("does it work offline")
        await until { controller.bubble == .full && !controller.isBusy && remote.asked.count == 2 }
        XCTAssertEqual(remote.asked[1].screen, "features/drop")
        XCTAssertEqual(remote.asked[1].history,
                       [.init(question: "can I talk instead of typing", answer: "Drop types what you say.\nHold its shortcut")])
    }

    /// A too-short question was never sent, so it is not sent back as an
    /// earlier exchange either; offline replies are not history.
    func test_only_answers_from_whytap_go_back_as_history() async {
        let remote = Remote(.answer(LilBroAnswer(paragraphs: ["Drop types what you say."])))
        let controller = make(remote: remote, reduceMotion: true)
        controller.ask("x")
        controller.ask("first question to whytap")
        await until { controller.bubble == .full && !controller.isBusy && remote.asked.count == 1 }
        XCTAssertEqual(remote.asked[0].history, [], "an unsent turn is not history")
        remote.reply = .offline
        controller.ask("second question")
        await until { controller.bubble == .full && !controller.isBusy && remote.asked.count == 2 }
        remote.reply = .answer(LilBroAnswer(paragraphs: ["Yes."]))
        controller.ask("third question")
        await until { controller.bubble == .full && !controller.isBusy && remote.asked.count == 3 }
        XCTAssertEqual(remote.asked[2].history.map(\.question), ["first question to whytap"])
    }

    func test_offline_try_again_asks_once_more_in_the_same_place() async {
        let remote = Remote(.offline)
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        let controller = make(selection: selection, remote: remote, reduceMotion: true)
        controller.ask("how do I dictate")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(controller.turns.last?.reply, .offline)
        XCTAssertEqual(selection.selectedTab, .hotkeys, "nothing changed")
        XCTAssertEqual(controller.pose, .sad)

        remote.reply = .answer(LilBroAnswer(paragraphs: ["Drop types what you say."], destination: .feature(.drop)))
        controller.retry()
        await until { controller.bubble == .full && !controller.isBusy && remote.asked.count == 2 }
        XCTAssertEqual(controller.turns.count, 1, "the failed turn was replaced, not repeated")
        XCTAssertEqual(selection.shownFeature, .drop)
    }

    /// Without whytap.ai a short message only: no "closest page" guessed on
    /// this Mac.
    func test_when_whytap_cannot_answer_nothing_opens() async {
        for failure in [LilBroReply.limit, .offline, .unavailable] {
            let selection = SettingsWindowSelection(selectedTab: .permissions)
            let controller = make(selection: selection, remote: Remote(failure), reduceMotion: true)
            controller.ask("how do I dictate")
            await until { controller.bubble == .full && !controller.isBusy }
            XCTAssertEqual(controller.turns.last?.reply, failure)
            XCTAssertNil(controller.turns.last?.opened)
            XCTAssertEqual(selection.selectedTab, .permissions)
            XCTAssertNil(selection.shownFeature)
        }
        XCTAssertTrue(LilBroCopy.offline.contains("answers aren’t available"))
        XCTAssertFalse(LilBroCopy.offline.contains("closest"))
    }

    // MARK: Cancellation and stopping (builder review of #464)

    /// Holds the waits `pausing` picks (a punch, a long run) until released;
    /// every other wait passes at once.
    @MainActor
    private final class Gate {
        let pausing: (TimeInterval) -> Bool
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var waiting: Int { waiters.count }

        init(pausing: @escaping (TimeInterval) -> Bool) { self.pausing = pausing }

        func sleep(_ seconds: TimeInterval) async {
            guard !open, pausing(seconds) else { await Task.yield(); return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func settleDown() async {
        for _ in 0..<400 { await Task.yield() }
    }

    func test_closing_during_a_punch_never_presses_the_row() async {
        let gate = Gate { $0 == 0.43 }
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        var seen: [SettingsWindowTab] = []
        let watch = selection.$selectedTab.sink { seen.append($0) }
        defer { watch.cancel() }
        let controller = make(selection: selection, sleep: { await gate.sleep($0) })
        controller.ask("Set up dictation")
        await until { controller.flash != nil && gate.waiting == 1 }
        controller.close()
        gate.release()
        await settleDown()
        XCTAssertEqual(selection.selectedTab, .hotkeys)
        XCTAssertFalse(seen.contains(.features), "the cancelled guide pressed Features")
        XCTAssertNil(selection.shownFeature)
        await until { !controller.isBusy && controller.feet.y == 471 }
    }

    func test_a_new_question_during_a_punch_replaces_the_old_guide() async {
        let gate = Gate { $0 == 0.43 }
        let selection = SettingsWindowSelection(selectedTab: .permissions)
        var seen: [SettingsWindowTab] = []
        let watch = selection.$selectedTab.sink { seen.append($0) }
        defer { watch.cancel() }
        let controller = make(selection: selection, sleep: { await gate.sleep($0) })
        controller.ask("Set up dictation")
        await until { controller.flash != nil && gate.waiting == 1 }
        controller.ask("change a hotkey")
        await until { gate.waiting == 2 }
        gate.release()
        await until { controller.bubble == .full && !controller.isBusy }
        await settleDown()
        XCTAssertEqual(selection.selectedTab, .hotkeys)
        XCTAssertFalse(seen.contains(.features), "the replaced guide still pressed Features")
        XCTAssertNil(selection.shownFeature)
        XCTAssertEqual(controller.turns.map(\.opened), [nil, "Hotkeys"])
    }

    func test_opening_the_balloon_from_the_sidebar_stops_a_stroll_at_once() async {
        let gate = Gate { $0 >= 0.6 }
        let controller = make(sleep: { await gate.sleep($0) })
        controller.stroll(to: CGPoint(x: 60, y: 471))
        await until { controller.segment != nil && gate.waiting == 1 }
        controller.toggleFromSidebar()
        XCTAssertNil(controller.segment, "he does not run under an open balloon")
        XCTAssertEqual(controller.bubble, .full)
        XCTAssertEqual(controller.pose, .idle)
        let stopped = controller.feet
        gate.release()
        await settleDown()
        XCTAssertEqual(controller.feet, stopped)
        XCTAssertNil(controller.segment)
    }

    func test_catching_him_mid_stroll_stops_him_before_the_balloon() async {
        let gate = Gate { $0 >= 0.6 }
        let controller = make(sleep: { await gate.sleep($0) })
        controller.stroll(to: CGPoint(x: 60, y: 471))
        await until { controller.segment != nil && gate.waiting == 1 }
        XCTAssertTrue(controller.canCatch)
        controller.catchHim()
        XCTAssertNil(controller.segment)
        await until { controller.bubble == .full }
        gate.release()
        await settleDown()
        XCTAssertNil(controller.segment)
    }

    func test_after_closing_he_strolls_again_later() async {
        let controller = make(reduceMotion: true)
        controller.ask("Set up dictation")
        await until { controller.bubble == .full && !controller.isBusy }
        controller.close()
        await until { !controller.isBusy }
        await settleDown()
        controller.stroll(to: CGPoint(x: 60, y: 471))
        await until { controller.feet.x == 60 }
    }


    func test_he_is_a_control_only_while_a_click_catches_him() async {
        let gate = Gate { $0 >= 0.6 }
        let controller = make(sleep: { await gate.sleep($0) })
        XCTAssertTrue(controller.canCatch, "at home")
        controller.stroll(to: CGPoint(x: 60, y: 471))
        await until { controller.segment != nil }
        XCTAssertTrue(controller.canCatch, "while strolling")
        gate.release()
        controller.toggleFromSidebar()
        XCTAssertFalse(controller.canCatch, "balloon open")
        controller.ask("Set up dictation")
        XCTAssertFalse(controller.canCatch, "thinking")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertFalse(controller.canCatch, "answer shown")
        controller.close()
        XCTAssertTrue(controller.canCatch, "walking home after closing")
        controller.catchHim()
        await until { controller.bubble == .full }
    }

    /// A short answer and one action: the details (the place he opened,
    /// examples) wait behind More, and every new question starts short again.
    func test_an_answer_is_short_until_more_is_asked_for() async {
        let controller = make(reduceMotion: true)
        controller.ask("how do I dictate")
        await until { controller.bubble == .full && !controller.isBusy }
        guard case .answer(let answer) = controller.turns.last?.reply else { return XCTFail("an answer") }
        XCTAssertFalse(controller.showMore)
        XCTAssertTrue(LilBroReplyView.hasDetails(answer, opened: controller.turns.last?.opened))
        controller.showMore = true
        controller.ask("where are my keys")
        XCTAssertFalse(controller.showMore, "a new question starts short")
        await until { controller.bubble == .full && !controller.isBusy }
        controller.showMore = true
        controller.close()
        XCTAssertFalse(controller.showMore)
        XCTAssertFalse(LilBroReplyView.hasDetails(LilBroAnswer(paragraphs: ["Here it is."]), opened: nil))
    }

    /// Opened before any question: only the greeting line and the field, no
    /// balloon; the balloon comes with the first answer.
    func test_first_open_is_only_the_field_and_the_balloon_comes_with_the_first_answer() async {
        let controller = make(reduceMotion: true)
        controller.toggleFromSidebar()
        XCTAssertTrue(controller.isOpen)
        XCTAssertFalse(controller.showsBalloon, "only the greeting line and the field")
        XCTAssertEqual(controller.greeting, LilBroCopy.greetings[0])
        controller.toggleFromSidebar()
        controller.toggleFromSidebar()
        XCTAssertEqual(controller.greeting, LilBroCopy.greetings[1], "a different line each opening")
        controller.ask("how do I dictate")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertTrue(controller.showsBalloon)
    }

    /// Under the three characters whytap.ai takes: nothing is sent.
    func test_a_too_short_question_is_never_sent() async {
        let remote = Remote()
        let controller = make(remote: remote, reduceMotion: true)
        for question in ["x", "Я", "🦊", "x?", "x  "] {
            controller.ask(question)
            XCTAssertEqual(controller.turns.last?.reply, .tooShort, question)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(remote.asked.isEmpty)
    }

    // MARK: Clear and closing (builder review of #493, ticket 625)

    /// whytap.ai that answers only when the test lets it.
    @MainActor
    private final class Held: LilBroBrain {
        private(set) var asked: [LilBroQuestion] = []
        private var waiting: CheckedContinuation<LilBroReply, Never>?
        var isWaiting: Bool { waiting != nil }
        func reply(to question: LilBroQuestion) async -> LilBroReply {
            asked.append(question)
            return await withCheckedContinuation { waiting = $0 }
        }
        func answer(_ reply: LilBroReply) {
            waiting?.resume(returning: reply)
            waiting = nil
        }
    }

    private static let toDrop = LilBroReply.answer(LilBroAnswer(paragraphs: ["Drop types what you say."],
                                                                destination: .feature(.drop)))

    func test_clear_while_he_guides_stops_before_the_press() async {
        let gate = Gate { $0 == 0.43 }
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        let controller = make(selection: selection, sleep: { await gate.sleep($0) })
        controller.ask("Set up dictation")
        await until { controller.flash != nil && gate.waiting == 1 }
        controller.clear()
        gate.release()
        await settleDown()
        XCTAssertEqual(selection.selectedTab, .hotkeys, "no navigation after Clear")
        XCTAssertNil(selection.shownFeature)
        XCTAssertFalse(controller.isBusy)
    }

    func test_clear_ends_a_pending_question_and_he_stays_usable() async {
        let remote = Held()
        let selection = SettingsWindowSelection()
        let controller = make(selection: selection, remote: remote, reduceMotion: true)
        controller.toggleFromSidebar()
        controller.ask("Set up dictation")
        await until { remote.isWaiting }
        controller.clear()
        XCTAssertTrue(controller.turns.isEmpty)
        XCTAssertFalse(controller.isBusy, "the entry is usable at once")
        XCTAssertEqual(controller.bubble, .full)
        remote.answer(Self.toDrop)
        await settleDown()
        XCTAssertTrue(controller.turns.isEmpty, "no late reply lands")
        XCTAssertNil(selection.shownFeature, "and nothing opens")
        controller.ask("does dictation work offline")
        await until { remote.isWaiting }
        remote.answer(.answer(LilBroAnswer(paragraphs: ["Yes."])))
        await until { !controller.isBusy && controller.turns.count == 1 && controller.turns[0].reply != nil }
    }

    func test_closing_before_the_reply_drops_the_empty_question() async {
        let remote = Held()
        let controller = make(remote: remote, reduceMotion: true)
        controller.ask("Set up dictation")
        await until { remote.isWaiting }
        controller.close()
        remote.answer(Self.toDrop)
        await settleDown()
        XCTAssertTrue(controller.turns.isEmpty)
    }

    // MARK: Exact row (REV 12; builder review of #493, ticket 627)

    private static let record = LilBroRow.named("hotkeys.meetingRecord")!
    private static let toRecord = LilBroReply.answer(LilBroAnswer(paragraphs: ["Meeting record is the row."],
                                                                  destination: .row(record)))

    /// The Hotkeys tab as the test plays it: while the row is focused on
    /// that tab, it reports itself at `y` (nil = scrolled away).
    @MainActor
    private final class HotkeysTab {
        var y: CGFloat? = 300
        /// Called on every wait of his; lets a test act mid-guide.
        var onWait: (() -> Void)?
        weak var controller: LilBroController?
        let selection: SettingsWindowSelection
        let base: (spots: [LilBroSpot: CGRect], blocks: [CGRect])
        init(selection: SettingsWindowSelection, base: (spots: [LilBroSpot: CGRect], blocks: [CGRect])) {
            self.selection = selection
            self.base = base
        }
        var rect: CGRect? { y.map { CGRect(x: 245, y: $0, width: 690, height: 53) } }
        func report() {
            guard let controller else { return }
            var spots = base.spots
            var blocks = base.blocks
            if selection.selectedTab == .hotkeys, let rect {
                spots[.row(LilBroControllerTests.record.id)] = rect
                if selection.focusedRow == LilBroControllerTests.record.id { blocks.append(rect) }
            }
            controller.update(blocks: blocks)
            controller.update(spots: spots)
        }
    }

    private func leading(mascot: Bool, reduceMotion: Bool) -> (LilBroController, SettingsWindowSelection, HotkeysTab) {
        let selection = SettingsWindowSelection()
        let tab = HotkeysTab(selection: selection, base: map())
        let controller = make(selection: selection, remote: Remote(Self.toRecord), mascot: mascot,
                              reduceMotion: reduceMotion,
                              sleep: { _ in tab.onWait?(); tab.report(); await Task.yield() })
        tab.controller = controller
        return (controller, selection, tab)
    }

    private let modes: [(mascot: Bool, reduceMotion: Bool)] = [(true, false), (true, true), (false, false)]

    func test_he_leads_to_the_row_and_its_outline_follows_it_away_and_back() async {
        for mode in modes {
            let (controller, selection, tab) = leading(mascot: mode.mascot, reduceMotion: mode.reduceMotion)
            controller.ask("how do I set a hotkey to start a meeting")
            await until { controller.bubble == .full && !controller.isBusy }
            XCTAssertEqual(selection.selectedTab, .hotkeys, "\(mode)")
            XCTAssertEqual(controller.target, tab.rect, "the row itself is outlined \(mode)")
            XCTAssertEqual(controller.turns.last?.opened, "Meeting record")
            if mode.mascot { XCTAssertEqual(controller.feet.y, 301, "he stands on it \(mode)") }

            tab.y = nil
            tab.report()
            XCTAssertNil(controller.target, "scrolled away: no outline left behind \(mode)")
            if mode.mascot { XCTAssertEqual(controller.feet, CGPoint(x: 176, y: 471), "waits at home \(mode)") }
            tab.y = 180
            tab.report()
            XCTAssertEqual(controller.target, tab.rect, "back: outlined where it is now \(mode)")
            if mode.mascot {
                XCTAssertEqual(controller.feet.y, 181, "and he is back on it \(mode)")
                XCTAssertEqual(controller.pose, .point, "\(mode)")
            } else {
                XCTAssertEqual(controller.feet, CGPoint(x: 176, y: 471), "hidden: nobody moves \(mode)")
            }
            tab.y = 120
            tab.report()
            XCTAssertEqual(controller.target, tab.rect, "follows its scrolling \(mode)")
            if mode.mascot { XCTAssertEqual(controller.feet.y, 121, "\(mode)") }
            // Cleared, the row coming back brings neither back.
            controller.clear()
            tab.y = 200
            tab.report()
            XCTAssertNil(controller.target, "\(mode)")
        }
    }

    func test_leaving_the_tab_clear_or_a_new_question_ends_the_outline() async {
        for mode in modes {
            for end in ["tab", "clear", "ask"] {
                let (controller, selection, tab) = leading(mascot: mode.mascot, reduceMotion: mode.reduceMotion)
                controller.ask("how do I set a hotkey to start a meeting")
                await until { controller.bubble == .full && !controller.isBusy }
                XCTAssertNotNil(controller.target, "\(mode) \(end)")
                switch end {
                case "tab": selection.select(.other)
                case "clear": controller.clear()
                default:
                    (controller.remote as? Remote)?.reply = .answer(LilBroAnswer(paragraphs: ["Yes."]))
                    controller.ask("does it work offline")
                    await until { controller.bubble == .full && !controller.isBusy }
                }
                tab.report()
                XCTAssertNil(controller.target, "no stale outline after \(end) \(mode)")
                XCTAssertNil(selection.focusedRow, "\(end) \(mode)")
                // The row coming back later is not outlined again.
                tab.report()
                XCTAssertNil(controller.target, "\(end) \(mode)")
            }
        }
    }

    func test_leaving_the_tab_before_the_row_shows_outlines_nothing_and_opens_nothing() async {
        for mode in modes {
            let (controller, selection, tab) = leading(mascot: mode.mascot, reduceMotion: mode.reduceMotion)
            tab.onWait = {
                // The person picks General the moment the row is focused.
                if selection.focusedRow == Self.record.id { selection.select(.other) }
            }
            controller.ask("how do I set a hotkey to start a meeting")
            await until { controller.bubble == .full && !controller.isBusy }
            XCTAssertEqual(selection.selectedTab, .other, "their tab stays \(mode)")
            XCTAssertNil(controller.target, "no other card outlined instead \(mode)")
            XCTAssertNil(controller.turns.last?.opened, "the row is not said to be opened \(mode)")
            XCTAssertNil(selection.focusedRow)
            if mode.mascot { XCTAssertEqual(controller.feet, CGPoint(x: 176, y: 471), "home \(mode)") }
        }
    }

    func test_a_row_that_never_shows_is_not_claimed() async {
        let (controller, selection, tab) = leading(mascot: false, reduceMotion: false)
        tab.y = nil
        controller.ask("how do I set a hotkey to start a meeting")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(selection.selectedTab, .hotkeys)
        XCTAssertNil(controller.target)
        XCTAssertNil(controller.turns.last?.opened)
    }

    /// Leaving Hotkeys while it is still laying out, before the row is
    /// focused: the person's tab stays and nothing is claimed (ticket 630).
    func test_leaving_the_tab_while_it_opens_keeps_the_persons_choice() async {
        for mode in modes {
            let (controller, selection, tab) = leading(mascot: mode.mascot, reduceMotion: mode.reduceMotion)
            selection.select(.permissions)
            tab.onWait = {
                if selection.selectedTab == .hotkeys, selection.focusedRow == nil { selection.select(.other) }
            }
            controller.ask("how do I set a hotkey to start a meeting")
            await until { controller.bubble == .full && !controller.isBusy }
            XCTAssertEqual(selection.selectedTab, .other, "never reselected \(mode)")
            XCTAssertNil(selection.focusedRow, "\(mode)")
            XCTAssertNil(controller.target, "\(mode)")
            XCTAssertNil(controller.turns.last?.opened, "\(mode)")
        }
    }

    /// The person clicks General while he punches the Hotkeys row in the
    /// sidebar: he presses nothing, their tab stays, nothing is claimed
    /// (ticket 631). The same holds for a feature's screen.
    func test_a_click_of_the_persons_own_during_his_punch_wins() async {
        for destination in [LilBroDestination.row(Self.record), .feature(.drop)] {
            let gate = Gate { $0 == 0.43 }
            let selection = SettingsWindowSelection(selectedTab: .permissions)
            let controller = make(selection: selection,
                                  remote: Remote(.answer(LilBroAnswer(paragraphs: ["Here."], destination: destination))),
                                  sleep: { await gate.sleep($0) })
            controller.ask("take me there")
            await until { controller.flash != nil && gate.waiting == 1 }
            selection.select(.other)
            gate.release()
            await until { controller.bubble == .full && !controller.isBusy }
            await settleDown()
            XCTAssertEqual(selection.selectedTab, .other, "\(destination)")
            XCTAssertNil(selection.shownFeature, "\(destination)")
            XCTAssertNil(selection.focusedRow, "\(destination)")
            XCTAssertNil(controller.target, "\(destination)")
            XCTAssertNil(controller.turns.last?.opened, "\(destination)")
            XCTAssertEqual(controller.feet, CGPoint(x: 176, y: 471), "home \(destination)")
        }
    }
}
