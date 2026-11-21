import XCTest
@testable import Sidekey

extension XCTestCase {
    /// Calendar ships closed ("Soon"). Tests of the Calendar code itself open it
    /// for the length of one test; the override is cleared in the teardown.
    func openCalendarForThisTest() {
        CalendarAvailability.testOverride = true
        addTeardownBlock { CalendarAvailability.testOverride = nil }
    }
}
