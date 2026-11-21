import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class PlannerStoreTests: XCTestCase {
    func testInputValidationDoesNotLeakIntoPersistenceErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(url: root.appendingPathComponent("planner.json"))
        let task = PlannerTask(title: String(repeating: "x", count: 501))
        let event = PlannerEvent(title: "Meeting", start: Date(), end: .distantPast)
        XCTAssertNotNil(PlannerStore.validationMessage(for: task))
        XCTAssertNotNil(PlannerStore.validationMessage(for: event))
        XCTAssertFalse(store.saveTask(task)); XCTAssertFalse(store.saveEvent(event))
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.archive.tasks.isEmpty); XCTAssertTrue(store.archive.events.isEmpty)
        XCTAssertTrue(store.canWrite)
    }

    func testEditingDatesPreservesDurationAndTimesAcrossAllDayAndDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        for (startHour, endDay, endHour) in [(10, 7, 11), (23, 8, 1), (10, 8, 0)] {
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: startHour)))
            let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: endDay, hour: endHour)))
            var event = PlannerEvent(title: "Fixture", start: start, end: end)
            var timed: DateInterval?
            event.convertAllDay(true, timedRange: &timed, calendar: calendar)
            event.convertAllDay(false, timedRange: &timed, calendar: calendar)
            XCTAssertEqual(event.start, start); XCTAssertEqual(event.end, end)
            let duration = event.end.timeIntervalSince(event.start)
            let moved = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: event.start))
            event.moveStart(to: moved, calendar: calendar)
            XCTAssertEqual(event.end.timeIntervalSince(event.start), duration)
            event.convertAllDay(true, timedRange: &timed, calendar: calendar)
            let dayCount = calendar.dateComponents([.day], from: event.start, to: event.end).day
            event.moveStart(to: calendar.date(byAdding: .day, value: 1, to: event.start)!, calendar: calendar)
            XCTAssertEqual(calendar.dateComponents([.day], from: event.start, to: event.end).day, dayCount)
        }
    }
    private var directory: URL!
    override func setUp() async throws {
        openCalendarForThisTest()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("planner-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }
    private var url: URL { directory.appendingPathComponent("planner.json") }

    func testTaskLifecycleSurvivesReload() {
        let store = PlannerStore(url: url)
        var task = PlannerTask(title: "  Review proposal  ")
        XCTAssertTrue(store.saveTask(task))
        XCTAssertEqual(store.archive.tasks.first?.title, "Review proposal")
        task.title = "Send proposal"; task.completed = true
        XCTAssertTrue(store.saveTask(task))
        let restored = PlannerStore(url: url)
        task.completedAt = restored.archive.tasks.first?.completedAt
        XCTAssertNotNil(task.completedAt)
        XCTAssertEqual(restored.archive.tasks, [task])
        task.completed = false
        XCTAssertTrue(restored.saveTask(task))
        XCTAssertTrue(restored.deleteTask(task.id))
        XCTAssertTrue(PlannerStore(url: url).archive.tasks.isEmpty)
    }

    func testInvalidTaskKeepsDraftAndStoreUnchanged() {
        let store = PlannerStore(url: url)
        XCTAssertFalse(store.saveTask(PlannerTask(title: " \n ")))
        XCTAssertFalse(store.saveTask(PlannerTask(title: String(repeating: "x", count: 501))))
        XCTAssertTrue(store.archive.tasks.isEmpty)
        XCTAssertNil(store.errorMessage, "Input validation belongs to the editor")
    }

    func testCorruptArchiveIsNeverOverwrittenAndRetryRecovers() throws {
        let original = Data("unreadable archive".utf8)
        try original.write(to: url)
        let store = PlannerStore(url: url)
        XCTAssertFalse(store.canWrite)
        XCTAssertFalse(store.saveTask(PlannerTask(title: "Keep safe")))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try JSONEncoder().encode(PlannerStore.Archive()).write(to: url)
        store.reload()
        XCTAssertTrue(store.canWrite)
        XCTAssertTrue(store.saveTask(PlannerTask(title: "Recovered")))
    }

    func testUnsupportedVersionAndDuplicateIDsBlockWrites() throws {
        var archive = PlannerStore.Archive()
        archive.version = 2
        try JSONEncoder().encode(archive).write(to: url)
        XCTAssertFalse(PlannerStore(url: url).canWrite)
        let task = PlannerTask(title: "One")
        archive.version = 1; archive.tasks = [task, task]
        try JSONEncoder().encode(archive).write(to: url)
        XCTAssertFalse(PlannerStore(url: url).canWrite)
    }

    func testFailedWriteDoesNotPublishUnsavedData() {
        let store = PlannerStore(url: url, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertFalse(store.saveTask(PlannerTask(title: "Unsaved task")))
        XCTAssertTrue(store.archive.tasks.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testEventLifecycleValidationAndExclusiveEnd() {
        let store = PlannerStore(url: url)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var event = PlannerEvent(title: "Review", start: start, end: start.addingTimeInterval(3600))
        XCTAssertTrue(store.saveEvent(event))
        event.title = "Review with team"
        XCTAssertTrue(store.saveEvent(event))
        XCTAssertEqual(PlannerStore(url: url).archive.events, [event])
        event.end = start
        XCTAssertFalse(store.saveEvent(event))
        event.end = start.addingTimeInterval(3600); event.meetingURL = URL(string: "file:///etc/passwd")
        XCTAssertFalse(store.saveEvent(event))
        XCTAssertTrue(store.deleteEvent(event.id))
        XCTAssertTrue(PlannerStore(url: url).archive.events.isEmpty)
    }

    func testAllDayAndOvernightEventsAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        var event = PlannerEvent(title: "Day off", start: start, end: end, allDay: true)
        event.timeZoneIdentifier = calendar.timeZone.identifier
        XCTAssertTrue(event.occurs(on: start, calendar: calendar))
        XCTAssertFalse(event.occurs(on: end, calendar: calendar))
        let overnight = PlannerEvent(title: "Night shift", start: start.addingTimeInterval(-1800), end: start.addingTimeInterval(1800))
        XCTAssertTrue(overnight.occurs(on: start, calendar: calendar))
        XCTAssertTrue(overnight.occurs(on: start.addingTimeInterval(-3600), calendar: calendar))
    }

    func testMonthGridRespectsFirstWeekdayAndLeapYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2028, month: 2, day: 20)))
        let days = PlannerMonth.days(containing: date, calendar: calendar)
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), 2)
        XCTAssertEqual(days.filter { calendar.component(.month, from: $0) == 2 }.count, 29)
        XCTAssertEqual(Set(days).count, 42)
    }

    func testToolSearchAndRoutingLeaveSavedLayoutAlone() {
        XCTAssertEqual(HoverSlotRouter.effect(for: .tasks), .openPanel(.tasks))
        XCTAssertEqual(HoverSlotRouter.effect(for: .calendar), .openPanel(.calendar))
        XCTAssertTrue(HoverSlotRouter.effect(for: .tasks).requiresExpansion)
        XCTAssertEqual(IslandHoverToolSearch.results(for: "задачи").first, .tasks)
        XCTAssertEqual(IslandHoverToolSearch.results(for: "calendar").first, .calendar)
        XCTAssertFalse(HoverLayoutStore.defaultSlots.contains(.tasks))
        XCTAssertFalse(HoverLayoutStore.defaultSlots.contains(.calendar))
    }

    func testPlannerWindowUsesSharedHoverPolicyWithoutShowingOrReadingUserData() throws {
        _ = NSApplication.shared
        let suite = "test.planner-window." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PlannerWindowController(store: PlannerStore(url: url), connections: CalendarConnections(defaults: defaults))
        let window = try XCTUnwrap(controller.window)
        defer { window.contentViewController = nil; window.close() }
        XCTAssertEqual(window.level, .statusBar)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
