import XCTest
@testable import Sidekey

/// What an event block shows for its height, when hovering it opens the
/// full-details preview, and what that preview says.
/// WHY: .project-docs/decisions/2026-11-21-calendar-event-details.md
@MainActor
final class CalendarEventPreviewTests: XCTestCase {
    override func setUp() { super.setUp(); openCalendarForThisTest() }

    private let width: CGFloat = 170
    private let meta = "11:00 – 12:00 · Work"
    private let longTitle = "Quarterly planning with the whole design, research and engineering group"

    /// Block height of an event lasting `hours` on the 44 pt/hour grid.
    private func height(_ hours: CGFloat) -> CGFloat { hours * CalendarDayGrid.hourHeight - 2 }

    private func plan(_ hours: CGFloat, title: String = "Sync", meta: String? = nil, notes: String = "",
                      attendees: String? = nil, hasAttendees: Bool? = nil, hasLocation: Bool = false,
                      width: CGFloat? = nil) -> CalendarEventBlockPlan {
        CalendarEventBlockPlan.make(height: height(hours), textWidth: width ?? self.width, title: title,
                                    meta: meta ?? self.meta, notes: notes, attendeeSummary: attendees,
                                    hasAttendees: hasAttendees ?? (attendees != nil), hasLocation: hasLocation)
    }

    // MARK: Block content by height

    func testShortEventsKeepOneLineAndAlwaysOfferThePreview() {
        let half = plan(0.5)
        XCTAssertTrue(half.oneLine)
        XCTAssertTrue(half.needsPreview, "One line shows only the start time")
        XCTAssertTrue(plan(0.25).oneLine)
    }

    func testAFortyFiveMinuteEventShowsTitleAndTimeWithoutAPreviewWhenThatIsEverything() {
        let result = plan(0.75)
        XCTAssertFalse(result.oneLine)
        XCTAssertEqual(result.titleLines, 1); XCTAssertEqual(result.noteLines, 0); XCTAssertFalse(result.showsAttendees)
        XCTAssertFalse(result.needsPreview, "Everything fits, so no preview, like To-do")
    }

    func testAnHourAddsTheFirstLineOfTheDescription() {
        let short = plan(1, notes: "Agenda in the doc")
        XCTAssertEqual(short.noteLines, 1)
        XCTAssertFalse(short.needsPreview)
        let long = plan(1, notes: "Agenda\nDemo\nQuestions")
        XCTAssertEqual(long.noteLines, 1)
        XCTAssertTrue(long.needsPreview, "Description lines are cut")
    }

    func testTheTitleOutranksTheDescription() {
        let result = plan(1, title: longTitle, notes: "Agenda")
        XCTAssertEqual(result.titleLines, 2)
        XCTAssertEqual(result.noteLines, 0)
        XCTAssertTrue(result.needsPreview)
    }

    func testDescriptionComesBeforeAttendeesAndSpareRoomExtendsIt() {
        let notes = (1...6).map { "Point \($0)" }.joined(separator: "\n")
        let twoHours = plan(2, notes: notes, attendees: "Anna, Boris +3")
        XCTAssertEqual(twoHours.noteLines, 3)
        XCTAssertTrue(twoHours.showsAttendees)
        XCTAssertTrue(twoHours.needsPreview)
        let fourHours = plan(4, notes: notes, attendees: "Anna, Boris +3")
        XCTAssertEqual(fourHours.noteLines, 6, "Room left after the attendees goes back to the description")
        XCTAssertTrue(fourHours.showsAttendees)
        XCTAssertTrue(fourHours.needsPreview, "The block names only some attendees, without their responses")
        let onlyNotes = plan(4, notes: notes)
        XCTAssertEqual(onlyNotes.noteLines, 6)
        XCTAssertFalse(onlyNotes.needsPreview)
    }

    func testDetailsTheBlockNeverShowsOrCutsOpenThePreview() {
        XCTAssertTrue(plan(2, hasLocation: true).needsPreview, "Location lives only in the preview")
        XCTAssertTrue(plan(2, hasAttendees: true).needsPreview, "Only you attending still has a list to show")
        XCTAssertTrue(plan(2, meta: "11:00 AM – 12:00 PM · A very long calendar name · anna@example.com", width: 60).needsPreview,
                      "A cut time or calendar line")
    }

    func testAllDayChipsPreviewOnlyWhenSomethingIsCutOrMissing() {
        XCTAssertFalse(CalendarEventBlockPlan.chipNeedsPreview(title: "Day off", source: "Home", hasDetails: false))
        XCTAssertTrue(CalendarEventBlockPlan.chipNeedsPreview(title: "Day off", source: "Home", hasDetails: true))
        XCTAssertTrue(CalendarEventBlockPlan.chipNeedsPreview(title: longTitle, source: "Home", hasDetails: false))
    }

    // MARK: Preview content

