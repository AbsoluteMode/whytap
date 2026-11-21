import AppKit
import XCTest
@testable import Sidekey

/// The Calendar hover day view: blocks on an hour grid, service logos and
/// what a click on an event does.
/// WHY: .project-docs/decisions/2026-11-20-calendar-day-view.md,
/// .project-docs/decisions/2026-11-21-calendar-logos.md
@MainActor
final class CalendarDayViewTests: XCTestCase {
    override func setUp() { super.setUp(); openCalendarForThisTest() }

    private let calendar = Calendar.current
    private var day: DateInterval {
        calendar.dateInterval(of: .day, for: calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!)!
    }

    private func item(_ id: String, _ from: Double, _ to: Double, feed: String = "local", allDay: Bool = false,
                      meeting: String? = nil, source: String? = nil) -> CalendarFeedEvent {
        CalendarFeedEvent(id: id, feedID: feed,
            event: PlannerEvent(title: id, start: day.start.addingTimeInterval(from * 3600), end: day.start.addingTimeInterval(to * 3600),
                                allDay: allDay, meetingURL: meeting.flatMap(URL.init(string:))),
            sourceURL: source.flatMap(URL.init(string:)))
    }

    func testOverlappingEventsShareTheWidthAndSeparateOnesDoNot() {
        let blocks = CalendarDayLayout.blocks([
            item("standup", 9.5, 9.75), item("review", 11, 12), item("pickup", 11.5, 12.25),
            item("lunch", 12, 13), item("gym", 17, 18),
        ], day: day, minimumHours: 0.4)
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.item.id, $0) })
        XCTAssertEqual(byID["standup"]?.columns, 1)
        XCTAssertEqual(byID["review"]?.column, 0); XCTAssertEqual(byID["pickup"]?.column, 1)
        // Lunch starts when review ends, so it reuses review's column inside the same group.
        XCTAssertEqual(byID["lunch"]?.column, 0)
        XCTAssertEqual(Set(["review", "pickup", "lunch"].map { byID[$0]!.columns }), [2])
        XCTAssertEqual(byID["gym"]?.columns, 1); XCTAssertEqual(byID["gym"]?.top, 17)
        XCTAssertEqual(byID["review"]?.height, 1)
    }

    func testBlocksAreClippedToTheDayAndShortOnesKeepAReadableHeight() {
        let blocks = CalendarDayLayout.blocks([
            item("overnight", -1, 0.5), item("five-minutes", 10, 10 + 5.0 / 60), item("late", 23.95, 24.5),
            item("all-day", 0, 24, allDay: true),
        ], day: day, minimumHours: 0.4)
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.item.id, $0) })
        XCTAssertNil(byID["all-day"], "All-day events have their own row")
        XCTAssertEqual(byID["overnight"]?.top, 0); XCTAssertEqual(byID["overnight"]?.height, 0.5)
        XCTAssertEqual(byID["five-minutes"]!.height, 0.4, accuracy: 0.0001)
        XCTAssertEqual(byID["late"]!.top + byID["late"]!.height, 24, accuracy: 0.0001)
        XCTAssertEqual(byID["late"]!.height, 0.4, accuracy: 0.0001)
    }

    func testDaylightSavingDaysHaveTheirRealNumberOfHours() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let spring = try XCTUnwrap(newYork.dateInterval(of: .day, for: newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!))
        let autumn = try XCTUnwrap(newYork.dateInterval(of: .day, for: newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!))
        XCTAssertEqual(CalendarDayLayout.hours(of: spring, calendar: newYork).count, 23)
        XCTAssertEqual(CalendarDayLayout.hours(of: autumn, calendar: newYork).count, 25)
        XCTAssertEqual(CalendarDayLayout.length(of: spring), 23)
    }

    func testTheDayOpensAnHourBeforeNowOrTheFirstEvent() {
        let blocks = CalendarDayLayout.blocks([item("review", 11, 12)], day: day, minimumHours: 0.4)
        XCTAssertEqual(CalendarDayLayout.initialHour(events: blocks, isToday: true, now: day.start.addingTimeInterval(10.4 * 3600), day: day), 9)
        XCTAssertEqual(CalendarDayLayout.initialHour(events: blocks, isToday: false, now: day.start, day: day), 10)
        XCTAssertEqual(CalendarDayLayout.initialHour(events: [], isToday: false, now: day.start, day: day), 8)
        XCTAssertEqual(CalendarDayLayout.initialHour(events: [], isToday: true, now: day.start.addingTimeInterval(1800), day: day), 0)
    }

    func testClickJoinsTheMeetingFirstThenOpensTheOriginal() {
        let both = item("review", 11, 12, meeting: "https://meet.google.com/abc", source: "https://calendar.google.com/event?eid=1")
        XCTAssertEqual(CalendarEventAction.resolve(both), .join(URL(string: "https://meet.google.com/abc")!))
        let original = item("standup", 9, 10, source: "https://calendar.google.com/event?eid=2")
        XCTAssertEqual(CalendarEventAction.resolve(original), .open(URL(string: "https://calendar.google.com/event?eid=2")!))
        XCTAssertNil(CalendarEventAction.resolve(item("local", 9, 10)))

        let model = CalendarHoverModel(store: PlannerStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("planner.json")),
            connections: CalendarConnections(defaults: UserDefaults(suiteName: "calendar.day.\(UUID().uuidString)")!))
        var opened: [URL] = []
        model.openURL = { opened.append($0) }
        XCTAssertTrue(model.perform(both)); XCTAssertTrue(model.perform(original))
        XCTAssertFalse(model.perform(item("local", 9, 10)), "An event with nowhere to go does nothing")
        XCTAssertEqual(opened.map(\.host), ["meet.google.com", "calendar.google.com"])
        XCTAssertEqual(model.actionTitle(both), "Join meeting")
        XCTAssertEqual(model.actionTitle(original), "Open in Google Calendar", "The link's own host names the service")
        XCTAssertEqual(model.actionTitle(item("unknown", 9, 10, source: "https://calendar.example.com/e/1")), "Open in its calendar")
        XCTAssertNil(model.actionTitle(item("local", 9, 10)))
        // A merged copy that opens another service's link names that service.
        XCTAssertEqual(model.actionTitle(item("merged", 9, 10, feed: "zoom-copy", source: "https://outlook.office.com/calendar/item/1")),
                       "Open in Outlook & Teams")
        XCTAssertEqual(model.actionTitle(item("mac", 9, 10, source: "ical://ekevent/X?method=show&options=more")), "Open in Calendar")
    }

    func testHalfHourDaylightSavingRowsStartOffTheHour() throws {
        var lordHowe = Calendar(identifier: .gregorian)
        lordHowe.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Lord_Howe"))
        let dayOfShift = try XCTUnwrap(lordHowe.dateInterval(of: .day, for: lordHowe.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!))
        let hours = CalendarDayLayout.hours(of: dayOfShift, calendar: lordHowe)
        XCTAssertEqual(CalendarDayLayout.length(of: dayOfShift), 23.5, accuracy: 0.001)
        XCTAssertTrue(hours.contains { lordHowe.component(.minute, from: $0.date) == 30 },
                      "Rows after the shift start at :30, so their labels need minutes")
    }

    func testAppleEventsOpenInCalendarOnThisMac() {
        XCTAssertEqual(CalendarEventAction.appleEventURL(identifier: "9A1B-22C3")?.absoluteString,
                       "ical://ekevent/9A1B-22C3?method=show&options=more")
        XCTAssertEqual(CalendarEventAction.appleEventURL(identifier: "a/b?c")?.absoluteString,
                       "ical://ekevent/a%2Fb%3Fc?method=show&options=more")
        XCTAssertNil(CalendarEventAction.appleEventURL(identifier: ""))
    }

    func testEachEventNamesItsServiceAndEveryCalendarIsShown() async throws {
        let tests = CalendarHoverTests(); try await tests.setUp()
        defer { Task { try? await tests.tearDown() } }
        let model = try tests.fakeGoogleModel()
        model.begin(); await model.connections.refresh(interval: model.interval)
        let review = try XCTUnwrap(model.events.first { $0.event.title == "Design review" })
        XCTAssertEqual(model.source(review.feedID), .provider(.google))
        XCTAssertEqual(model.actionTitle(review), "Join meeting")
        let standup = try XCTUnwrap(model.events.first { $0.event.title == "Team standup" })
        XCTAssertEqual(model.actionTitle(standup), "Open in Google Calendar")
        XCTAssertEqual(model.source("local"), .whytap)
        XCTAssertNil(model.source("gone:calendar"), "A calendar that disappeared gets the generic symbol")
        XCTAssertEqual(model.events.filter(\.event.allDay).map(\.event.title), ["Company offsite"])
        // A hiding choice saved by an older build no longer removes anything from Hover.
        for feed in model.connections.feeds { model.connections.setVisible(false, feedID: feed.id) }
        XCTAssertEqual(Set(model.events.map(\.event.title)), ["Company offsite", "Team standup", "Design review", "School pickup"])
        XCTAssertTrue(model.isConnected(.google)); XCTAssertFalse(model.isConnected(.microsoft))
        // The Connect rows say the same thing on screen and to VoiceOver.
        XCTAssertEqual(model.connectState(.google), .addAccount)
        XCTAssertEqual(model.connectAccessibilityLabel(.google), "Add Google Calendar account")
        XCTAssertEqual(model.connectState(.microsoft), .connect)
        XCTAssertEqual(model.connectAccessibilityLabel(.microsoft), "Connect Outlook Calendar")
    }

    func testLogosComeFromTheBundleOrTheInstalledApp() throws {
        let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/UsefulLinkIcons")
        let lookup = CalendarSourceLogo.applicationURL
        defer { CalendarSourceLogo.resourceDirectoryForTesting = nil; CalendarSourceLogo.applicationURL = lookup }
        CalendarSourceLogo.resourceDirectoryForTesting = icons
        CalendarSourceLogo.applicationURL = { _ in nil }
        for source: CalendarEventSource in [.whytap, .provider(.google), .provider(.microsoft), .provider(.zoom)] {
            let image = try XCTUnwrap(CalendarSourceLogo.image(for: source), "\(source) is bundled")
            XCTAssertFalse(image.isTemplate, "Logos keep their own colours")
        }
        XCTAssertNil(CalendarSourceLogo.image(for: .provider(.apple)), "No Calendar app, no logo: the view falls back to a symbol")
        CalendarSourceLogo.applicationURL = { $0 == CalendarSourceLogo.appleCalendarBundleID
            ? URL(fileURLWithPath: "/System/Applications/Calendar.app") : nil }
        XCTAssertNotNil(CalendarSourceLogo.image(for: .provider(.apple)))
        CalendarSourceLogo.resourceDirectoryForTesting = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(CalendarSourceLogo.image(for: .whytap), "A missing asset is no image, not a crash")
    }

    /// An app icon's transparent margin is cut away so it is as big as a flat logo.
    func testLogoMarginsAreTrimmedSoLogosMatchInSize() throws {
        let padded = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { _ in
            NSColor.red.setFill(); NSRect(x: 20, y: 30, width: 60, height: 60).fill(); return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(CalendarSourceLogo.trimmed(padded).tiffRepresentation)))
        let corner = try XCTUnwrap(bitmap.colorAt(x: 2, y: 2))
        XCTAssertGreaterThan(corner.alphaComponent, 0.9, "The visible square reaches the corners after trimming")
        let blank = NSImage(size: NSSize(width: 10, height: 10))
        XCTAssertTrue(CalendarSourceLogo.trimmed(blank) === blank, "A fully transparent image is left as it is")
    }
}
