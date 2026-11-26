import Combine
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
                      reduceMotion: Bool = false,
                      sleep: ((TimeInterval) async -> Void)? = nil) -> LilBroController {
        let selection = given ?? SettingsWindowSelection()
        let preferences = LilBroPreferences(defaults: defaults)
        preferences.mascotVisible = mascot
        let controller = LilBroController(selection: selection, preferences: preferences, local: brain,
                                          remote: remote ?? Remote(.unavailable),
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
        controller.turnOnAnswers()
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
        controller.turnOnAnswers()
        controller.turnOffAnswers()
        controller.ask("Set up dictation")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertTrue(remote.asked.isEmpty)
        XCTAssertFalse(LilBroPreferences(defaults: defaults).answersFromWhytap)
    }

    /// ⋯ → Turn on answers only shows the disclosure; the choice is made by
    /// its button (builder review of #465, ticket 604).
    func test_the_menu_shows_the_disclosure_and_only_its_button_turns_answers_on() async {
        let remote = Remote(.answer(LilBroAnswer(paragraphs: ["Hi"])))
        let controller = make(remote: remote, reduceMotion: true)
        controller.ask("how do I dictate")
        await until { controller.bubble == .full && !controller.isBusy }
        controller.askToTurnOnAnswers()
        XCTAssertTrue(controller.consentShown)
        XCTAssertFalse(controller.answersFromWhytap, "the menu alone turns nothing on")
        XCTAssertFalse(LilBroPreferences(defaults: defaults).answersFromWhytap)
        controller.dismissConsent()
        XCTAssertFalse(controller.consentShown)
        controller.ask("Set up dictation")
        await until { controller.bubble == .full && !controller.isBusy && controller.turns.count == 2 }
        XCTAssertTrue(remote.asked.isEmpty, "Not now sends nothing")

        controller.askToTurnOnAnswers()
        controller.turnOnAnswers()
        XCTAssertFalse(controller.consentShown)
        XCTAssertTrue(LilBroPreferences(defaults: defaults).answersFromWhytap)
        controller.turnOffAnswers()
        XCTAssertFalse(controller.answersFromWhytap)
    }

    /// Where the disclosure shows and with which buttons: after the greeting
    /// and an unknown reply it offers Turn on answers (one line, full text
    /// under Details); asked for from ⋯ it shows after any reply, the
    /// unknown one too, with Not now.
    func test_the_disclosure_always_has_not_now_when_the_menu_asked_for_it() {
        let answer = LilBroReply.answer(LilBroAnswer(paragraphs: ["Hi"]))
        let unknown = LilBroReply.unknown(suggestions: [])
        XCTAssertEqual(LilBroOffer.placement(after: nil, answersOn: false, consentShown: false), .turnOn)
        XCTAssertEqual(LilBroOffer.placement(after: unknown, answersOn: false, consentShown: false), .turnOn)
        XCTAssertEqual(LilBroOffer.placement(after: answer, answersOn: false, consentShown: false), .none)
        for reply in [nil, answer, unknown, .offline] as [LilBroReply?] {
            XCTAssertEqual(LilBroOffer.placement(after: reply, answersOn: false, consentShown: true), .turnOnOrNotNow)
            XCTAssertEqual(LilBroOffer.placement(after: reply, answersOn: true, consentShown: true), .none)
        }
        XCTAssertEqual(LilBroOffer(turnOn: {}, notNow: {}).choices, ["Turn on answers", "Not now"])
        XCTAssertEqual(LilBroOffer(turnOn: {}).choices, ["Turn on answers"])
        XCTAssertEqual(LilBroOffer(asks: true, turnOn: {}).choices, ["Turn on and ask"])
        // Folded to one line, the full text is kept for Details.
        XCTAssertTrue(LilBroCopy.offerLine.contains("whytap.ai"))
        XCTAssertTrue(LilBroCopy.offer.contains("Claude Sonnet 5.5"))
        // The disclosure says what is sent again and kept.
        XCTAssertTrue(LilBroCopy.offer.contains("earlier whytap.ai questions with its answers, sent again"))
        XCTAssertTrue(LilBroCopy.offer.contains("90 days"))
        XCTAssertTrue(LilBroCopy.answersNote.contains("earlier whytap.ai questions and answers"))
    }

    func test_after_an_unknown_reply_the_menu_shows_the_disclosure_with_not_now() async {
        let controller = make(brain: Remote(.unknown(suggestions: ["Set up dictation"])), reduceMotion: true)
        controller.ask("zzz qqq")
        await until { controller.bubble == .full && !controller.isBusy }
        controller.askToTurnOnAnswers()
        let reply = controller.turns.last?.reply
        XCTAssertEqual(LilBroOffer.placement(after: reply, answersOn: controller.answersFromWhytap,
                                             consentShown: controller.consentShown), .turnOnOrNotNow)
        controller.dismissConsent()
        XCTAssertEqual(LilBroOffer.placement(after: reply, answersOn: controller.answersFromWhytap,
                                             consentShown: controller.consentShown), .turnOn)
        XCTAssertFalse(controller.answersFromWhytap)
    }

    /// Questions asked while answers were off never reach whytap.ai later, on
    /// the first opt-in or after turning answers off and on again.
    func test_questions_asked_on_this_mac_stay_out_of_what_goes_to_whytap() async {
        let remote = Remote(.answer(LilBroAnswer(paragraphs: ["Drop types what you say."])))
        let controller = make(remote: remote, reduceMotion: true)
        controller.ask("my private local question about dictation")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertTrue(remote.asked.isEmpty)

        controller.turnOnAnswers()
        controller.ask("first question to whytap")
        await until { controller.bubble == .full && !controller.isBusy && remote.asked.count == 1 }
        XCTAssertEqual(remote.asked[0].history, [], "the local turn is not history")

        controller.turnOffAnswers()
        controller.ask("another private local question about dictation")
        await until { controller.bubble == .full && !controller.isBusy && controller.turns.count == 3 }
        XCTAssertEqual(remote.asked.count, 1)

        controller.turnOnAnswers()
        controller.ask("second question to whytap")
        await until { controller.bubble == .full && !controller.isBusy && remote.asked.count == 2 }
        XCTAssertEqual(remote.asked[1].history.map(\.question), ["first question to whytap"])
        let sent = remote.asked.flatMap { [$0.text] + $0.history.map(\.question) }
        XCTAssertFalse(sent.contains { $0.contains("private") })
    }

    /// While answers are off the local guide gets no screen or history either.
    func test_a_local_question_carries_nothing_else() async {
        let local = Remote(.unknown(suggestions: []))
        let controller = make(brain: local, remote: Remote(.unavailable), reduceMotion: true)
        controller.ask("zzz something")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(local.asked.first, LilBroQuestion(text: "zzz something"))
    }

    func test_offline_try_again_asks_once_more_in_the_same_place() async {
        let remote = Remote(.offline)
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        let controller = make(selection: selection, remote: remote, reduceMotion: true)
        controller.turnOnAnswers()
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
        controller.turnOnAnswers()
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
        /// Which registration ran: a re-registered row's new closure, not the old one.
        private(set) var by: [String] = []
        func report(to controller: LilBroController, optionalFirst: Bool = false, tag: String = "first",
                    feature: AppFeature = .drop, action: FeatureSetupAction = .downloadOnDeviceModel(.dropFast),
                    hasButton: Bool = true) {
            let perform: @MainActor (FeatureSetupAction) -> Void = { [weak self] in
                self?.performed.append($0)
                self?.by.append(tag)
            }
            let model = LilBroPressable(feature: feature, id: "model.dropFast", action: action,
                                        optional: false, hasButton: hasButton, perform: perform)
            let extra = LilBroPressable(feature: feature, id: "permission.microphone", action: .allow(.microphone),
                                        optional: true, hasButton: true, perform: perform)
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
        XCTAssertEqual(LilBroCopy.ask(.downloadOnDeviceModel(.dropFast), steps: 1),
                       "One step left: Download free model. It downloads about 470 MB to this Mac. Press it?")
        XCTAssertEqual(LilBroCopy.ask(.allow(.keyboard), steps: 3),
                       "3 steps left. First: \(FeatureSetupAction.allow(.keyboard).title). "
                       + "macOS asks you to allow it, or System Settings opens where you turn it on. Press it?")
        XCTAssertEqual(LilBroCopy.consequence(of: .restartWhytap), "Whytap quits and opens again; Settings closes.")
    }

    // MARK: Stale or wrong presses (builder review of #468, ticket 609)

    /// Drop's screen open, the offer made.
    private func offered(_ steps: Steps, mascot: Bool = true,
                         sleep: ((TimeInterval) async -> Void)? = nil) async -> (LilBroController, SettingsWindowSelection) {
        let selection = SettingsWindowSelection(selectedTab: .features)
        let controller = make(selection: selection, mascot: mascot, sleep: sleep)
        steps.report(to: controller)
        selection.open(.drop)  // already there: no punches on the way
        controller.ask("Set up dictation")
        await until { controller.proposal != nil && !controller.isBusy }
        return (controller, selection)
    }

    func test_with_several_required_steps_he_says_how_many() async {
        let steps = Steps()
        let selection = SettingsWindowSelection(selectedTab: .features)
        let controller = make(selection: selection)
        let perform: @MainActor (FeatureSetupAction) -> Void = { _ in }
        controller.update(pressables: [
            LilBroPressable(feature: .drop, id: "model.dropFast", action: .downloadOnDeviceModel(.dropFast),
                            optional: false, hasButton: true, perform: perform),
            LilBroPressable(feature: .drop, id: "permission.keyboard", action: .allow(.keyboard),
                            optional: false, hasButton: true, perform: perform),
            LilBroPressable(feature: .drop, id: "permission.microphone", action: .allow(.microphone),
                            optional: false, hasButton: true, perform: perform),
        ])
        _ = steps
        controller.ask("Set up dictation")
        await until { controller.proposal != nil && !controller.isBusy }
        XCTAssertEqual(controller.proposalSteps, 3)
        XCTAssertTrue(LilBroCopy.ask(controller.proposal!.action, steps: controller.proposalSteps).hasPrefix("3 steps left. First:"))
    }

    func test_a_row_whose_action_changed_before_yes_is_not_pressed() async {
        let steps = Steps()
        let (controller, _) = await offered(steps)
        steps.report(to: controller, tag: "changed", action: .useOnDeviceModel(.dropFast))
        XCTAssertNil(controller.proposal, "a different action is not the one asked about")
        controller.confirmProposal()
        await settleDown()
        XCTAssertTrue(steps.performed.isEmpty)
    }

    func test_a_step_done_while_he_runs_to_it_is_not_pressed() async {
        let gate = Gate { $0 == 0.43 }
        let steps = Steps()
        let (controller, _) = await offered(steps, sleep: { await gate.sleep($0) })
        controller.confirmProposal()
        await until { controller.flash != nil && gate.waiting == 1 }
        controller.update(pressables: [])  // the person pressed it meanwhile
        gate.release()
        await until { !controller.isBusy && controller.bubble == .full }
        XCTAssertTrue(steps.performed.isEmpty, "checked again right before pressing")
        XCTAssertNil(controller.turns.last?.pressed)
    }

    func test_a_step_done_right_after_yes_is_not_pressed_without_the_mascot_either() async {
        let steps = Steps()
        let (controller, _) = await offered(steps, mascot: false)
        controller.confirmProposal()
        controller.update(pressables: [])
        await until { !controller.isBusy && controller.bubble == .full }
        XCTAssertTrue(steps.performed.isEmpty)
    }

    func test_leaving_the_feature_withdraws_the_offer_even_for_the_same_row_elsewhere() async {
        let steps = Steps()
        let (controller, selection) = await offered(steps)
        selection.open(.agent)
        steps.report(to: controller, tag: "agent", feature: .agent)  // Agent has an identical row
        XCTAssertNil(controller.proposal)
        controller.confirmProposal()
        await settleDown()
        XCTAssertTrue(steps.performed.isEmpty)
    }

    func test_after_leaving_mid_run_nothing_is_pressed_on_the_new_screen() async {
        let gate = Gate { $0 == 0.43 }
        let steps = Steps()
        let (controller, selection) = await offered(steps, sleep: { await gate.sleep($0) })
        controller.confirmProposal()
        await until { controller.flash != nil && gate.waiting == 1 }
        selection.open(.agent)
        steps.report(to: controller, tag: "agent", feature: .agent)
        gate.release()
        await until { !controller.isBusy && controller.bubble == .full }
        XCTAssertTrue(steps.performed.isEmpty)
    }

    func test_an_unchanged_step_runs_once_through_its_current_registration() async {
        let steps = Steps()
        let (controller, _) = await offered(steps, mascot: false)
        steps.report(to: controller, tag: "redrawn")  // same step, new closure after a redraw
        XCTAssertNotNil(controller.proposal)
        controller.confirmProposal()
        await until { !controller.isBusy && controller.bubble == .full }
        XCTAssertEqual(steps.performed, [.downloadOnDeviceModel(.dropFast)])
        XCTAssertEqual(steps.by, ["redrawn"])
    }

    func test_rows_still_from_the_last_screen_are_never_offered_and_the_new_ones_are() async {
        let steps = Steps()
        let selection = SettingsWindowSelection(selectedTab: .features)
        let controller = make(selection: selection)
        steps.report(to: controller, tag: "screenshots", feature: .screenshots)
        controller.ask("Set up dictation")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertNil(controller.proposal, "Screenshots' rows are not Drop's")
        steps.report(to: controller, tag: "drop")  // Drop's rows report a moment later
        XCTAssertEqual(controller.proposal?.feature, .drop)
        controller.confirmProposal()
        await until { !controller.isBusy && controller.bubble == .full }
        XCTAssertEqual(steps.by, ["drop"])
    }

    func test_a_model_row_that_shows_a_picker_is_left_to_the_person() async {
        let steps = Steps()
        let selection = SettingsWindowSelection(selectedTab: .features)
        let controller = make(selection: selection)
        steps.report(to: controller, action: .chooseModel(.dropFast), hasButton: false)
        controller.ask("Set up dictation")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertNil(controller.proposal, "Choose a model is the row's picker, not a button he presses")

        let model = FeatureRequirement(kind: .model(.dropFast), title: "Speech-to-text model", detail: "")
        let check = { (action: FeatureSetupAction) in
            FeatureCheck(requirement: model, state: .unmet(reason: "", action: action))
        }
        XCTAssertFalse(LilBroPressable.rowHasButton(check(.chooseModel(.dropFast)), action: .chooseModel(.dropFast)))
        for action in [FeatureSetupAction.downloadOnDeviceModel(.dropFast), .useOnDeviceModel(.dropFast),
                       .addKey(.dropFast), .fixKey(.dropFast), .addOpenAIKey] {
            XCTAssertTrue(LilBroPressable.rowHasButton(check(action), action: action), "\(action)")
        }
        let keyboard = FeatureCheck(requirement: FeatureRequirement(kind: .permission(.keyboard), title: "", detail: ""),
                                    state: .unmet(reason: "", action: .allow(.keyboard)))
        XCTAssertTrue(LilBroPressable.rowHasButton(keyboard, action: .allow(.keyboard)))
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

    func test_closing_while_he_punches_the_step_presses_nothing() async {
        let gate = Gate { $0 == 0.43 }
        let steps = Steps()
        let selection = SettingsWindowSelection(selectedTab: .features)
        let controller = make(selection: selection, sleep: { await gate.sleep($0) })
        steps.report(to: controller)
        selection.open(.drop)
        controller.ask("Set up dictation")
        await until { controller.proposal != nil && !controller.isBusy }
        controller.confirmProposal()
        await until { controller.flash != nil && gate.waiting == 1 }
        controller.close()
        gate.release()
        await settleDown()
        XCTAssertTrue(steps.performed.isEmpty, "a cancelled press never runs the step")
        XCTAssertNil(controller.turns.last?.pressed)
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
    /// examples, what to ask next) wait behind More, and every new question
    /// starts short again.
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

    /// A question this Mac did not understand (another language): "Turn on
    /// and ask" turns answers on and sends that one question to whytap.ai;
    /// the earlier local question never goes.
    func test_turn_on_and_ask_sends_only_the_question_this_mac_did_not_understand() async {
        let remote = Remote(.answer(LilBroAnswer(paragraphs: ["Meeting Notes takes notes."],
                                                 destination: .feature(.meetings))))
        let controller = make(remote: remote, reduceMotion: true)
        controller.ask("how do I dictate")
        await until { controller.bubble == .full && !controller.isBusy }
        controller.ask("как мне использовать митинги")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertEqual(controller.turns.last?.reply?.isUnknown, true)
        XCTAssertTrue(controller.turnOnAsks)
        XCTAssertTrue(remote.asked.isEmpty, "nothing is sent before the press")
        controller.turnOnAnswers()
        await until { controller.bubble == .full && !controller.isBusy && controller.turns.last?.reply?.isUnknown == false }
        XCTAssertEqual(remote.asked.map(\.text), ["как мне использовать митинги"])
        XCTAssertEqual(remote.asked.first?.history, [], "the local question stays on this Mac")
        XCTAssertEqual(controller.turns.count, 2, "the question is asked again in its place")
        XCTAssertEqual(controller.turns.last?.opened, "Meeting Notes")
    }

    /// Turned on from ⋯ after an answer, nothing is sent by the press itself.
    func test_turning_answers_on_after_an_answer_sends_nothing() async {
        let remote = Remote(.unavailable)
        let controller = make(remote: remote, reduceMotion: true)
        controller.ask("how do I dictate")
        await until { controller.bubble == .full && !controller.isBusy }
        XCTAssertFalse(controller.turnOnAsks)
        controller.turnOnAnswers()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(remote.asked.isEmpty)
    }
}
