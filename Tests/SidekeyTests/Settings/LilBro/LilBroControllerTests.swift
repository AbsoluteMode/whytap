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
        func reply(to question: String) async -> LilBroReply { reply }
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
                      brain: LilBroBrain? = nil, mascot: Bool = true,
                      reduceMotion: Bool = false,
                      sleep: ((TimeInterval) async -> Void)? = nil) -> LilBroController {
        let selection = given ?? SettingsWindowSelection()
        let preferences = LilBroPreferences(defaults: defaults)
        preferences.mascotVisible = mascot
        let controller = LilBroController(selection: selection, preferences: preferences, brain: brain,
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
                                    preferences: LilBroPreferences(defaults: defaults), brain: nil,
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
}
