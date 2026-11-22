import Foundation

/// The life of one row of suggestion drops right of the island: a chain buds
/// out (icon, action, Y, N), stays 10 s with no visible timer (hovering
/// pauses it), answers with Y/N by click or ⌃Y/⌃N, and retracts in the
/// reverse order. One suggestion at a time; a busy island puts them out.
/// WHY: .project-docs/decisions/2026-11-22-drop-learning-drops.md
@MainActor
final class DropLearningDropsModel: ObservableObject {
    enum Stage: Equatable { case hidden, emerging, open, confirming, retracting }
    enum Outcome: Equatable { case accepted, declined, expired }
    enum Button: Equatable { case yes, no }

    /// The whole chain stays under 0.8 s each way.
    enum Timing {
        static let showSeconds: TimeInterval = 10
        /// Each drop buds from the one before it this much later.
        static let budStep: TimeInterval = 0.1
        static let emerge: TimeInterval = 0.7
        static let confirm: TimeInterval = 0.55
        static let retract: TimeInterval = 0.6
        /// Reduce Motion: the drops only fade.
        static let fade: TimeInterval = 0.16
    }

    static let dropCount = 4

    typealias Cancel = () -> Void
    typealias Schedule = (_ after: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Cancel

    @Published private(set) var stage: Stage = .hidden
    @Published private(set) var content: DropLearningDropContent?
    /// How many drops of the chain are out (0...4), in chain order.
    @Published private(set) var dropsOut = 0
    @Published private(set) var hovered = false
    /// The pointer is on Y or N: that drop shows ✓/✕ instead of its letter.
    @Published private(set) var hoveredButton: Button?
    /// ⌃ is held while the drops are open: Y and N light up.
    @Published private var controlModifierDown = false
    /// The icon drop swells once and shows ✓ (or ↗ for a full Vocab).
    @Published private(set) var confirmed = false

    /// Answers go to the learning coordinator.
    var onOutcome: ((DropLearningSuggestion, Outcome) -> Void)?
    /// True when the drops start to show, false once they are gone: the panel
    /// orders in and out and ⌃Y/⌃N are captured only in between.
    var onVisibleChange: ((Bool) -> Void)?

    private(set) var suggestion: DropLearningSuggestion?
    private let schedule: Schedule
    private let now: () -> Date
    private let reduceMotion: () -> Bool
    private var pending: [Cancel] = []
    private var expiry: Cancel?
    private var remaining: TimeInterval = Timing.showSeconds
    private var openSince: Date?

    init(
        schedule: @escaping Schedule = DropLearningDropsModel.mainQueueSchedule,
        now: @escaping () -> Date = Date.init,
        reduceMotion: @escaping () -> Bool = { false }
    ) {
        self.schedule = schedule
        self.now = now
        self.reduceMotion = reduceMotion
    }

    var isVisible: Bool { stage != .hidden }
    var controlHeld: Bool { stage == .open && controlModifierDown }
    var isReducedMotion: Bool { reduceMotion() }

    /// Shows a suggestion if nothing is on screen. Returns false when the
    /// drops are already busy with another one (it is offered again the next
    /// time the same correction is seen).
    @discardableResult
    func show(_ suggestion: DropLearningSuggestion) -> Bool {
        guard stage == .hidden else { return false }
        self.suggestion = suggestion
        content = DropLearningDropContent.make(suggestion.candidate)
        confirmed = false
        hovered = false
        hoveredButton = nil
        controlModifierDown = false
        remaining = Timing.showSeconds
        stage = .emerging
        onVisibleChange?(true)
        if reduceMotion() {
            dropsOut = Self.dropCount
            after(Timing.fade) { $0.becomeOpen() }
        } else {
            dropsOut = 1
            for index in 2...Self.dropCount {
                after(Timing.budStep * Double(index - 1)) { $0.dropsOut = max($0.dropsOut, index) }
            }
            after(Timing.emerge) { $0.becomeOpen() }
        }
        return true
    }

    // MARK: - Input

    func answer(_ button: Button) {
        guard stage == .open, let suggestion else { return }
        stopExpiry()
        switch button {
        case .yes:
            onOutcome?(suggestion, .accepted)
            stage = .confirming
            confirmed = true
            after(reduceMotion() ? Timing.fade : Timing.confirm) { $0.retract() }
        case .no:
            onOutcome?(suggestion, .declined)
            retract()
        }
    }

    /// The pointer entered or left the row: hovering pauses the 10 s.
    func setHovered(_ value: Bool) {
        let value = value && (stage == .open || stage == .emerging)
        guard hovered != value else { return }
        hovered = value
        if !value { hoveredButton = nil }
        guard stage == .open else { return }
        value ? pauseExpiry() : startExpiry()
    }

    func setHoveredButton(_ button: Button?) {
        guard hoveredButton != button else { return }
        hoveredButton = stage == .open || stage == .emerging ? button : nil
    }

    func setControlHeld(_ held: Bool) {
        if controlModifierDown != held { controlModifierDown = held }
    }

    /// The island left idle (a new take, the agent, a failure): the drops go
    /// out at once and the suggestion counts as let go.
    func dismissForBusyIsland() {
        guard stage != .hidden else { return }
        if let suggestion, stage == .emerging || stage == .open {
            onOutcome?(suggestion, .expired)
        }
        cancelAll()
        dropsOut = 0
        finishHidden()
    }

    // MARK: - Stages

    private func becomeOpen() {
        guard stage == .emerging else { return }
        dropsOut = Self.dropCount
        stage = .open
        if !hovered { startExpiry() }
    }

    private func expire() {
        guard stage == .open, let suggestion else { return }
        onOutcome?(suggestion, .expired)
        retract()
    }

    private func retract() {
        guard stage == .open || stage == .confirming || stage == .emerging else { return }
        cancelAll()
        stage = .retracting
        hovered = false
        hoveredButton = nil
        controlModifierDown = false
        if reduceMotion() {
            dropsOut = 0
            after(Timing.fade) { $0.finishHidden() }
            return
        }
        // Exact reverse of the chain: N, Y, action, icon.
        let start = dropsOut
        dropsOut = max(0, start - 1)
        if start > 1 {
            for step in 1..<start {
                after(Timing.budStep * Double(step)) { $0.dropsOut = min($0.dropsOut, start - 1 - step) }
            }
        }
        after(Timing.retract) { $0.finishHidden() }
    }

    private func finishHidden() {
        cancelAll()
        stage = .hidden
        dropsOut = 0
        suggestion = nil
        content = nil
        confirmed = false
        hovered = false
        hoveredButton = nil
        controlModifierDown = false
        onVisibleChange?(false)
    }

    // MARK: - Timer (no visible countdown)

    private func startExpiry() {
        stopExpiry()
        openSince = now()
        let left = remaining
        expiry = schedule(left) { [weak self] in self?.expire() }
    }

    private func pauseExpiry() {
        if let openSince { remaining = max(0, remaining - now().timeIntervalSince(openSince)) }
        stopExpiry()
    }

    private func stopExpiry() {
        expiry?()
        expiry = nil
        openSince = nil
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping @MainActor (DropLearningDropsModel) -> Void) {
        pending.append(schedule(seconds) { [weak self] in
            guard let self else { return }
            work(self)
        })
    }

    private func cancelAll() {
        pending.forEach { $0() }
        pending.removeAll()
        stopExpiry()
    }

    nonisolated static let mainQueueSchedule: Schedule = { seconds, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }
}
