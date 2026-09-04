import XCTest
@testable import Sidekey

/// Pure unit coverage for the fully-on-device meeting activation gate
/// (`MeetingsCoordinator.isFullyLocalMeetingEnabled`). The gate must require
/// BOTH `.local` isolation levels AND Apple-Silicon hardware (ROO-257 Stage 6:
/// MLX/Core ML never engage on Intel).
@MainActor
final class MeetingsCoordinatorGateTests: XCTestCase {
    func testEnabledWhenAllConditionsMet() {
        XCTAssertTrue(
            MeetingsCoordinator.isFullyLocalMeetingEnabled(
                transcriptionLevel: .local,
                llmLevel: .local,
                isAppleSilicon: true
            )
        )
    }

    func testDisabledOnIntelEvenWhenLevelsMatch() {
        XCTAssertFalse(
            MeetingsCoordinator.isFullyLocalMeetingEnabled(
                transcriptionLevel: .local,
                llmLevel: .local,
                isAppleSilicon: false
            )
        )
    }

    func testDisabledWhenEitherLevelIsNotLocal() {
        XCTAssertFalse(
            MeetingsCoordinator.isFullyLocalMeetingEnabled(
                transcriptionLevel: .local,
                llmLevel: .yourKey,
                isAppleSilicon: true
            )
        )
        XCTAssertFalse(
            MeetingsCoordinator.isFullyLocalMeetingEnabled(
                transcriptionLevel: .yourKey,
                llmLevel: .local,
                isAppleSilicon: true
            )
        )
        XCTAssertFalse(
            MeetingsCoordinator.isFullyLocalMeetingEnabled(
                transcriptionLevel: .local,
                llmLevel: .custom,
                isAppleSilicon: true
            )
        )
    }
}
