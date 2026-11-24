import XCTest
@testable import Sidekey

/// Lil Bro as the person meets him: he lives on his sidebar entry, is
/// caught with a click, answers in his balloon, runs to the row that opens
/// the place and presses it through the same calls the row makes, stands
/// still while the balloon is open and goes home once it is closed.
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

    private struct Fixed: LilBroBrain {
        let reply: LilBroReply
        func reply(to question: LilBroQuestion) async -> LilBroReply { reply }
    }

    /// whytap.ai as the tests see it: what was asked, and a fixed reply.
    private final class Remote: LilBroBrain {
        var reply: LilBroReply
        private(set) var asked: [LilBroQuestion] = []
        init(_ reply: LilBroReply) { self.reply = reply }
        func reply(to question: LilBroQuestion) async -> LilBroReply {
            asked.append(question)
            return reply
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
                      brain: LilBroBrain? = nil, remote: LilBroBrain? = nil, mascot: Bool = true,
                      reduceMotion: Bool = false) -> LilBroController {
        let selection = given ?? SettingsWindowSelection()
        let preferences = LilBroPreferences(defaults: defaults)
        preferences.mascotVisible = mascot
        let controller = LilBroController(selection: selection, preferences: preferences, local: brain,
                                          remote: remote ?? Remote(.unavailable),
                                          reduceMotion: { reduceMotion }, sleep: { _ in await Task.yield() })
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

    func test_asked_about_dictation_he_runs_to_drop_presses_it_and_stays_with_the_balloon_open() async {
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
                                    preferences: LilBroPreferences(defaults: defaults), local: nil, remote: Remote(.unavailable),
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
        let controller = make(selection: selection, brain: Fixed(reply: .offline))
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
        XCTAssertEqual(controller.stops(for: .tab(.agentMode)).map(\.spot), [.tab(SettingsWindowTab.agentMode.resolved)])
    }

    // MARK: Answers from whytap.ai (step 2)

    func test_nothing_goes_to_whytap_until_answers_are_turned_on() async {
        let remote = Remote(.unavailable)
        let selection = SettingsWindowSelection()
        let controller = make(selection: selection, remote: remote, reduceMotion: true)
        XCTAssertFalse(controller.answersFromWhytap, "off by default")
        controller.ask("how do I dictate")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertTrue(remote.asked.isEmpty)
        XCTAssertEqual(selection.shownFeature, .drop, "the local guide still finds it")
    }

    func test_turned_on_he_asks_whytap_with_the_screen_and_earlier_answers() async {
        let answer = LilBroAnswer(paragraphs: ["Drop types what you say."], bullets: ["Hold its shortcut"],
                                  destination: .feature(.drop), followUps: ["Does it work offline?"])
        let remote = Remote(.answer(answer))
        let selection = SettingsWindowSelection()
        let controller = make(selection: selection, remote: remote, reduceMotion: true)
        controller.setAnswersFromWhytap(true)
        XCTAssertTrue(LilBroPreferences(defaults: defaults).answersFromWhytap, "the choice is remembered")
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

    func test_turning_answers_off_goes_back_to_this_mac() async {
        let remote = Remote(.unavailable)
        let controller = make(remote: remote, reduceMotion: true)
        controller.setAnswersFromWhytap(true)
        controller.setAnswersFromWhytap(false)
        controller.ask("Set up dictation")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertTrue(remote.asked.isEmpty)
        XCTAssertFalse(LilBroPreferences(defaults: defaults).answersFromWhytap)
    }

    func test_offline_try_again_asks_once_more_in_the_same_place() async {
        let remote = Remote(.offline)
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        let controller = make(selection: selection, remote: remote, reduceMotion: true)
        controller.setAnswersFromWhytap(true)
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

    func test_when_whytap_cannot_answer_he_still_opens_the_closest_page() async {
        let remote = Remote(.limit)
        let selection = SettingsWindowSelection(selectedTab: .permissions)
        let controller = make(selection: selection, remote: remote, reduceMotion: true)
        controller.setAnswersFromWhytap(true)
        controller.ask("how do I dictate")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(controller.turns.last?.reply, .limit)
        XCTAssertEqual(LilBroLocalGuide.closestPlaces(for: "how do I dictate"), [.feature(.drop)])
        controller.open(.feature(.drop))
        await until { controller.bubble == .full && !controller.isBusy && selection.shownFeature == .drop }
        XCTAssertEqual(controller.turns.last?.opened, "Drop")
        XCTAssertEqual(LilBroLocalGuide.closestPlaces(for: "zzz"), [.tab(.features), .apiKeys])
    }

    // MARK: Pressing after a yes (step 3)

    /// Drop's screen reports its "What it needs" rows: the model row with
    /// Download free model, and an optional row that is never offered unasked.
    @MainActor
    private final class Steps {
        private(set) var performed: [FeatureSetupAction] = []
        func report(to controller: LilBroController, optionalFirst: Bool = false) {
            let perform: @MainActor (FeatureSetupAction) -> Void = { [weak self] in self?.performed.append($0) }
            let model = LilBroPressable(id: "model.dropFast", action: .downloadOnDeviceModel(.dropFast),
                                        optional: false, perform: perform)
            let extra = LilBroPressable(id: "permission.microphone", action: .allow(.microphone),
                                        optional: true, perform: perform)
            controller.update(pressables: optionalFirst ? [extra, model] : [model, extra])
            var spots = map().spots
            spots[.need("model.dropFast")] = CGRect(x: 245, y: 300, width: 690, height: 50)
            controller.update(spots: spots)
        }

        private func map() -> (spots: [LilBroSpot: CGRect], blocks: [CGRect]) {
            var spots: [LilBroSpot: CGRect] = [
                .home: CGRect(x: 10, y: 470, width: 200, height: 34),
                .sidebar: CGRect(x: 0, y: 0, width: 220, height: 460),
                .pane: CGRect(x: 221, y: 0, width: 739, height: 560),
                .feature(.drop): CGRect(x: 245, y: 92, width: 690, height: 50),
            ]
            for (index, tab) in SettingsWindowTab.availableCases.enumerated() {
                spots[.tab(tab)] = CGRect(x: 10, y: 10 + CGFloat(index) * 34, width: 200, height: 30)
            }
            return (spots, [])
        }
    }

    func test_on_a_feature_screen_he_asks_before_pressing_and_presses_only_after_yes() async {
        let steps = Steps()
        let selection = SettingsWindowSelection()
        let controller = make(selection: selection)
        steps.report(to: controller, optionalFirst: true)
        controller.ask("Set up dictation")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(controller.proposal?.action, .downloadOnDeviceModel(.dropFast), "the required step, not the optional one")
        XCTAssertTrue(steps.performed.isEmpty, "nothing is pressed while he asks")

        controller.confirmProposal()
        XCTAssertNil(controller.proposal)
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(steps.performed, [.downloadOnDeviceModel(.dropFast)], "the row's own action, once")
        XCTAssertEqual(controller.turns.last?.pressed, "Download free model")
        XCTAssertEqual(controller.feet, LilBroPlanner.perch(on: CGRect(x: 245, y: 300, width: 690, height: 50)),
                       "he ran to the row he pressed")
        XCTAssertEqual(controller.pose, .done)
    }

    func test_ill_do_it_presses_nothing() async {
        let steps = Steps()
        let controller = make()
        steps.report(to: controller)
        controller.ask("Set up dictation")
        await until { controller.proposal != nil && !controller.isBusy }
        controller.declineProposal()
        XCTAssertNil(controller.proposal)
        controller.confirmProposal()
        await Task.yield()
        XCTAssertTrue(steps.performed.isEmpty)
        XCTAssertNil(controller.turns.last?.pressed)
    }

    func test_closing_or_asking_again_withdraws_the_question() async {
        let steps = Steps()
        let controller = make()
        steps.report(to: controller)
        controller.ask("Set up dictation")
        await until { controller.proposal != nil && !controller.isBusy }
        controller.close()
        XCTAssertNil(controller.proposal)
        controller.confirmProposal()
        XCTAssertTrue(steps.performed.isEmpty)
    }

    func test_a_step_done_meanwhile_is_not_asked_about() async {
        let steps = Steps()
        let controller = make()
        steps.report(to: controller)
        controller.ask("Set up dictation")
        await until { controller.proposal != nil && !controller.isBusy }
        controller.update(pressables: [])
        XCTAssertNil(controller.proposal)
    }

    func test_tabs_and_keys_never_offer_a_press() async {
        let steps = Steps()
        let controller = make()
        steps.report(to: controller)
        controller.ask("change a hotkey")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertNil(controller.proposal)
    }

    func test_hidden_he_presses_at_once_after_yes() async {
        let steps = Steps()
        let controller = make(mascot: false)
        steps.report(to: controller)
        controller.ask("Set up dictation")
        await until { controller.proposal != nil && !controller.isBusy }
        controller.confirmProposal()
        await until { !controller.isBusy && controller.bubble == .full }
        XCTAssertEqual(steps.performed, [.downloadOnDeviceModel(.dropFast)])
        XCTAssertEqual(controller.feet, CGPoint(x: 176, y: 471), "nobody ran")
    }

    func test_each_step_says_what_pressing_it_does() {
        XCTAssertEqual(LilBroCopy.ask(.downloadOnDeviceModel(.dropFast)),
                       "One step left: Download free model. It downloads about 470 MB to this Mac. Press it?")
        XCTAssertEqual(LilBroCopy.consequence(of: .allow(.keyboard)), "macOS will ask you to allow it.")
        XCTAssertEqual(LilBroCopy.consequence(of: .restartWhytap), "Whytap quits and opens again; Settings closes.")
    }
}
