import Foundation
import os.log
import Sparkle

/// A value-typed snapshot of an in-flight Sparkle update. Published via
/// `AppState.updateAvailable` so the Dynamic Island right band renders the
/// pill and invokes `install()` / `dismiss()` on user action without ever
/// importing Sparkle types.
///
/// The flow is the download-on-action path enabled by
/// `automaticallyDownloadsUpdates = false` on `SPUUpdater`:
///
///   1. Sparkle discovers an update during a scheduled check (hourly + beacon-
///      triggered on release) → host publishes a `PendingUpdate` with
///      `stage == .available(download:)`. The pill shows «Update»; NO download
///      starts yet.
///   2. User clicks «Update» → `download()` fires the held `updateFound` reply
///      directly with `.install` via `driver.invokeDownload()`. Scheduled checks
///      run hourly + a beacon triggers within ~5 min of each release, so the
///      held item is current at click time. Bytes arrive → pill transitions to
///      `.downloading(fractionCompleted:)`.
///   3. Download finishes → `DriverStage.readyToInstall` →
///      `applyDriverStage` AUTO-INVOKES `driver.invokeInstall()` (one-button
///      update: download + install + relaunch from a single ↓ click). The pill
///      stays in the downloading/installing visual during the brief install —
///      there is NO user-actionable [Restart now] step. This is safe (not a
///      surprise restart) because the download was user-initiated.
///
/// The `.available` pill also exposes ✕ "Skip this version" (`skip` closure →
/// `driver.invokeSkip()`), which tells Sparkle to skip THIS build; future
/// versions still prompt.
///
/// `Equatable` compares marketing version, Sparkle build, and stage tag
/// only so SwiftUI re-render diffing stays stable across closure captures.
struct PendingUpdate: Equatable {

    /// Visual stage carried by the pill. Implementation closures live on
    /// the `readyToInstall` case so they are statically impossible to
    /// invoke while the update is still downloading.
    enum Stage: Equatable {
        /// Update discovered but NOT downloaded. The pill shows «Update»; the
        /// `download` closure fires the held `updateFound` reply with `.install`
        /// via `driver.invokeDownload()`, starting the download immediately.
        case available(download: () -> Void)
        /// Bytes in flight. `fractionCompleted` drives the island indicator.
        /// Also covers the brief auto-install phase after the download
        /// finishes (the pill keeps the downloading visual — no separate
        /// install step is surfaced).
        case downloading(fractionCompleted: Double)
        /// Retained for stage identity only. With one-button update the host
        /// AUTO-installs when the driver reports readyToInstall
        /// (`applyDriverStage` calls `driver.invokeInstall()` directly) and
        /// never publishes this case, so the `install` closure is normally
        /// unused. Kept so callers that switch on `Stage` stay exhaustive and
        /// `PendingUpdate.install()` remains type-safe.
        case readyToInstall(install: () -> Void)

        static func == (lhs: Stage, rhs: Stage) -> Bool {
            switch (lhs, rhs) {
            case (.available, .available): return true
            case (.downloading, .downloading): return true
            case (.readyToInstall, .readyToInstall): return true
            default: return false
            }
        }
    }

    /// `SUAppcastItem.displayVersionString` — i.e. `CFBundleShortVersionString`
    /// (e.g. "0.5.2"). Used by the pill UI.
    let displayVersion: String

    /// `SUAppcastItem.versionString` — i.e. `CFBundleVersion` / Sparkle build
    /// (e.g. "1207"). Acts as update identity; the display version may
    /// stay the same across multiple prod builds.
    let buildVersion: String

    let stage: Stage

    /// Dismisses the pill in-memory for the current session. Implemented
    /// by `UpdateController`; remembers the dismissed build so a re-
    /// trigger from Sparkle's retry cycle does not resurface the pill in
    /// the same session. NOT persisted across process restart (product
    /// decision).
    let dismiss: () -> Void

    /// Skips THIS version permanently (Sparkle records the skipped build).
    /// Implemented by `UpdateController` as `driver.invokeSkip()` →
    /// `reply(.skip)`. Unlike `dismiss` (in-memory, this session only), a
    /// skip persists in Sparkle and stops re-prompting for the same build;
    /// future versions still surface. Wired to the ✕ affordance on the
    /// `.available` pill.
    let skip: () -> Void

