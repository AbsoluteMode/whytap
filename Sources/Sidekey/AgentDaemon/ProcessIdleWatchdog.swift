import Foundation

/// Watches a child process's stdout for silence. `kick()` on every output
/// chunk resets the clock (output = alive). Two deadlines fire off a private
/// serial queue: `onSoft` (collect diagnostics while the process is still
/// alive) and `onHard` (declare it stuck). After `onHard` (or `cancel()`) the
/// watchdog is permanently stopped. All state is confined to `queue`, so it is
/// safe to `kick()` from a pipe readability handler on any thread.
///
/// WHY: docs/decisions/2026-06-16-agent-turn-watchdog.md
final class ProcessIdleWatchdog: @unchecked Sendable {
    private let soft: TimeInterval
    private let hard: TimeInterval
    private let queue: DispatchQueue
    private let onSoft: () -> Void
    private let onHard: () -> Void

    private var softItem: DispatchWorkItem?
    private var hardItem: DispatchWorkItem?
    private var stopped = false

    init(softTimeout: TimeInterval,
         hardTimeout: TimeInterval,
         queue: DispatchQueue = DispatchQueue(label: "com.sidekey.agent.watchdog"),
         onSoft: @escaping () -> Void,
         onHard: @escaping () -> Void) {
        precondition(softTimeout < hardTimeout, "softTimeout must be less than hardTimeout")
        self.soft = softTimeout
        self.hard = hardTimeout
        self.queue = queue
        self.onSoft = onSoft
        self.onHard = onHard
    }

    /// Arm both deadlines from now. Call once when the process launches.
    func start() { queue.async { self.arm() } }

    /// Output observed — reset the silence clock.
    func kick() { queue.async { self.arm() } }

    /// Stop permanently (natural exit, or after hard fired).
    func cancel() {
        queue.async {
            self.stopped = true
            self.softItem?.cancel(); self.hardItem?.cancel()
            self.softItem = nil; self.hardItem = nil
        }
    }

    // Must run on `queue`.
    private func arm() {
        softItem?.cancel(); hardItem?.cancel()
        guard !stopped else { return }
        let s = DispatchWorkItem { [weak self] in self?.onSoft() }
        let h = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.softItem = nil; self.hardItem = nil
            self.onHard()
        }
        softItem = s; hardItem = h
        queue.asyncAfter(deadline: .now() + soft, execute: s)
        queue.asyncAfter(deadline: .now() + hard, execute: h)
    }
}
