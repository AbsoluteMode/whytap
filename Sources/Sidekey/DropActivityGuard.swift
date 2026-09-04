import Foundation

/// Holds a `ProcessInfo` activity assertion for the lifetime of one Drop
/// turn so App Nap cannot throttle the turn's timers/detection (a likely
/// contributor to the stop-watchdog not firing promptly on a hung turn).
/// Idempotent: a second `begin` while already active is a no-op.
@MainActor
final class DropActivityGuard {
    private var token: NSObjectProtocol?
    var isActive: Bool { token != nil }

    func begin(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: reason
        )
    }

    func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }
}
