import XCTest
@testable import Sidekey

/// Orchestrates the drop/agent wing's two-step entrance: the island form
/// grows EMPTY first, then the face content (provider mark + "listening…")
/// fades in. The reveal is explicit state — not a SwiftUI transition — so
/// the surface and the content can never interleave into a half-clipped
/// "listenin|" frame, regardless of how the width springs schedule.
@MainActor
final class IslandWingRevealCoordinatorTests: XCTestCase {
    func test_revealWaitsForGrowDelayThenFlips() async throws {
        let coordinator = IslandWingRevealCoordinator(growDelay: .milliseconds(30))

        coordinator.wingVisibilityChanged(true)
        XCTAssertFalse(coordinator.revealed, "content must stay hidden while the form grows")

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(coordinator.revealed, "content reveals after the grow delay")
    }

    func test_hidingWingResetsRevealImmediately() async throws {
        let coordinator = IslandWingRevealCoordinator(growDelay: .milliseconds(10))
        coordinator.wingVisibilityChanged(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(coordinator.revealed)

        coordinator.wingVisibilityChanged(false)
        XCTAssertFalse(coordinator.revealed, "collapse hides content in the same frame")
    }

    func test_hideBeforeDelayCancelsPendingReveal() async throws {
        let coordinator = IslandWingRevealCoordinator(growDelay: .milliseconds(60))
        coordinator.wingVisibilityChanged(true)
        coordinator.wingVisibilityChanged(false)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(
            coordinator.revealed,
            "a reveal scheduled for a wing that already collapsed must not fire"
        )
    }

    func test_rapidShowHideShowRevealsExactlyOnceForLatestShow() async throws {
        let coordinator = IslandWingRevealCoordinator(growDelay: .milliseconds(40))
        coordinator.wingVisibilityChanged(true)
        coordinator.wingVisibilityChanged(false)
        coordinator.wingVisibilityChanged(true)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(coordinator.revealed, "the latest show still reveals")
    }

    func test_repeatedVisibleCallsDoNotResetAnActiveReveal() async throws {
        let coordinator = IslandWingRevealCoordinator(growDelay: .milliseconds(10))
        coordinator.wingVisibilityChanged(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(coordinator.revealed)

        coordinator.wingVisibilityChanged(true)
        XCTAssertTrue(coordinator.revealed, "face→face swaps keep the content revealed")
    }
}