    /// Convenience that hands the captured install block back to the
    /// caller for `.readyToInstall`, or no-ops for other stages. The
    /// SwiftUI layer always calls this — the type system already prevents
    /// it from being mis-routed.
    func install() {
        if case .readyToInstall(let block) = stage {
            block()
        }
    }

    /// Triggers the download for `.available`; no-op otherwise.
    func startDownload() {
        if case .available(let download) = stage { download() }
    }

    /// Returns a copy of this update with a new stage, preserving
    /// `displayVersion`, `buildVersion`, `dismiss`, and `skip`. Used by
    /// `UpdateController.applyDriverStage(_:)` to transition the pill
    /// state as Sparkle progresses through download.
    func with(stage newStage: Stage) -> PendingUpdate {
        PendingUpdate(
            displayVersion: displayVersion,
            buildVersion: buildVersion,
            stage: newStage,
            dismiss: dismiss,
            skip: skip
        )
    }

    static func == (lhs: PendingUpdate, rhs: PendingUpdate) -> Bool {
        lhs.displayVersion == rhs.displayVersion
            && lhs.buildVersion == rhs.buildVersion
            && lhs.stage == rhs.stage
    }
}

/// Owns Sparkle's `SPUUpdater` + a custom `IslandUpdateUserDriver` and turns
/// update discoveries into host-rendered Dynamic Island pills without using
/// any of Sparkle's standard windows.
///
/// ## Download-on-action flow (Sparkle 2.9.1)
///
/// Sparkle is configured with `automaticallyDownloadsUpdates = false`.
/// Scheduled discoveries surface through the driver (`.available`), and the
/// download only begins when the user clicks «Update» in the island pill:
///
/// 1. **`updater(_:didFindValidUpdate:)`** — scheduled discovery fires; the
///    delegate method calls `handleDiscovered(version:build:)` for idempotency
///    / dismiss guard. The pill is only a notification that an update exists.
///    The driver holds the `updateFound` reply until the user acts.
///
/// 2. **User clicks «Update»** → `download()` closure calls `downloadAction()`
///    → `driver.invokeDownload()` → fires the held `updateFound` reply with
///    `.install`. Sparkle begins downloading immediately. Scheduled checks run
///    hourly + a beacon triggers within ~5 min of each release, so the held
///    item is current at click time.
///
/// 3. **Driver emits `.readyToInstall`** → `applyDriverStage` AUTO-invokes
///    `driver.invokeInstall()` (one-button update: a single ↓ click downloads,
///    installs, and relaunches). The pill keeps the downloading/installing
///    visual; no user-actionable restart step is surfaced. Safe because the
///    download was user-initiated (`automaticallyDownloadsUpdates = false`).
///
/// 4. **`updater(_:failedToDownloadUpdate:error:)`** — download failed; host
///    clears the pill. The next scheduled tick will retry.
///
/// ## Lifetime
///
/// `SPUUpdater` weakly references its delegate; `AppDelegate` retains this
/// controller for the whole app lifetime. The driver is stored strongly here
/// so it is never orphaned.
@MainActor
final class UpdateController: NSObject, ObservableObject {

    /// The direct Sparkle updater. `private(set)` so tests can read
    /// configuration properties (`automaticallyChecksForUpdates`, etc.)
    /// without importing Sparkle in every test file.
    private(set) var updater: SPUUpdater!

    /// Custom user driver — translates Sparkle's SPUUserDriver callbacks
    /// into primitive `DriverStage` emits. Stored strongly because
    /// `SPUUpdater` only weakly holds its user driver.
    /// `private(set)` so tests can arm and inspect driver state directly.
    private(set) var driver: IslandUpdateUserDriver!

    /// Injectable override for the user-action download trigger. In production
    /// this calls `driver.invokeDownload()` which fires the held `updateFound`
    /// reply with `.install` — the download begins immediately using Sparkle's
    /// already-discovered appcast item. In tests it can be replaced with a
    /// counter to verify the trigger fires.
    private var downloadAction: () -> Void = {}

    /// Injectable override for the auto-install trigger. In production this
    /// calls `driver.invokeInstall()` (Sparkle installs + relaunches). Fired
    /// automatically by `applyDriverStage(.readyToInstall)` — one-button
    /// update, no second click. In tests it is replaced with a counter.
    private var installAction: () -> Void = {}

    /// Injectable override for the ✕ "Skip this version" trigger. In production
    /// this calls `driver.invokeSkip()` (Sparkle records the skipped build). In
    /// tests it is replaced with a counter to verify the trigger fires.
    private var skipAction: () -> Void = {}

