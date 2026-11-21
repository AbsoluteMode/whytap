import EventKit
import XCTest
@testable import Sidekey

/// Which service's logo an EventKit calendar shows, and the attendees an event
/// carries in memory.
/// WHY: .project-docs/decisions/2026-11-21-calendar-event-details.md
@MainActor
final class CalendarEventDetailsTests: XCTestCase {
    // MARK: Service behind a calendar on this Mac

    func testGoogleAccountsOnThisMacShowTheGoogleLogo() {
        for title in ["Google", "anna@gmail.com", "Anna.Petrova@GoogleMail.com", "Work (Google)"] {
            XCTAssertEqual(CalendarDisplayService.classify(sourceType: .calDAV, sourceTitle: title), .google, title)
        }
    }

    func testExchangeAndOutlookAccountsShowTheOutlookLogo() {
        XCTAssertEqual(CalendarDisplayService.classify(sourceType: .exchange, sourceTitle: "Company"), .microsoft,
                       "Every Exchange account is Microsoft's")
        for title in ["Outlook", "anna@outlook.com", "anna@hotmail.co.uk", "anna@live.fr", "anna@msn.com",
                      "Office 365", "Office365", "Microsoft", "Exchange"] {
            XCTAssertEqual(CalendarDisplayService.classify(sourceType: .calDAV, sourceTitle: title), .microsoft, title)
        }
    }

    func testICloudLocalSubscribedAndUnknownKeepTheCalendarLogo() {
        XCTAssertEqual(CalendarDisplayService.classify(sourceType: .mobileMe, sourceTitle: "iCloud"), .apple)
        XCTAssertEqual(CalendarDisplayService.classify(sourceType: .local, sourceTitle: "On My Mac"), .apple)
        XCTAssertEqual(CalendarDisplayService.classify(sourceType: .birthdays, sourceTitle: "Other"), .apple)
        XCTAssertEqual(CalendarDisplayService.classify(sourceType: .subscribed, sourceTitle: "Google holidays"), .apple,
                       "A subscription is read by Calendar itself, whatever its name")
        XCTAssertEqual(CalendarDisplayService.classify(sourceType: .calDAV, sourceTitle: "anna@fastmail.com"), .apple)
        XCTAssertEqual(CalendarDisplayService.classify(sourceType: .calDAV, sourceTitle: "anna@olive.com"), .apple,
                       "Only whole domain labels count")
        XCTAssertEqual(CalendarDisplayService.classify(sourceType: .calDAV, sourceTitle: ""), .apple)
    }

    func testAFeedShowsItsDisplayServiceButStaysAnAppleConnection() {
        let google = CalendarFeed(id: "apple:1", remoteID: "1", title: "Work · anna@gmail.com", provider: .apple,
                                  displayService: .google)
        XCTAssertEqual(google.provider, .apple, "Disconnect and permissions still treat it as Calendar on this Mac")
        XCTAssertEqual(CalendarEventSource.of(google), .provider(.google))
        let plain = CalendarFeed(id: "apple:2", remoteID: "2", title: "Home · iCloud", provider: .apple)
        XCTAssertEqual(CalendarEventSource.of(plain), .provider(.apple))
        XCTAssertNil(CalendarEventSource.of(CalendarFeed(id: "x", remoteID: "x", title: "?", provider: nil)))
    }

    // MARK: Attendees

    func testOrganizerLeadsAndDuplicatesMergeKeepingTheResponse() {
        let organizer = PlannerEventAttendee(name: "Boris", email: "boris@example.com", isOrganizer: true, status: .accepted)
        let merged = PlannerEventAttendee.merged(organizer: organizer, attendees: [
            PlannerEventAttendee(name: "Anna", email: "anna@example.com", status: .tentative),
            PlannerEventAttendee(name: "Boris B.", email: "BORIS@example.com", status: .declined),
            PlannerEventAttendee(name: "Anna", email: "anna@example.com", status: .accepted),
        ])
        XCTAssertEqual(merged.map(\.email), ["boris@example.com", "anna@example.com"])
        XCTAssertTrue(merged[0].isOrganizer)
        XCTAssertEqual(merged[0].status, .declined, "The organizer's own row in the list carries their response")
        XCTAssertEqual(merged[1].status, .tentative)
        XCTAssertEqual(PlannerEventAttendee.merged(organizer: nil, attendees: []), [])
    }

    func testNamesFallBackToTheEmailAddress() {
        XCTAssertEqual(PlannerEventAttendee(name: "  Anna Petrova ", email: "a@x.com").displayName, "Anna Petrova")
        XCTAssertEqual(PlannerEventAttendee(name: "", email: "a@x.com").displayName, "a@x.com")
        XCTAssertEqual(PlannerEventAttendee(name: "", email: "").displayName, "Unknown attendee")
        XCTAssertEqual(PlannerEventAttendee.email(fromParticipantURL: URL(string: "mailto:Anna@Example.com")!), "Anna@Example.com")
        XCTAssertEqual(PlannerEventAttendee.email(fromParticipantURL: URL(string: "mailto:a%20b@x.com")!), "a b@x.com")
        XCTAssertNil(PlannerEventAttendee.email(fromParticipantURL: URL(string: "urn:uuid:123")!))
    }