    private func model() -> CalendarHoverModel {
        CalendarHoverModel(store: PlannerStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("planner.json")),
            connections: CalendarConnections(defaults: UserDefaults(suiteName: "calendar.preview.\(UUID().uuidString)")!))
    }

    func testThePreviewHasEveryDetail() throws {
        let start = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 11)))
        var event = PlannerEvent(title: "Design review", start: start, end: start.addingTimeInterval(3600),
                                 location: "Room 4", notes: "<p>Agenda<br>1. Intro &amp; goals</p>",
                                 meetingURL: URL(string: "https://us02web.zoom.us/j/123?pwd=secret"))
        event.attendees = [PlannerEventAttendee(name: "Anna", email: "anna@example.com", isOrganizer: true)]
        let item = CalendarFeedEvent(id: "e1", feedID: "local", event: event, sourceURL: nil)
        let preview = model().previewContent(item)
        XCTAssertEqual(preview.id, "e1")
        XCTAssertEqual(preview.title, "Design review")
        XCTAssertTrue(preview.when.contains(try XCTUnwrap(CalendarEventBlockLabel.timeRange(event))), preview.when)
        XCTAssertEqual(preview.calendar, "Whytap · On this Mac")
        XCTAssertEqual(preview.source, .whytap)
        XCTAssertEqual(preview.location, "Room 4")
        XCTAssertEqual(preview.action, "Join meeting")
        XCTAssertEqual(preview.link, "us02web.zoom.us/j/123", "The link's password stays out of view")
        XCTAssertEqual(preview.notes, "Agenda\n1. Intro & goals")
        XCTAssertEqual(preview.attendees.map(\.displayName), ["Anna"])

        let allDay = CalendarFeedEvent(id: "e2", feedID: "local",
            event: PlannerEvent(title: "Off", start: Calendar.current.startOfDay(for: start),
                                end: Calendar.current.startOfDay(for: start).addingTimeInterval(86400), allDay: true), sourceURL: nil)
        let offDay = model().previewContent(allDay)
        XCTAssertTrue(offDay.when.hasSuffix("All day"), offDay.when)
        XCTAssertNil(offDay.location); XCTAssertNil(offDay.notes); XCTAssertNil(offDay.action); XCTAssertNil(offDay.link)
    }

    func testDescriptionsReadAsPlainText() {
        XCTAssertEqual(CalendarEventText.plain("<b>Bold</b> &lt;tag&gt;&nbsp;x<div>Next</div>"), "Bold <tag> x\nNext")
        XCTAssertEqual(CalendarEventText.plain("  a < b and c > d  "), "a < b and c > d", "Plain text with angle brackets stays")
        XCTAssertEqual(CalendarEventText.plain("One\n\n\n\nTwo\r\n"), "One\n\nTwo")
        XCTAssertEqual(CalendarEventText.plain(""), "")
    }

    func testTeamsInvitationsLoseTheirSeparatorsAndBracketedLinks() {
        let rule = String(repeating: "_", count: 80)
        let russian = """
        \(rule)
        Совещание в Microsoft Teams
        Присоединиться на компьютере, в мобильном приложении или в Интернете
        Щелкните здесь, чтобы присоединиться к собранию<https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d>
        Идентификатор собрания: 938 763 481 588 9
        Секретный код: Ab3cDe
        Скачать Teams<https://www.microsoft.com/en-us/microsoft-teams/download-app> | Присоединиться в Интернете<https://www.microsoft.com/microsoft-teams/join-a-meeting>
        Подробнее<https://aka.ms/JoinTeamsMeeting> | Параметры собрания<https://teams.microsoft.com/meetingOptions/?organizerId=x>
        \(rule)
        """
        XCTAssertEqual(CalendarEventText.plain(russian), """
        Совещание в Microsoft Teams
        Присоединиться на компьютере, в мобильном приложении или в Интернете
        Щелкните здесь, чтобы присоединиться к собранию
        Идентификатор собрания: 938 763 481 588 9
        Секретный код: Ab3cDe
        Скачать Teams | Присоединиться в Интернете
        Подробнее | Параметры собрания
        """)
        let english = "Agenda: roadmap\r\n\r\n\(rule)\r\nMicrosoft Teams Need help?<https://aka.ms/JoinTeamsMeeting?omkt=en-US>\r\n"
            + "Join the meeting now<https://teams.microsoft.com/l/meetup-join/1>\r\nMeeting ID: 938 763 481 588 9\r\n"
            + "Passcode: Ab3cDe\r\n \u{00A0}\r\n\(rule)\r\n  \r\n"
        XCTAssertEqual(CalendarEventText.plain(english),
                       "Agenda: roadmap\n\nMicrosoft Teams Need help?\nJoin the meeting now\nMeeting ID: 938 763 481 588 9\nPasscode: Ab3cDe")
    }

    func testGoogleMeetInvitationsLoseTheirSeparators() {
        let rule = "-::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-"
        let invitation = """
        Weekly sync notes in the doc.
        \(rule)
        Join with Google Meet: https://meet.google.com/abc-defg-hij
        Or dial: (US) +1 555-555-0100 PIN: 123456789#

        Learn more about Meet at: https://support.google.com/a/users/answer/9282720

        Please do not edit this section.
        \(rule)
        """
        XCTAssertEqual(CalendarEventText.plain(invitation), """
        Weekly sync notes in the doc.
        Join with Google Meet: https://meet.google.com/abc-defg-hij
        Or dial: (US) +1 555-555-0100 PIN: 123456789#

        Learn more about Meet at: https://support.google.com/a/users/answer/9282720

        Please do not edit this section.
        """)
        let html = "<p>Notes</p><p>\(rule)</p>Join with Google Meet: <a href=\"https://meet.google.com/x\">meet.google.com/x</a>"
        XCTAssertEqual(CalendarEventText.plain(html), "Notes\n\nJoin with Google Meet: meet.google.com/x")
    }

    func testOnlyWholeDecorativeLinesAreSeparators() {
        for rule in ["---", "= = = =", "────────", "━━━━", "*****", "~~~~", "___ ___", "-:~:-"] {
            XCTAssertEqual(CalendarEventText.plain("A\n\(rule)\nB"), "A\nB", rule)
        }
        XCTAssertEqual(CalendarEventText.plain("A\n-\nB"), "A\n-\nB", "A single dash is content")
        XCTAssertEqual(CalendarEventText.plain("Q&A -- 10 min\nsnake_case_name\n2 * 3 = 6"), "Q&A -- 10 min\nsnake_case_name\n2 * 3 = 6")
        XCTAssertEqual(CalendarEventText.plain("Docs <https://x.com/doc> and <notes>"), "Docs  and <notes>",
                       "Only bracketed web, mail and phone links go")
    }

    // MARK: Preview state

    private func content(_ id: String) -> CalendarEventPreviewContent {
        CalendarEventPreviewContent(id: id, title: id, when: "", calendar: "", source: nil, location: nil,
                                    action: nil, link: nil, notes: nil, attendees: [])
    }

    func testTheBubbleStartsBesideTheEventAndStaysInsideTheIslandArea() {
        XCTAssertEqual(CalendarEventPreviewPolicy.bubbleTop(eventTop: 120, bubbleHeight: 100, areaHeight: 400), 120)
        XCTAssertEqual(CalendarEventPreviewPolicy.bubbleTop(eventTop: 360, bubbleHeight: 100, areaHeight: 400), 300,
                       "A late event lifts the bubble so its bottom stays visible")
        XCTAssertEqual(CalendarEventPreviewPolicy.bubbleTop(eventTop: 50, bubbleHeight: 500, areaHeight: 400), 0,
                       "A bubble taller than the area starts at its top")
    }

    func testAClosedCalendarNeverShowsAPreview() {
        closeCalendarForThisTest()
        let state = CalendarEventPreviewState(hideDelay: .milliseconds(40))
        state.show(content("a"), frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        XCTAssertNil(state.anchor, "A closed (Soon) Calendar shows no event details anywhere")
    }

    func testTheDescriptionGetsTheLinesItsRoomHolds() {
        XCTAssertEqual(CalendarEventPreviewPolicy.descriptionLines(room: 131, lineHeight: 13.1), 10)
        XCTAssertEqual(CalendarEventPreviewPolicy.descriptionLines(room: 38.9, lineHeight: 13.1), 3)
        XCTAssertEqual(CalendarEventPreviewPolicy.descriptionLines(room: 2, lineHeight: 13.1), 1, "Never less than a line")
        XCTAssertNil(CalendarEventPreviewPolicy.descriptionLines(room: .greatestFiniteMagnitude, lineHeight: 13.1),
                     "Before the first layout there is no limit")
        XCTAssertNil(CalendarEventPreviewPolicy.descriptionLines(room: 100, lineHeight: 0))
    }

    func testMovingBetweenEventsNeverFlashesAnEmptyPreview() async throws {
        let state = CalendarEventPreviewState(hideDelay: .milliseconds(40))
        let first = content("a"), second = content("b")
        var seen: [String?] = []
        let watch = state.$anchor.sink { seen.append($0?.content.id) }
        defer { watch.cancel() }
        state.show(first, frame: CGRect(x: 0, y: 10, width: 100, height: 40))
        state.hide("a")
        state.show(second, frame: CGRect(x: 0, y: 60, width: 100, height: 40))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(seen, [nil, "a", "b"])
        state.hide("a")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(state.anchor?.content.id, "b", "Leaving an event that is no longer shown changes nothing")
        state.hide("b")
        XCTAssertEqual(state.anchor?.content.id, "b", "Hiding waits briefly for the next event")
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while state.anchor != nil, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(state.anchor)
        state.show(first, frame: .zero); state.clear()
        XCTAssertNil(state.anchor, "Closing the panel hides at once")
    }
}
