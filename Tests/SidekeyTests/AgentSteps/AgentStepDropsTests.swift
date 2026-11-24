import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Sidekey

/// The drops that show what the Agent changed in Whytap: order, how many at
/// once, how they leave, and when they may show at all.
/// WHY: .project-docs/decisions/2026-11-24-agent-step-drops.md
@MainActor
final class AgentStepDropsTests: XCTestCase {
    /// A clock the test moves by hand.
    private final class Clock {
        private var items: [(at: TimeInterval, id: Int, work: @MainActor () -> Void)] = []
        private var cancelled: Set<Int> = []
        private var nextID = 0
        private(set) var time: TimeInterval = 0

        lazy var schedule: AgentStepDropsModel.Schedule = { [unowned self] seconds, work in
            let id = self.nextID
            self.nextID += 1
            self.items.append((self.time + seconds, id, work))
            return { self.cancelled.insert(id) }
        }

        @MainActor func advance(_ seconds: TimeInterval) {
            let target = time + seconds
            while let next = items.enumerated()
                .filter({ $0.element.at <= target + 0.0001 })
                .min(by: { ($0.element.at, $0.element.id) < ($1.element.at, $1.element.id) }) {
                items.remove(at: next.offset)
                time = max(time, next.element.at)
                if !cancelled.contains(next.element.id) { next.element.work() }
            }
            time = target
        }
    }

    private typealias Timing = AgentStepDropsModel.Timing

    private func step(_ line: String, _ operation: String = "vocab_add") -> AgentAppStep {
        AgentAppStep(operation: operation, line: line)
    }

    private func lines(_ model: AgentStepDropsModel) -> [String] { model.visible.map(\.step.line) }

    private func model(_ clock: Clock, reduceMotion: Bool = false) -> (AgentStepDropsModel, () -> [Bool]) {
        let model = AgentStepDropsModel(schedule: clock.schedule, reduceMotion: { reduceMotion })
        var shown: [Bool] = []
        model.onVisibleChange = { shown.append($0) }
        return (model, { shown })
    }

    // MARK: One step

    func testOneStepBudsAfterThePanelIsUpStaysAndLeaves() {
        let clock = Clock()
        let (model, shown) = model(clock)
        model.show([step("Vocab + whytap")])
        XCTAssertEqual(shown(), [true], "the panel is up first")
        XCTAssertEqual(lines(model), [], "so the drop's arrival is animated, not already there")
        XCTAssertEqual(model.stage, .emerging)
        clock.advance(Timing.lead)
        XCTAssertEqual(lines(model), ["Vocab + whytap"])
        XCTAssertEqual(model.stage, .open)
        clock.advance(AgentStepDropsModel.holdSeconds(count: 1) - 0.01)
        XCTAssertEqual(lines(model), ["Vocab + whytap"], "still there just before its time is up")
        clock.advance(0.02)
        XCTAssertEqual(lines(model), [])
        XCTAssertEqual(model.stage, .retracting)
        XCTAssertEqual(shown(), [true], "the panel stays until the drop's exit has played")
        clock.advance(Timing.settle)
        XCTAssertEqual(model.stage, .hidden)
        XCTAssertEqual(shown(), [true, false])
    }

    // MARK: Three steps

    func testThreeStepsBudInOrderOneAfterAnotherAndLeaveInReverse() {
        let clock = Clock()
        let (model, shown) = model(clock)
        model.show([step("Vocab + whytap"), step("Filler + короче", "filler_add"), step("Drop mode → Smart", "set_setting")])
        clock.advance(Timing.lead)
        XCTAssertEqual(lines(model), ["Vocab + whytap"])
        clock.advance(Timing.budStep)
        XCTAssertEqual(lines(model), ["Vocab + whytap", "Filler + короче"])
        XCTAssertEqual(model.stage, .emerging)
        clock.advance(Timing.budStep)
        XCTAssertEqual(lines(model), ["Vocab + whytap", "Filler + короче", "Drop mode → Smart"])
        XCTAssertEqual(model.stage, .open)
        clock.advance(AgentStepDropsModel.holdSeconds(count: 3))
        XCTAssertEqual(lines(model), ["Vocab + whytap", "Filler + короче"], "the farthest goes first")
        clock.advance(Timing.retractStep)
        XCTAssertEqual(lines(model), ["Vocab + whytap"])
        clock.advance(Timing.retractStep)
        XCTAssertEqual(lines(model), [])
        clock.advance(Timing.settle)
        XCTAssertEqual(shown(), [true, false])
        // Three drops get more time than one.
        XCTAssertGreaterThan(AgentStepDropsModel.holdSeconds(count: 3), AgentStepDropsModel.holdSeconds(count: 1))
    }