    /// In-memory dismissed-build flag. Cleared on every process restart by
    /// design. NOT persisted to UserDefaults so a Later click never silently
    /// suppresses the update forever — the next launch always re-evaluates.
    private(set) var dismissedBuildVersionString: String?

    /// Persists the build/version we are about to auto-install so the NEW
    /// binary can show a post-relaunch "Updated" indicator (variant A). Only
    /// its `persistPendingInstall` is used here; the launch-time `checkAndShow`
    /// runs from `AppDelegate` against the same UserDefaults marker.
    private let justUpdatedIndicator: JustUpdatedIndicator

    /// Held weak so the controller does not retain its host AppState —
    /// the app delegate owns both and AppState's lifetime envelopes the
    /// controller's.
    private weak var appState: AppState?

    private static let log = OSLog(
        subsystem: "com.rootwise.sidekey",
        category: "updates"
    )

    init(
        appState: AppState,
        updatesEnabled: Bool = true,
        downloadAction: (() -> Void)? = nil,
        installAction: (() -> Void)? = nil,
        skipAction: (() -> Void)? = nil,
        justUpdatedIndicator: JustUpdatedIndicator? = nil
    ) {
        self.appState = appState
        self.justUpdatedIndicator = justUpdatedIndicator
            ?? JustUpdatedIndicator(appState: appState)
        super.init()

        // Build the custom driver first so it is ready before the updater
        // begins its first scheduled tick.
        let userDriver = IslandUpdateUserDriver(onStage: { [weak self] stage in
            self?.applyDriverStage(stage)
        })
        self.driver = userDriver

        // Build the direct SPUUpdater — no standard windows, no standard
        // user-driver delegate needed.
        // Two-phase init: super.init() ran above, so self is valid as delegate.
        self.updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: self
        )

        // Background scheduled checks enabled — set programmatically so a
        // user who had checks disabled in a prior build is re-enabled on
        // first launch (product decision).
        updater.automaticallyChecksForUpdates = updatesEnabled
        updater.updateCheckInterval = 3600

        // Download-on-action: Sparkle must NOT auto-download. The pill
        // surfaces "Update" first; the download begins only when the user
        // clicks. Sparkle's header warns this property persists to
        // UserDefaults and "Do not always set it on launch unless you want
        // to ignore the user's preference." — we explicitly want to ignore
        // that preference here: download-on-action is Sidekey product policy,
        // not a user-toggleable option.
        updater.automaticallyDownloadsUpdates = false

        // Wire the download action before starting the updater, in case a
        // discovery fires immediately. The default fires the held updateFound
        // reply directly with .install — the pill click starts the download
        // immediately using the appcast item Sparkle already discovered.
        // Scheduled checks run hourly + a beacon triggers within ~5 min of
        // each release, so the held item is current at click time.
        // WHY: docs/decisions/2026-06-19-update-direct-install.md
        if let downloadAction {
            self.downloadAction = downloadAction
        } else {
            self.downloadAction = { [weak self] in
                self?.driver.invokeDownload()
            }
        }

        // Auto-install + skip triggers. Defaults route to the driver's held
        // replies; tests inject counters. invokeInstall() fires the held
        // readyToInstall reply (install + relaunch); invokeSkip() fires the
        // held updateFound reply with .skip (Sparkle records the skipped build).
        if let installAction {
            self.installAction = installAction
        } else {
            self.installAction = { [weak self] in
                self?.driver.invokeInstall()
            }
        }

        if let skipAction {
            self.skipAction = skipAction
        } else {
            self.skipAction = { [weak self] in
                self?.driver.invokeSkip()
            }
        }

        // Start the updater — it can throw on misconfiguration (e.g. missing
        // SUFeedURL in Info.plist). Failure is non-fatal: the app runs without
        // updates rather than crashing. Error type is logged (not payload —
        // invariant #3).
        if updatesEnabled {
            do {
                try updater.start()
            } catch {
                os_log(
                    "updater.start.failed errorType=%{public}@",
                    log: Self.log,
                    type: .error,
                    String(describing: type(of: error))
                )
            }
        }

