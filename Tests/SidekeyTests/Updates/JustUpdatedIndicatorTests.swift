import XCTest
@testable import Sidekey

/// Tests for the post-relaunch "Updated" indicator (ROO update-UX, variant A).
///
/// Just before Sparkle installs + relaunches, `UpdateController` persists the
/// build/version it is about to apply. On the NEXT launch — now running the new
/// binary — `JustUpdatedIndicator.checkAndShow()` reads that marker:
///
///   - marker build == current `CFBundleVersion` → the update really applied →
///     publish "Updated vX.Y" into `AppState.justUpdatedVersion` and auto-hide
///     it after 5 s (or on tap).
///   - marker build != current (rollback / different build / stale) → clear the
///     marker and show nothing.
///
/// The marker is one-shot: it is always cleared after the check so it never
/// re-fires on a later launch.
///
/// Time is injected (a fake scheduler captures the pending 5 s work) and the
/// current build is injected, so the whole indicator is unit-testable with no
/// real timer and no dependency on the test bundle's actual version.
@MainActor
final class JustUpdatedIndicatorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var scheduler: FakeDismissScheduler!

    override func setUp() {
        super.setUp()
        suiteName = "JustUpdatedIndicatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        scheduler = FakeDismissScheduler()
        AppState.shared.justUpdatedVersion = nil
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AppState.shared.justUpdatedVersion = nil
        super.tearDown()
    }

    private func makeIndicator(currentBuild: String?) -> JustUpdatedIndicator {
        JustUpdatedIndicator(
            appState: .shared,
            defaults: defaults,
            currentBuild: { currentBuild },
            scheduler: scheduler
        )
    }

    // MARK: - Persist marker

    func test_persistPendingInstall_writesBuildAndVersion() {
        let indicator = makeIndicator(currentBuild: "1500")
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")

        XCTAssertEqual(defaults.string(forKey: JustUpdatedIndicator.justInstalledBuildKey), "1500")
        XCTAssertEqual(defaults.string(forKey: JustUpdatedIndicator.justInstalledVersionKey), "1.18.0")
    }

    // MARK: - checkAndShow: marker matches current build → show

    func test_checkAndShow_markerMatchesCurrentBuild_publishesVersion() {
        let indicator = makeIndicator(currentBuild: "1500")
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")

        indicator.checkAndShow()

        XCTAssertEqual(
            AppState.shared.justUpdatedVersion,
            "1.18.0",
            "A marker whose build matches the running binary must surface the Updated indicator."
        )
    }

    func test_checkAndShow_markerMatch_clearsMarker_soItIsOneShot() {
        let indicator = makeIndicator(currentBuild: "1500")
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")

        indicator.checkAndShow()

        XCTAssertNil(
            defaults.string(forKey: JustUpdatedIndicator.justInstalledBuildKey),
            "Marker must be cleared after a successful check so it never re-fires."
        )
        XCTAssertNil(defaults.string(forKey: JustUpdatedIndicator.justInstalledVersionKey))
    }

    func test_checkAndShow_secondCall_afterMatch_showsNothing() {
        let indicator = makeIndicator(currentBuild: "1500")
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")

        indicator.checkAndShow()
        AppState.shared.justUpdatedVersion = nil

        // Simulate the indicator being re-checked later in the same run: the
        // marker is gone, so nothing surfaces.
        indicator.checkAndShow()

        XCTAssertNil(AppState.shared.justUpdatedVersion)
    }

    // MARK: - checkAndShow: marker does not match → clear-noop

    func test_checkAndShow_markerBuildMismatch_showsNothing_andClearsMarker() {
        let indicator = makeIndicator(currentBuild: "1499")
        // Marker says we were installing 1500, but the running binary is 1499
        // (install did not actually apply / rollback).
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")

        indicator.checkAndShow()

        XCTAssertNil(
            AppState.shared.justUpdatedVersion,
            "A mismatched marker must NOT surface the indicator."
        )
        XCTAssertNil(
            defaults.string(forKey: JustUpdatedIndicator.justInstalledBuildKey),
            "A mismatched marker must still be cleared (one-shot)."
        )
    }

    func test_checkAndShow_noMarker_isNoop() {
        let indicator = makeIndicator(currentBuild: "1500")

        indicator.checkAndShow()

        XCTAssertNil(AppState.shared.justUpdatedVersion)
        XCTAssertFalse(scheduler.hasPendingWork, "No marker → no dismiss timer armed.")
    }

    func test_checkAndShow_currentBuildUnknown_isNoop_butClearsMarker() {
        // Defensive: if the running bundle has no readable CFBundleVersion we
        // cannot prove the install applied, so show nothing — but still consume
        // the marker so it does not linger.
        let indicator = makeIndicator(currentBuild: nil)
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")

        indicator.checkAndShow()

        XCTAssertNil(AppState.shared.justUpdatedVersion)
        XCTAssertNil(defaults.string(forKey: JustUpdatedIndicator.justInstalledBuildKey))
    }

    // MARK: - Auto-dismiss after 5 s

    func test_checkAndShow_match_armsDismissAfterConfiguredDelay() {
        let indicator = makeIndicator(currentBuild: "1500")
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")

        indicator.checkAndShow()

        XCTAssertTrue(scheduler.hasPendingWork, "A shown indicator must arm the auto-dismiss.")
        XCTAssertEqual(scheduler.lastDelay, JustUpdatedIndicator.autoDismissDelay)
    }

    func test_autoDismiss_firesAndClearsPublishedVersion() {
        let indicator = makeIndicator(currentBuild: "1500")
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")
        indicator.checkAndShow()
        XCTAssertEqual(AppState.shared.justUpdatedVersion, "1.18.0")

        scheduler.fire()

        XCTAssertNil(
            AppState.shared.justUpdatedVersion,
            "After the auto-dismiss delay the Updated indicator must clear itself."
        )
    }

    // MARK: - Tap-dismiss

    func test_dismiss_clearsPublishedVersion_andCancelsTimer() {
        let indicator = makeIndicator(currentBuild: "1500")
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")
        indicator.checkAndShow()
        XCTAssertEqual(AppState.shared.justUpdatedVersion, "1.18.0")

        indicator.dismiss()

        XCTAssertNil(AppState.shared.justUpdatedVersion, "Tap must clear the indicator immediately.")
        XCTAssertFalse(scheduler.hasPendingWork, "Tap-dismiss must cancel the pending auto-dismiss.")
    }

    func test_autoDismiss_afterTapDismiss_isHarmless() {
        let indicator = makeIndicator(currentBuild: "1500")
        indicator.persistPendingInstall(buildVersion: "1500", displayVersion: "1.18.0")
        indicator.checkAndShow()
        indicator.dismiss()

        // A stray fire (e.g. a timer that slipped through) must not resurrect
        // the indicator or crash.
        scheduler.fire()
        XCTAssertNil(AppState.shared.justUpdatedVersion)
    }
}

/// Test double for the injectable one-shot dismiss scheduler: captures the
/// pending work and the requested delay so tests drive time by hand.
@MainActor
final class FakeDismissScheduler: JustUpdatedDismissScheduling {
    private(set) var lastDelay: TimeInterval?
    private var pending: (() -> Void)?

    var hasPendingWork: Bool { pending != nil }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        lastDelay = delay
        pending = work
    }

    func cancel() {
        pending = nil
    }

    /// Invoke the captured work as if the delay elapsed.
    func fire() {
        let work = pending
        pending = nil
        work?()
    }
}