    // MARK: More than fit

    func testFiveStepsNeverShowMoreThanThreeAndEveryStepIsSeenInOrder() {
        let clock = Clock()
        let (model, _) = model(clock)
        let all = (1...5).map { step("Vocab + word\($0)") }
        var seen: [String] = []
        var most = 0
        let watch = model.$visible.sink { drops in
            most = max(most, drops.count)
            for drop in drops where !seen.contains(drop.step.line) { seen.append(drop.step.line) }
        }
        model.show(all)
        clock.advance(Timing.lead + 2 * Timing.budStep)
        XCTAssertEqual(lines(model), ["Vocab + word1", "Vocab + word2", "Vocab + word3"])
        XCTAssertEqual(model.stage, .emerging, "two more are coming")
        clock.advance(Timing.advance)
        XCTAssertEqual(lines(model), ["Vocab + word2", "Vocab + word3", "Vocab + word4"], "the first went back into the island")
        clock.advance(Timing.advance)
        XCTAssertEqual(lines(model), ["Vocab + word3", "Vocab + word4", "Vocab + word5"])
        XCTAssertEqual(model.stage, .open)
        clock.advance(AgentStepDropsModel.holdSeconds(count: 3) + 3 * Timing.retractStep + Timing.settle)
        XCTAssertEqual(model.stage, .hidden)
        XCTAssertEqual(seen, all.map(\.line))
        XCTAssertEqual(most, AgentStepDropsModel.maxVisible)
        watch.cancel()
    }

    // MARK: Interruptions

    func testABusyIslandFadesTheDropsAtOnceAndNothingComesBack() {
        let clock = Clock()
        let (model, shown) = model(clock)
        model.show([step("Vocab + a"), step("Vocab + b"), step("Vocab + c")])
        clock.advance(Timing.lead + Timing.budStep)
        XCTAssertEqual(model.visible.count, 2)
        model.dismissForBusyIsland()
        XCTAssertEqual(lines(model), [])
        XCTAssertTrue(model.fading)
        clock.advance(Timing.fade)
        XCTAssertEqual(model.stage, .hidden)
        XCTAssertEqual(shown(), [true, false])
        clock.advance(30)
        XCTAssertEqual(lines(model), [], "the third drop's timer was cancelled")
        XCTAssertEqual(shown(), [true, false])
        model.dismissForBusyIsland()
        XCTAssertEqual(shown(), [true, false], "nothing to put out twice")
    }

    func testANewTurnsStepsReplaceARowStillOnScreen() {
        let clock = Clock()
        let (model, shown) = model(clock)
        model.show([step("Vocab + old")])
        clock.advance(Timing.lead + 1)
        model.show([step("Filler + new", "filler_add")])
        XCTAssertEqual(shown(), [true, false, true])
        clock.advance(Timing.lead)
        XCTAssertEqual(lines(model), ["Filler + new"])
        clock.advance(AgentStepDropsModel.holdSeconds(count: 1) - 0.1)
        XCTAssertEqual(lines(model), ["Filler + new"], "the old row's timer does not end the new one early")
    }

    func testReduceMotionOnlyFades() {
        let clock = Clock()
        let (model, _) = model(clock, reduceMotion: true)
        model.show([step("Vocab + a"), step("Vocab + b")])
        XCTAssertTrue(model.fading)
        clock.advance(Timing.lead + Timing.budStep + AgentStepDropsModel.holdSeconds(count: 2))
        XCTAssertEqual(lines(model), [], "both go together")
        clock.advance(Timing.fade)
        XCTAssertEqual(model.stage, .hidden)
    }

    func testNoStepsShowNothing() {
        let clock = Clock()
        let (model, shown) = model(clock)
        model.show([])
        XCTAssertEqual(model.stage, .hidden)
        XCTAssertEqual(shown(), [])
    }

    // MARK: When they may show

    private func controller(_ clock: Clock, now: @escaping () -> Date = Date.init)
        -> (AgentStepDropsController, CurrentValueSubject<Bool, Never>, () -> [String]) {
        let idle = CurrentValueSubject<Bool, Never>(true)
        var announced: [String] = []
        let controller = AgentStepDropsController(
            model: AgentStepDropsModel(schedule: clock.schedule), present: { _ in },
            islandIdle: idle.eraseToAnyPublisher(), now: now, announce: { announced.append($0) })
        return (controller, idle, { announced })
    }

