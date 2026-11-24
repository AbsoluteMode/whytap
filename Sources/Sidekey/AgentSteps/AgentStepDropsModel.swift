import Foundation

/// The life of the drops that show what the Agent changed in Whytap: one
/// drop per step, budding in order right of the island, at most three at a
/// time (a fourth pushes the first back into the island), then leaving in
/// the reverse order. Nothing to answer and no keys: the user asked for the
/// change, the drops only show it was made.
/// WHY: .project-docs/decisions/2026-11-24-agent-step-drops.md
@MainActor
final class AgentStepDropsModel: ObservableObject {
    enum Stage: Equatable { case hidden, emerging, open, retracting }

    struct Drop: Identifiable, Equatable {
        let id: Int
        let step: AgentAppStep
    }

    enum Timing {
        /// The panel is on screen this long before the first drop: its
        /// arrival is animated instead of already there, and the island's
        /// wing has folded back by then.
        static let lead: TimeInterval = 0.3
        /// Each drop buds from the one before it this much later.
        static let budStep: TimeInterval = 0.22
        /// With more steps than fit, the row moves on by one this often.
        static let advance: TimeInterval = 1.1
        /// The full row stays this long, plus `holdPerDrop` for each drop
        /// after the first.
        static let hold: TimeInterval = 3.2
        static let holdPerDrop: TimeInterval = 0.8
        /// Drops leave one by one this far apart, last first.
        static let retractStep: TimeInterval = 0.12
        /// The last drop's own exit, before the panel leaves the screen.
        static let settle: TimeInterval = 0.5
        /// Reduce Motion, and a busy island: the drops only fade.
        static let fade: TimeInterval = 0.16
    }

    static let maxVisible = 3

    typealias Cancel = () -> Void
    typealias Schedule = (_ after: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Cancel

    @Published private(set) var stage: Stage = .hidden
    /// The drops on screen, in chain order from the island outwards.
    @Published private(set) var visible: [Drop] = []
    /// The row is only fading (Reduce Motion, a busy island), not budding.
    @Published private(set) var fading = false

    /// True when the drops start to show, false once the last one is gone:
    /// the panel is ordered in before the first drop and out after the last.
    var onVisibleChange: ((Bool) -> Void)?

    private let schedule: Schedule
    private let reduceMotion: () -> Bool
    private var pending: [Cancel] = []

    init(schedule: @escaping Schedule = AgentStepDropsModel.mainQueueSchedule,
         reduceMotion: @escaping () -> Bool = { false }) {
        self.schedule = schedule
        self.reduceMotion = reduceMotion
    }

    var isVisible: Bool { stage != .hidden }
    var isReducedMotion: Bool { reduceMotion() }

    /// How long a full row of `count` drops stays before it leaves.
    static func holdSeconds(count: Int) -> TimeInterval {
        Timing.hold + Timing.holdPerDrop * Double(max(0, min(count, maxVisible) - 1))
    }

    /// Shows a finished turn's steps. A row still on screen is replaced.
    func show(_ steps: [AgentAppStep]) {
        guard !steps.isEmpty else { return }
        if stage != .hidden { finishHidden() }
        let drops = steps.enumerated().map { Drop(id: $0.offset, step: $0.element) }
        stage = .emerging
        fading = reduceMotion()
        onVisibleChange?(true)
        let first = min(drops.count, Self.maxVisible)
        let last = drops.count - 1
        var time = Timing.lead
        for index in drops.indices {
            // More steps than fit: the oldest goes back into the island as
            // the next one buds at the far end.
            if index >= first { time += Timing.advance } else if index > 0 { time += Timing.budStep }
            after(time) {
                if index >= first { $0.visible.removeFirst() }
                $0.visible.append(drops[index])
                if index == last { $0.stage = .open }
            }
        }
        after(time + Self.holdSeconds(count: first)) { $0.retract() }
    }

    /// The island left idle (a new take, the Agent, an answer), or the Mac
    /// sleeps: the drops fade at once.
    func dismissForBusyIsland() {
        guard stage != .hidden else { return }
        cancelAll()
        stage = .retracting
        fading = true
        visible = []
        after(Timing.fade) { $0.finishHidden() }
    }

    private func retract() {
        guard stage == .open || stage == .emerging else { return }
        cancelAll()
        stage = .retracting
        if reduceMotion() {
            visible = []
            after(Timing.fade) { $0.finishHidden() }
            return
        }
        // Reverse of the chain: the farthest drop goes first, each into the
        // one before it, the first into the island.
        let count = visible.count
        for step in 0..<count {
            after(Timing.retractStep * Double(step)) { if !$0.visible.isEmpty { $0.visible.removeLast() } }
        }
        after(Timing.retractStep * Double(max(0, count - 1)) + Timing.settle) { $0.finishHidden() }
    }

    private func finishHidden() {
        cancelAll()
        visible = []
        fading = false
        stage = .hidden
        onVisibleChange?(false)
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping @MainActor (AgentStepDropsModel) -> Void) {
        pending.append(schedule(seconds) { [weak self] in
            guard let self else { return }
            work(self)
        })
    }

    private func cancelAll() {
        pending.forEach { $0() }
        pending.removeAll()
    }

    nonisolated static let mainQueueSchedule: Schedule = { seconds, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }
}
