import XCTest
@testable import Sidekey

final class CalendarProviderTests: XCTestCase {
    override func setUp() { super.setUp(); openCalendarForThisTest() }

    func testAllDayInclusiveAndExclusiveEndsMergeAcrossTimeZones() throws {
        var origin = Calendar(identifier: .gregorian)
        origin.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(origin.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let end = try XCTUnwrap(origin.date(byAdding: .day, value: 1, to: start))
        var first = PlannerEvent(title: "Day off", start: start, end: end.addingTimeInterval(-1), allDay: true)
        first.timeZoneIdentifier = origin.timeZone.identifier
        var second = first; second.end = end
        var viewer = Calendar(identifier: .gregorian)
        viewer.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertEqual(first.displayBounds(calendar: viewer), second.displayBounds(calendar: viewer))
        let merged = CalendarEventMerger.merge([
            CalendarFeedEvent(id: "apple", feedID: "apple:one", event: first, externalUID: "fixture"),
            CalendarFeedEvent(id: "google", feedID: "google:one", event: second, externalUID: "fixture")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.additionalFeedIDs, ["google:one"])
        XCTAssertTrue(first.occurs(on: first.displayBounds(calendar: viewer).start, calendar: viewer))
    }
    func testPKCEUsesRFC7636VectorAndRandomState() throws {
        XCTAssertEqual(CalendarPKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try CalendarPKCE.random(), second = try CalendarPKCE.random()
        XCTAssertEqual(first.count, 43); XCTAssertNotEqual(first, second)
        for provider in [CalendarProvider.google, .microsoft, .zoom] {
            let url = try CalendarPKCE.authorizationURL(provider: provider, clientID: "test-client", redirect: "http://127.0.0.1:3456/callback", state: first, verifier: second)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "state" }?.value, first)
            XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
            if provider == .google {
                let scopes = Set((items.first { $0.name == "scope" }?.value ?? "").split(separator: " ").map(String.init))
                XCTAssertEqual(scopes, ["https://www.googleapis.com/auth/calendar.calendarlist.readonly",
                                        "https://www.googleapis.com/auth/calendar.events.readonly"])
            }
            XCTAssertFalse(url.absoluteString.contains("client_secret"))
        }
    }

    func testCallbackRejectsWrongStatePathDuplicatesAndDenial() throws {
        XCTAssertEqual(try CalendarPKCE.callback("/callback?state=expected&code=abc", expectedState: "expected"), "abc")
        for target in ["/callback?state=wrong&code=abc", "/other?state=expected&code=abc",
                       "/callback?state=expected&state=expected&code=abc", "/callback?state=expected&code=a&code=b",
                       "/callback?state=expected&error=access_denied"] {
            XCTAssertThrowsError(try CalendarPKCE.callback(target, expectedState: "expected"))
        }
    }

    func testFormEncodingPreservesSpecialCharacters() {
        let data = CalendarHTTP.form(["refresh_token": "a+b&c=d% ?"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "refresh_token=a%2Bb%26c%3Dd%25%20%3F")
    }

    func testGoogleAndZoomMapAllDayAndConferenceLinks() throws {
        for provider in [CalendarProvider.google, .zoom] {
            let feed = CalendarFeed(id: "feed", remoteID: "id", title: "Work", provider: provider)
            let row: [String: Any] = ["id": "event", "summary": "Day off", "start": ["date": "2026-10-19"],
                "end": ["date": "2026-10-20"], "description": "Join https://company.zoom.us/j/123"]
            let item = try XCTUnwrap(CalendarRemoteClient.event(row, feed: feed))
            XCTAssertTrue(item.event.allDay)
            XCTAssertEqual(item.event.meetingURL?.host, "company.zoom.us")
            XCTAssertFalse(item.event.occurs(on: item.event.end))
        }
    }

    func testMicrosoftUTCAndTeamsLinkArePreserved() throws {
        let feed = CalendarFeed(id: "feed", remoteID: "id", title: "Work", provider: .microsoft)
        let row: [String: Any] = ["id": "event", "subject": "Stand-up", "start": ["dateTime": "2026-10-19T09:00:00.0000000", "timeZone": "UTC"],
            "end": ["dateTime": "2026-10-19T09:30:00.0000000", "timeZone": "UTC"],
            "onlineMeeting": ["joinUrl": "https://teams.microsoft.com/l/meetup-join/test"]]
        let item = try XCTUnwrap(CalendarRemoteClient.event(row, feed: feed))
        XCTAssertEqual(item.event.start, CalendarDateCodec.parse("2026-10-19T09:00:00Z"))
        XCTAssertEqual(item.event.end.timeIntervalSince(item.event.start), 1800)
        XCTAssertEqual(item.event.meetingURL?.host, "teams.microsoft.com")
    }

    func testCancelledEventsAndUnsafeLinksAreExcluded() throws {
        let feed = CalendarFeed(id: "feed", remoteID: "id", title: "Work", provider: .google)
        XCTAssertNil(try CalendarRemoteClient.event(["status": "cancelled"], feed: feed))
        XCTAssertThrowsError(try CalendarRemoteClient.event(["id": "broken"], feed: feed))
        XCTAssertNil(CalendarDateCodec.safeURL("javascript:alert(1)"))
        XCTAssertNil(CalendarDateCodec.safeURL("https://user:password@example.com"))
        XCTAssertNil(CalendarDateCodec.meetingURL(in: "https://zoom.us.evil.example/j/1"))
        XCTAssertNil(CalendarDateCodec.meetingURL(in: "http://teams.microsoft.com/x"))
    }

    func testSameMeetingAcrossAccountsIsMergedOnlyWithMatchingUIDAndTimes() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let event = PlannerEvent(title: "Review", start: start, end: start.addingTimeInterval(1800))
        let apple = CalendarFeedEvent(id: "apple:1", feedID: "apple", event: event, externalUID: "same-uid")
        var google = CalendarFeedEvent(id: "google:1", feedID: "google", event: event,
            sourceURL: URL(string: "https://calendar.google.com/calendar/event?eid=fixture"), externalUID: "same-uid")
        google.event.meetingURL = URL(string: "https://meet.google.com/fixture")
        let merged = CalendarEventMerger.merge([apple, google])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].additionalFeedIDs, ["google"])
        XCTAssertNotNil(merged[0].event.meetingURL)
        google.externalUID = "different-uid"
        XCTAssertEqual(CalendarEventMerger.merge([apple, google]).count, 2)
        google.externalUID = "same-uid"; google.event.end = event.end.addingTimeInterval(3600)
        XCTAssertEqual(CalendarEventMerger.merge([apple, google]).count, 2)
    }

    func testAllDayCivilDateSurvivesTravelAndMonthCounts() throws {
        var origin = Calendar(identifier: .gregorian)
        origin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
        let start = try XCTUnwrap(origin.date(from: DateComponents(year: 2026, month: 10, day: 19)))
        var event = PlannerEvent(title: "Day off", start: start, end: origin.date(byAdding: .day, value: 1, to: start)!, allDay: true)
        event.timeZoneIdentifier = origin.timeZone.identifier
        var destination = origin
        destination.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let localDay = try XCTUnwrap(destination.date(from: DateComponents(year: 2026, month: 10, day: 19)))
        XCTAssertTrue(event.occurs(on: localDay, calendar: destination))
        XCTAssertFalse(event.occurs(on: localDay.addingTimeInterval(-86400), calendar: destination))
        let counts = PlannerMonth.counts(events: [CalendarFeedEvent(id: "one", feedID: "local", event: event)],
            days: [localDay, destination.date(byAdding: .day, value: 1, to: localDay)!], calendar: destination)
        XCTAssertEqual(counts[localDay], 1)
        XCTAssertEqual(counts.count, 1)
    }
}