    func testStepsShowOnAnIdleIslandAndAreAnnounced() {
        let clock = Clock()
        let (controller, _, announced) = controller(clock)
        controller.show([step("Vocab + whytap"), step("Filler + короче", "filler_add")])
        clock.advance(Timing.lead + Timing.budStep)
        XCTAssertEqual(lines(controller.model), ["Vocab + whytap", "Filler + короче"])
        XCTAssertEqual(announced(), ["Vocab + whytap. Filler + короче"])
    }

    func testStepsThatArriveDuringADictationWaitForItToEnd() {
        let clock = Clock()
        var date = Date(timeIntervalSince1970: 1_000)
        let (controller, idle, announced) = controller(clock, now: { date })
        idle.send(false)
        controller.show([step("Vocab + whytap")])
        clock.advance(5)
        XCTAssertFalse(controller.model.isVisible)
        XCTAssertEqual(announced(), [])
        date += 5
        idle.send(true)
        clock.advance(Timing.lead)
        XCTAssertEqual(lines(controller.model), ["Vocab + whytap"])
        XCTAssertEqual(announced(), ["Vocab + whytap"])
    }

    func testStepsThatWaitedTooLongAreNotShownLate() {
        let clock = Clock()
        var date = Date(timeIntervalSince1970: 1_000)
        let (controller, idle, _) = controller(clock, now: { date })
        idle.send(false)
        controller.show([step("Vocab + whytap")])
        date += AgentStepDropsController.waitLimit + 1
        idle.send(true)
        clock.advance(5)
        XCTAssertFalse(controller.model.isVisible, "they are in History")
    }

    func testANewTakeOrAgentTurnPutsShownDropsOutAndSleepDropsWaitingOnes() {
        let clock = Clock()
        let (controller, idle, _) = controller(clock)
        controller.show([step("Vocab + whytap")])
        clock.advance(Timing.lead)
        XCTAssertEqual(controller.model.visible.count, 1)
        idle.send(false)
        XCTAssertEqual(controller.model.visible.count, 0)
        clock.advance(Timing.fade)
        XCTAssertFalse(controller.model.isVisible)
        // Steps waiting for the island are dropped by sleep or quit.
        controller.show([step("Vocab + later")])
        controller.dismiss()
        idle.send(true)
        clock.advance(5)
        XCTAssertFalse(controller.model.isVisible)
    }

    // MARK: Panel

    func testPanelFrameStartsUnderTheIslandsEdgeAndStaysOnItsScreen() {
        let island = NSRect(x: 600, y: 950, width: 300, height: 32)
        let frame = AgentStepDropsPanel.frame(island: island, screenMaxX: 1512)
        XCTAssertEqual(frame.minX, island.maxX - AgentStepDropsView.Metrics.islandOverlap)
        XCTAssertEqual(frame.minY, island.minY)
        XCTAssertEqual(frame.height, island.height)
        XCTAssertLessThanOrEqual(frame.maxX, 1512)
        XCTAssertEqual(AgentStepDropsPanel.frame(island: island, screenMaxX: 1000).maxX, 1000)
        // The first drop rests clear of the island.
        XCTAssertGreaterThan(AgentStepDropsView.Metrics.leading, AgentStepDropsView.Metrics.islandOverlap)
    }

    func testGlassKindFollowsTransparencySetting() {
        XCTAssertEqual(AgentStepGlass.kind(reduceTransparency: true), .opaque)
        XCTAssertNotEqual(AgentStepGlass.kind(reduceTransparency: false), .opaque)
    }

    // MARK: Offscreen render

    /// Renders the real drop view without any window and reads
    /// the text back; with AGENT_STEP_DROPS_RENDER_DIR set it also writes
    /// the storyboard frames used to review the motion.
    func testRowRendersItsStepsOffScreen() throws {
        let frames = AgentStepDropsStoryboard.frames(steps: [
            step("Vocab + whytap"), step("Filler + короче", "filler_add"), step("Drop mode → Smart", "set_setting")
        ])
        XCTAssertGreaterThan(frames.count, 20)
        let rest = try XCTUnwrap(frames.first { $0.drops.count == 3 && $0.drops.allSatisfy { $0.progress == 1 } })
        for dark in [false, true] {
            let image = try XCTUnwrap(AgentStepDropsStoryboard.render(rest, dark: dark, scale: 2))
            XCTAssertGreaterThan(image.width, 600)
            let text = try AgentStepDropsStoryboard.recognizedText(image)
            XCTAssertTrue(text.contains("whytap"), text)
            XCTAssertTrue(text.contains("Smart"), text)
        }
        guard let output = ProcessInfo.processInfo.environment["AGENT_STEP_DROPS_RENDER_DIR"] else { return }
        try AgentStepDropsStoryboard.write(to: URL(fileURLWithPath: output, isDirectory: true))
    }
}
