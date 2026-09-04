import Foundation
import os.log

/// Pure-logic state machine for wake/sleep handling.
///
/// Background: on macOS the sequence of power-state notifications is not
/// always symmetric. `NSWorkspace.willSleepNotification` reliably fires
/// before a deep system sleep, but several real-world cases produce a
/// `didWakeNotification` *without* a preceding `willSleep`:
///
/// * Display-only sleep that escalates to suspend without firing
///   `willSleep` (observed on Apple Silicon under "Optimized Battery").
/// * Dark sleep with quick keychain unlocks (the workspace notification
///   bus skips entries in this path on some kernel builds).
/// * Lid-close on docked external displays where the system signals
///   wake on lid-open but never logged a willSleep on lid-close.
///
/// In all of those cases the Carbon `RegisterEventHotKey` registration
/// and `NSEvent.addGlobalMonitorForEvents` handles can be silently torn
/// down by the kernel's power-management layer, leaving the app deaf
/// for ~30s until macOS eventually re-routes events on its own.
///
/// The fix is to **always re-arm critical monitors on wake**, with a
/// `WakeReason` tag indicating whether a preceding pause was observed.
/// Callers use the reason to skip heavy work (full luminance restart,
/// agent shutdown/recreate) when the app was never actually torn down.
///
/// The coordinator is intentionally pure — it does not own any system
/// resources, only sequences callbacks. The actual subsystem hooks
/// (hotkey reinstall, NSEvent monitor reinstall, etc.) live on the
/// callers (today: `AppDelegate`).
final class PowerStateCoordinator {
    /// Why a re-arm fired. Callers use this to decide which subsystems
    /// to restart.
    ///
    /// * `.full` — a matching `willSleep` was observed before this wake.
    ///   The app actively paused: monitors were uninstalled, agent
    ///   controller torn down, orb surface hidden. Caller should
    ///   restart everything.
    /// * `.soft` — wake fired without a paired pause. Monitors *may* be
    ///   broken at the kernel level even though our process never
    ///   teardown them. Caller should reinstall event monitors
    ///   defensively but skip heavyweight restarts (auth refresh,
    ///   luminance reseed) that would only thrash a healthy app.
    enum WakeReason: Equatable {
        case full
        case soft
    }

    /// Wake notifications inside this window after a previous wake
    /// collapse into the same transition. macOS sometimes posts both
    /// `didWake` and `screensDidWake` back-to-back for one wake event,
    /// and we do not want to re-register hot keys twice in a row.
    private let softWakeDebounceSeconds: TimeInterval

    private let now: () -> Date
    private let onPause: () -> Void
    private let onRearm: (WakeReason) -> Void

    private var pausedForSleep = false
    private var lastRearmAt: Date?

    var isPausedForSleep: Bool { pausedForSleep }

    init(
        softWakeDebounceSeconds: TimeInterval = 2.0,
        now: @escaping () -> Date = { Date() },
        onPause: @escaping () -> Void,
        onRearm: @escaping (WakeReason) -> Void
    ) {
        self.softWakeDebounceSeconds = softWakeDebounceSeconds
        self.now = now
        self.onPause = onPause
        self.onRearm = onRearm
    }

    /// Handles `NSWorkspace.willSleepNotification`. Idempotent — a
    /// duplicate notification during the same sleep transition is a
    /// no-op so callers don't double-stop subsystems.
    func handleWillSleep() {
        guard !pausedForSleep else { return }
        pausedForSleep = true
        onPause()
    }

    /// Handles wake notifications (`NSWorkspace.didWakeNotification`
    /// and `NSWorkspace.screensDidWakeNotification`). Both wire to
    /// this entry point because either may arrive first depending on
    /// the sleep mode the system used.
    ///
    /// The handler is idempotent within `softWakeDebounceSeconds` so
    /// two back-to-back wake notifications produce a single re-arm.
    /// Outside that window, a fresh wake event always triggers a
    /// re-arm — even without a preceding pause — because some macOS
    /// sleep modes silently kill event monitors without firing
    /// `willSleep`.
    func handleDidWake() {
        if pausedForSleep {
            pausedForSleep = false
            lastRearmAt = now()
            onRearm(.full)
            return
        }

        if let last = lastRearmAt,
           now().timeIntervalSince(last) < softWakeDebounceSeconds {
            return
        }

        lastRearmAt = now()
        onRearm(.soft)
    }
}