        os_log(
            "controller.init automaticChecks=%{public}@ autoDownload=%{public}@ interval=%{public}@",
            log: Self.log,
            type: .info,
            updatesEnabled ? "true" : "false",
            "false",
            "3600"
        )
    }

    // MARK: - Host-side actions

    /// Read the pending-install marker on launch and, if the install actually
    /// applied (persisted build == running `CFBundleVersion`), surface the
    /// transient "Updated vX.Y" island indicator (variant A). One-shot: the
    /// marker is consumed regardless of outcome. Call once after the island
    /// panel is on screen.
    func showJustInstalledIndicatorIfNeeded() {
        justUpdatedIndicator.checkAndShow()
    }

    /// Dismiss the transient "Updated" indicator immediately (tap). Routes to
    /// the same indicator that armed the auto-dismiss so the pending timer is
    /// cancelled too.
    func dismissJustInstalledIndicator() {
        justUpdatedIndicator.dismiss()
    }

    /// Dismiss the pending pill in-memory for this session. Remembers the
    /// build so Sparkle's retry cycle re-discovering the same build does
    /// NOT resurface the pill. For `.readyToInstall` this means the user
    /// chose "Later"; Sparkle will not auto-install because download-on-action
    /// means the install cycle only runs when the user explicitly triggers it.
    func dismissPendingUpdate() {
        let version = appState?.updateAvailable?.displayVersion
        let build = appState?.updateAvailable?.buildVersion
        if let build {
            dismissedBuildVersionString = build
        }
        os_log(
            "pendingUpdate.dismiss version=%{public}@ build=%{public}@ reason=%{public}@",
            log: Self.log,
            type: .info,
            version ?? "<none>",
            build ?? "<none>",
            "user_skip"
        )
        appState?.updateAvailable = nil
    }

    // MARK: - Internal entry points

    /// Internal entry point for `didFindValidUpdate`. Publishes a `.available`
    /// pill WITHOUT starting a download — the user must click «Update».
    ///
    /// `internal` (not `private`) because tests exercise it directly —
    /// constructing an `SPUUserUpdateState` is not possible in pure Swift.
    func handleDiscovered(version: String, build: String) {
        if dismissedBuildVersionString == build {
            os_log(
                "discovery.noop reason=%{public}@ version=%{public}@ build=%{public}@",
                log: Self.log,
                type: .info,
                "dismissed_this_session",
                version,
                build
            )
            return
        }

        // Idempotency: re-entry for the same build while we're already showing
        // it must not reset state (avoids demoting a readyToInstall pill back
        // to available because a stray didFindValidUpdate fired late).
        if appState?.updateAvailable?.buildVersion == build {
            os_log(
                "discovery.noop reason=%{public}@ version=%{public}@ build=%{public}@",
                log: Self.log,
                type: .info,
                "already_pending",
                version,
                build
            )
            return
        }

        appState?.updateAvailable = PendingUpdate(
            displayVersion: version,
            buildVersion: build,
            stage: .available(download: { [weak self] in self?.downloadAction() }),
            dismiss: { [weak self] in self?.dismissPendingUpdate() },
            skip: { [weak self] in self?.skipAction() }
        )
        os_log(
            "pendingUpdate.set stage=%{public}@ version=%{public}@ build=%{public}@",
            log: Self.log,
            type: .info,
            "available",
            version,
            build
        )
    }

    /// Maps `IslandUpdateUserDriver.DriverStage` onto the current pending
    /// update's stage, preserving `displayVersion`, `buildVersion`, and
    /// `dismiss`. Called on every driver emit.
    func applyDriverStage(_ stage: IslandUpdateUserDriver.DriverStage) {
        guard let current = appState?.updateAvailable else { return }
        switch stage {
        case .available:
            // Discovery already set .available via handleDiscovered; no-op.
            break
        case .downloading(let fraction):
            appState?.updateAvailable = current.with(
                stage: .downloading(fractionCompleted: fraction)
            )
        case .readyToInstall:
            // One-button update: the download was user-initiated (↓ click), so
            // installing + relaunching automatically here is not a surprise
            // restart. We auto-invoke install instead of surfacing a second
            // [Restart now] click. The pill stays in the downloading visual
            // (no stage change) through the brief install; .installing/.cleared
            // continue to be handled below.
            //
            // Record the version we are about to apply BEFORE relaunching so
            // the next launch (new binary) can show a post-relaunch "Updated"
            // indicator (variant A). Persist first — installAction() may
            // terminate the app immediately.
            justUpdatedIndicator.persistPendingInstall(
                buildVersion: current.buildVersion,
                displayVersion: current.displayVersion
            )
            installAction()
        case .installing:
            // Keep the downloading/installing visual during the brief install.
            break
        case .cleared:
            appState?.updateAvailable = nil
        }
    }

    /// Internal entry point for a download failure. Clears the pill so it
    /// does not look stuck; Sparkle's next scheduled tick will retry on its own.
    func handleDownloadFailed(_ update: SUAppcastItem, error: Error) {
        os_log(
            "download.failed version=%{public}@ build=%{public}@ error=%{public}@",
            log: Self.log,
            type: .error,
            update.displayVersionString,
            update.versionString,
            error.localizedDescription
        )
        // Only clear if this is the same build we were tracking. A stale
        // failure for an older build must not wipe a newer pending pill.
        if appState?.updateAvailable?.buildVersion == update.versionString {
            appState?.updateAvailable = nil
        }
    }

    #if DEBUG
    /// DEBUG-only preview of the update UX for `--demo-update`. Drives the REAL
    /// island views end-to-end WITHOUT a Sparkle download:
    ///   1. publishes a `.downloading` `PendingUpdate` → the download spinner
    ///      (`IslandUpdateSpinner`) turns for `spinnerSeconds`;
    ///   2. clears it, then surfaces the "Updated" indicator through the REAL
    ///      `JustUpdatedIndicator.checkAndShow()` path (persist marker →
    ///      build-match → publish → its own 5 s auto-dismiss + tap).
    ///
    /// Uses a throwaway `JustUpdatedIndicator` on an isolated UserDefaults suite
    /// with a forced-matching build, so it neither reads nor writes the
    /// production install marker and does not touch the controller's own
    /// indicator / scheduler. Gated by the caller on the `--demo-update`
    /// launch argument; no production path reaches this.
    func runDemoUpdatePreview(spinnerSeconds: TimeInterval = 6) {
        guard let appState else { return }

        appState.updateAvailable = PendingUpdate(
            displayVersion: "1.18.0",
            buildVersion: "demo",
            stage: .downloading(fractionCompleted: 0.4),
            dismiss: {},
            skip: {}
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + spinnerSeconds) { [weak self, weak appState] in
            guard let self, let appState else { return }
            appState.updateAvailable = nil

            // Real "Updated" path: a forced-match marker on a demo-only suite
            // so checkAndShow() publishes + arms the genuine 5 s auto-dismiss.
            let demoSuite = UserDefaults(suiteName: "sidekey.demoUpdate") ?? .standard
            let indicator = JustUpdatedIndicator(
                appState: appState,
                defaults: demoSuite,
                currentBuild: { "demo" }
            )
            // Retain past this closure so its 5 s auto-dismiss timer (held only
            // weakly by the scheduler's callback) actually fires; the real
            // startup path is retained by the controller, this demo one is not.
            self.demoIndicator = indicator
            indicator.persistPendingInstall(buildVersion: "demo", displayVersion: "1.18.0")
            indicator.checkAndShow()
        }
    }

    /// Retains the throwaway demo indicator so its auto-dismiss timer survives.
    private var demoIndicator: JustUpdatedIndicator?
    #endif
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {

    /// Sparkle has discovered a valid update. With
    /// `automaticallyDownloadsUpdates = false` the download has NOT started
    /// yet; the driver's `showUpdateFound(with:state:reply:)` has already
    /// emitted `.available`. This delegate method enforces the
    /// dismiss-guard and idempotency on the host side.
    ///
    /// `nonisolated` because Sparkle's protocol does not annotate this
    /// method `@MainActor`; the standard updater nevertheless dispatches
    /// callbacks on the main thread (`SPUUpdater.h` doc on the delegate
    /// contract), so `MainActor.assumeIsolated` is sound and preserves
    /// FIFO ordering across back-to-back delegate invocations (an
    /// unstructured `Task { @MainActor in ... }` hop does NOT).
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let build = item.versionString
        MainActor.assumeIsolated {
            self.handleDiscovered(version: version, build: build)
        }
    }

    /// Download failed — clear the pill so it does not look stuck.
    /// Sparkle will retry on its own at the next scheduled tick.
    nonisolated func updater(
        _ updater: SPUUpdater,
        failedToDownloadUpdate item: SUAppcastItem,
        error: Error
    ) {
        MainActor.assumeIsolated {
            self.handleDownloadFailed(item, error: error)
        }
    }

}
