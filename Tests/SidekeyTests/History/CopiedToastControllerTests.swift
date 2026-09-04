import Combine
import XCTest
@testable import Sidekey

@MainActor
final class CopiedToastControllerTests: XCTestCase {
    func testInitiallyHidden() {
        let controller = CopiedToastController()
        XCTAssertFalse(controller.isVisible)
    }

    func testShowFlipsIsVisible() {
        let controller = CopiedToastController()
        controller.show()
        XCTAssertTrue(controller.isVisible)
    }

    func testHideFlipsIsVisible() {
        let controller = CopiedToastController()
        controller.show()
        controller.hide()
        XCTAssertFalse(controller.isVisible)
    }

    /// `show()` schedules `hide()` after `totalLifespan`. We provide an
    /// injectable scheduler so the test does not have to wait
    /// `totalLifespan` seconds of wall-clock time.
    func testShowAutoHidesAfterLifespan() async {
        var deadline: TimeInterval?
        var scheduledWork: (() -> Void)?
        let controller = CopiedToastController(
            schedule: { delay, work in
                deadline = delay
                scheduledWork = work
            }
        )

        controller.show()
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(deadline, CopiedToastController.totalLifespan)

        scheduledWork?()
        XCTAssertFalse(controller.isVisible)
    }

    /// A second `show()` before the auto-hide fires resets the timer
    /// so the toast stays visible for another full lifespan instead
    /// of flickering off mid-display.
    func testSecondShowExtendsTheTimer() {
        var pendingWork: (() -> Void)?
        let controller = CopiedToastController(
            schedule: { _, work in
                pendingWork = work
            }
        )

        controller.show()
        let firstWork = pendingWork
        controller.show()
        let secondWork = pendingWork

        XCTAssertNotNil(firstWork)
        XCTAssertNotNil(secondWork)
        // Each show schedules a fresh closure — they're not the same
        // instance, so the controller does not collapse the two into
        // one.
        XCTAssertFalse(firstWork! as AnyObject === secondWork! as AnyObject)

        // Stale first closure must not flip visibility off — the
        // controller's `show()` increments a generation token internally,
        // so when the older closure eventually fires it no-ops.
        firstWork!()
        XCTAssertTrue(controller.isVisible, "older scheduled hide must not steal a newer show")
    }
}