    func testEventKitResponsesMap() {
        XCTAssertEqual(PlannerEventAttendee.Status(.accepted), .accepted)
        XCTAssertEqual(PlannerEventAttendee.Status(.declined), .declined)
        XCTAssertEqual(PlannerEventAttendee.Status(.tentative), .tentative)
        XCTAssertEqual(PlannerEventAttendee.Status(.pending), .pending)
        XCTAssertNil(PlannerEventAttendee.Status(.unknown))
    }

    func testCompactSummaryNamesTwoOthersAndCountsTheRest() {
        let people = ["Anna Petrova", "Boris", "", "Dmitry", "Eva"].enumerated().map { index, name in
            PlannerEventAttendee(name: name, email: "p\(index)@x.com")
        }
        XCTAssertEqual(PlannerEventAttendee.compactSummary(people), "Anna, Boris +3")
        XCTAssertEqual(PlannerEventAttendee.compactSummary(Array(people.prefix(2))), "Anna, Boris")
        let me = PlannerEventAttendee(name: "Me", email: "me@x.com", isCurrentUser: true)
        XCTAssertEqual(PlannerEventAttendee.compactSummary([me, people[1]]), "Boris", "You are not listed in the block")
        XCTAssertNil(PlannerEventAttendee.compactSummary([me]))
        XCTAssertNil(PlannerEventAttendee.compactSummary([]))
        XCTAssertEqual(PlannerEventAttendee.compactSummary([people[2]]), "p2@x.com")
    }

    func testMicrosoftEventsCarryAttendeesAndTheOrganizer() throws {
        let feed = CalendarFeed(id: "feed", remoteID: "id", title: "Work", provider: .microsoft)
        let row: [String: Any] = ["id": "event", "subject": "Planning",
            "start": ["dateTime": "2026-10-19T09:00:00.0000000", "timeZone": "UTC"],
            "end": ["dateTime": "2026-10-19T10:00:00.0000000", "timeZone": "UTC"],
            "isOrganizer": true,
            "organizer": ["emailAddress": ["name": "Me", "address": "me@contoso.com"]],
            "attendees": [
                ["type": "required", "status": ["response": "accepted"], "emailAddress": ["name": "Anna", "address": "anna@contoso.com"]],
                ["type": "optional", "status": ["response": "tentativelyAccepted"], "emailAddress": ["address": "boris@contoso.com"]],
                ["type": "required", "status": ["response": "declined"], "emailAddress": ["name": "Carl", "address": "carl@contoso.com"]],
                ["type": "required", "status": ["response": "notResponded"], "emailAddress": ["name": "Dana"]],
                ["type": "resource", "status": ["response": "none"], "emailAddress": "not an object"],
            ]]
        let item = try XCTUnwrap(CalendarRemoteClient.event(row, feed: feed))
        let attendees = item.event.attendees
        XCTAssertEqual(attendees.map(\.displayName), ["Me", "Anna", "boris@contoso.com", "Carl", "Dana"])
        XCTAssertTrue(attendees[0].isOrganizer); XCTAssertTrue(attendees[0].isCurrentUser)
        XCTAssertEqual(attendees.map(\.status), [nil, .accepted, .tentative, .declined, .pending],
                       "The organizer has no response of their own; an unreadable row is skipped")
    }

    func testGoogleDirectEventsDoNotReadAttendees() throws {
        let feed = CalendarFeed(id: "feed", remoteID: "id", title: "Work", provider: .google)
        let row: [String: Any] = ["id": "event", "summary": "Sync",
            "start": ["dateTime": "2026-10-19T09:00:00Z"], "end": ["dateTime": "2026-10-19T10:00:00Z"],
            "organizer": ["email": "boss@example.com"],
            "attendees": [["email": "anna@example.com", "displayName": "Anna", "responseStatus": "accepted"]]]
        let item = try XCTUnwrap(CalendarRemoteClient.event(row, feed: feed))
        XCTAssertEqual(item.event.attendees, [], "Google direct access stays as declared for Google verification")
    }

    func testAttendeesAreNeverSavedAndOldArchivesStillLoad() throws {
        var event = PlannerEvent(title: "Review", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600))
        event.attendees = [PlannerEventAttendee(name: "Anna", email: "anna@example.com")]
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("attendees"), json)
        XCTAssertFalse(json.contains("anna@example.com"), json)
        let decoded = try JSONDecoder().decode(PlannerEvent.self, from: data)
        XCTAssertEqual(decoded.attendees, [])
        XCTAssertEqual(decoded.title, "Review")
        let old = Data("""
        {"id":"8F0D3C55-3A35-4D5F-9F3B-2E3F0B1E2A11","title":"Old","start":0,"end":3600,"allDay":false,
         "location":"","notes":"","timeZoneIdentifier":"UTC"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PlannerEvent.self, from: old).title, "Old")
    }

    func testMergedCopiesKeepTheAttendeesOfWhicheverCopyHasThem() {
        let start = Date(timeIntervalSince1970: 0)
        var withPeople = PlannerEvent(title: "Sync", start: start, end: start.addingTimeInterval(3600))
        withPeople.attendees = [PlannerEventAttendee(name: "Anna", email: "anna@example.com")]
        let bare = PlannerEvent(title: "Sync", start: start, end: start.addingTimeInterval(3600))
        let merged = CalendarEventMerger.merge([
            CalendarFeedEvent(id: "a", feedID: "zoom", event: bare, sourceURL: nil, externalUID: "uid"),
            CalendarFeedEvent(id: "b", feedID: "outlook", event: withPeople, sourceURL: nil, externalUID: "uid"),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.event.attendees.map(\.email), ["anna@example.com"])
    }
}
