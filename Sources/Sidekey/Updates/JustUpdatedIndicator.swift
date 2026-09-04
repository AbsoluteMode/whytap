import Foundation
import os.log

/// Schedules (and cancels) the single pending "hide the Updated indicator" tick.
/// Injected into `JustUpdatedIndicator` so tests drive time by hand — a fake
/// captures the pending closure and fires it on demand, with no real `Timer`.
///
/// Contract: `schedule` replaces any previously-armed tick (only one is ever
/// pending); `cancel` disarms it.
@MainActor
protocol JustUpdatedDismissScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
    func cancel()
}

/// Production dismiss scheduler — a lightweight one-shot `Timer` wrapper on the
/// main run loop. Rescheduling invalidates the prior timer so at most one is
/// ever armed.
@MainActor
final class JustUpdatedTimerScheduler: JustUpdatedDismissScheduling {
    private var timer: Timer?

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        cancel()
        let interval = max(delay, 0)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

/// Post-relaunch "Updated" indicator (update-UX variant A). Keeps the
/// one-button auto-install + relaunch flow — the confirmation is shown in the
/// NEW binary after it comes back up, not before restart.
///
/// Two responsibilities:
///
///   1. **Persist** (called by `UpdateController` just before it auto-installs):
///      record the build + display version we are about to apply.
///   2. **Check on launch** (`checkAndShow`): if the persisted build matches the
///      running binary's `CFBundleVersion`, the update really applied — publish
///      "Updated vX.Y" into `AppState.justUpdatedVersion` and auto-hide it after
///      `autoDismissDelay` (or on tap). If it does not match (rollback / stale /
///      different build), show nothing. Either way the marker is consumed so it
///      is strictly one-shot.
///
/// This is a cosmetic island indicator, NOT a Sparkle window and NOT a modal —
/// invariant #5 is untouched; the update itself still installs + relaunches from
/// the single ↓ click.
///
/// Pure of AppKit: the current build and the clock flow in through injected
/// closures / scheduler, so the whole thing is unit-testable with a virtual
/// timer and a synthetic build number.
@MainActor
final class JustUpdatedIndicator {
    /// `CFBundleVersion` (Sparkle build) we are about to install. Matched against
    /// the running binary on next launch to prove the install applied.
    static let justInstalledBuildKey = "sidekey.update.justInstalledBuild"
    /// `CFBundleShortVersionString` we are about to install — shown in the pill
    /// ("Updated v1.18.0" when it fits).
    static let justInstalledVersionKey = "sidekey.update.justInstalledVersion"

    /// How long the "Updated" indicator stays up before it fades on its own.
    static let autoDismissDelay: TimeInterval = 5

    private weak var appState: AppState?
    private let defaults: UserDefaults
    private let currentBuild: () -> String?
    private let scheduler: JustUpdatedDismissScheduling

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "updates")

    init(
        appState: AppState,
        defaults: UserDefaults = .standard,
        currentBuild: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        },
        scheduler: JustUpdatedDismissScheduling? = nil
    ) {
        self.appState = appState
        self.defaults = defaults
        self.currentBuild = currentBuild
        // Default constructed inside the @MainActor init body — the production
        // scheduler's init is main-actor-isolated and cannot be a (nonisolated)
        // default-argument expression.
        self.scheduler = scheduler ?? JustUpdatedTimerScheduler()
    }

    /// Record the build/version we are about to auto-install. Called by
    /// `UpdateController` immediately before `installAction()`.
    func persistPendingInstall(buildVersion: String, displayVersion: String) {
        defaults.set(buildVersion, forKey: Self.justInstalledBuildKey)
        defaults.set(displayVersion, forKey: Self.justInstalledVersionKey)
    }

    /// Read the marker on launch and, if the install applied, surface the
    /// "Updated" indicator. Always consumes the marker (one-shot).
    func checkAndShow() {
        let markerBuild = defaults.string(forKey: Self.justInstalledBuildKey)
        let markerVersion = defaults.string(forKey: Self.justInstalledVersionKey)

        // Nothing to do if there is no pending-install marker.
        guard let markerBuild else { return }

        // Consume the marker up front — whatever the outcome, it must never
        // re-fire on a later launch.
        clearMarker()

        guard let current = currentBuild(), current == markerBuild else {
            os_log(
                "justUpdated.skip reason=%{public}@ marker=%{public}@ current=%{public}@",
                log: Self.log,
                type: .info,
                "build_mismatch_or_unknown",
                markerBuild,
                currentBuild() ?? "<none>"
            )
            return
        }

        appState?.justUpdatedVersion = markerVersion ?? current
        os_log(
            "justUpdated.show version=%{public}@ build=%{public}@",
            log: Self.log,
            type: .info,
            markerVersion ?? "<none>",
            markerBuild
        )
        scheduler.schedule(after: Self.autoDismissDelay) { [weak self] in
            self?.dismiss()
        }
    }

    /// Hide the indicator immediately (tap or auto-dismiss). Idempotent.
    func dismiss() {
        scheduler.cancel()
        appState?.justUpdatedVersion = nil
    }

    private func clearMarker() {
        defaults.removeObject(forKey: Self.justInstalledBuildKey)
        defaults.removeObject(forKey: Self.justInstalledVersionKey)
    }
}
