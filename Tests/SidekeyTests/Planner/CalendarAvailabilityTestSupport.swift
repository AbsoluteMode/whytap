import XCTest
@testable import Sidekey

extension XCTestCase {
    /// Calendar ships open. Tests that predate the release still open it
    /// explicitly; the override is cleared in the teardown.
    func openCalendarForThisTest() {
        CalendarAvailability.testOverride = true
        addTeardownBlock { CalendarAvailability.testOverride = nil }
    }

    /// The switch can close Calendar again as "Soon"; tests of that state close
    /// it for the length of one test.
    func closeCalendarForThisTest() {
        CalendarAvailability.testOverride = false
        addTeardownBlock { CalendarAvailability.testOverride = nil }
    }
}
