import AppKit
import EventKit
import XCTest
@testable import Sidekey

/// Calendar connects only through the calendars of this Mac (2026-11-23): one
/// permission, accounts from Internet Accounts, a tick per calendar. Accounts
/// an earlier build connected directly keep working. Calendar on this Mac is a
/// fake: no test asks macOS or reads real calendars.
// WHY: .project-docs/decisions/2026-11-23-calendar-macos-only.md
@MainActor
final class CalendarMacOnlyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var directory: URL!
    private var day: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 24))! }

    private final class FakeMac {
        var status: EKAuthorizationStatus = .notDetermined
        var answer: EKAuthorizationStatus = .fullAccess
        var prompts = 0
        var feeds: [CalendarFeed] = []
        var events: [CalendarFeedEvent] = []
        var access: AppleCalendarAccess {
            AppleCalendarAccess(
                status: { self.status },
                request: {
                    if self.status == .notDetermined { self.prompts += 1; self.status = self.answer }
                    return self.status == .fullAccess
                },
                read: { _ in (self.feeds, self.events) })
        }
    }

    override func setUp() async throws {
        suite = "calendar.mac-only." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-mac-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        PlannerURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func connections(_ mac: FakeMac, oauth: CalendarOAuthClient? = nil, http: CalendarHTTP? = nil) -> CalendarConnections {
        CalendarConnections(defaults: defaults, oauth: oauth ?? CalendarOAuthClient(storage: PlannerMemoryCredentials()),
                            http: http ?? CalendarHTTP(), apple: mac.access)
    }

    private func model(_ connections: CalendarConnections) -> CalendarHoverModel {
        CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")),
            connections: connections, now: { self.day.addingTimeInterval(9 * 3600) },
            connectionFlow: CalendarConnectionFlow(connections: connections, googleReview: { false }))
    }

    private func finish(_ flow: CalendarConnectionFlow) async throws {
        for _ in 0..<200 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(flow.working)
    }

    private func feed(_ id: String, account: String, name: String, service: CalendarProvider? = nil,
                      sourceID: String? = nil) -> CalendarFeed {
        CalendarFeed(id: "apple:\(id)", accountID: nil, remoteID: id, title: "\(name) · \(account)", provider: .apple,
                     displayService: service, sourceTitle: account, calendarTitle: name, sourceID: sourceID)
    }

    private func event(_ title: String, feed: String, hour: Int, notes: String = "", uid: String? = nil) -> CalendarFeedEvent {
        let start = day.addingTimeInterval(TimeInterval(hour * 3600))
        return CalendarFeedEvent(id: "\(feed):\(title)", feedID: feed,
            event: PlannerEvent(title: title, start: start, end: start.addingTimeInterval(1800), notes: notes,
                                meetingURL: CalendarDateCodec.meetingURL(in: notes)),
            sourceURL: nil, externalUID: uid)
    }

    // MARK: - The four states

    func testStatesFromNotAskedToCalendars() async throws {
        let mac = FakeMac()
        let connections = connections(mac)
        XCTAssertEqual(connections.macAccess, .notAsked)

        try await connections.enableApple()
        XCTAssertEqual(mac.prompts, 1)
        XCTAssertEqual(connections.macAccess, .loading, "connected, nothing read yet")

        let interval = DateInterval(start: day, duration: 86_400)
        connections.refreshAppleIfEnabled(interval: interval)
        XCTAssertEqual(connections.macAccess, .noCalendars)

        mac.feeds = [feed("home", account: "iCloud", name: "Home")]
        connections.refreshAppleIfEnabled(interval: interval)
        XCTAssertEqual(connections.macAccess, .ready)

        mac.status = .denied
        connections.refreshAppleIfEnabled(interval: interval)
        XCTAssertEqual(connections.macAccess, .refused)
        XCTAssertEqual(connections.macAccessOffMessage, CalendarConnectionError.appleAccessOffMessage,
                       "a saved connection recovers on its own")
    }

    func testARefusedConnectAsksForConnectAgain() async {
        let mac = FakeMac(); mac.answer = .denied
        let connections = connections(mac)
        do { try await connections.enableApple(); XCTFail("refused") } catch {}
        XCTAssertEqual(connections.macAccess, .refused)
        XCTAssertEqual(connections.macAccessOffMessage, CalendarConnectionError.appleConnectRefusedMessage)
        mac.status = .fullAccess
        connections.checkAppleAccess()
        XCTAssertEqual(connections.macAccess, .notAsked, "allowed in System Settings: the one Allow button is back")
    }

    func testAllowingAccessFromTheCalendarsPageNeedsOneTap() async throws {
        let mac = FakeMac()
        mac.feeds = [feed("work", account: "max@gmail.com", name: "Work", service: .google)]
        let connections = connections(mac)
        let model = model(connections)
        model.begin()
        model.page = .providers
        XCTAssertTrue(model.connect(.apple, info: nil))
        try await finish(model.connectionFlow)
        XCTAssertEqual(mac.prompts, 1)
        XCTAssertTrue(connections.appleEnabled)
        XCTAssertEqual(model.page, .agenda, "after Allow the day is shown")
    }

    // MARK: - Calendars by account, with ticks

    func testCalendarsAreGroupedByAccountWithTheirService() {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [feed("w", account: "max@gmail.com", name: "Work", service: .google),
                     feed("h", account: "iCloud", name: "Home"),
                     feed("a", account: "iCloud", name: "Anniversaries"),
                     feed("x", account: "Exchange", name: "Calendar", service: .microsoft),
                     feed("p", account: "max@gmail.com", name: "Holidays", service: .google)]
        let connections = connections(mac)
        connections.refreshAppleIfEnabled(interval: DateInterval(start: day, duration: 86_400))
        let groups = connections.macCalendarGroups
        XCTAssertEqual(groups.map(\.title), ["Exchange", "iCloud", "max@gmail.com"])
        XCTAssertEqual(groups.map(\.service), [.microsoft, nil, .google])
        XCTAssertEqual(groups[1].feeds.compactMap(\.calendarTitle), ["Anniversaries", "Home"])
        XCTAssertEqual(groups[2].feeds.compactMap(\.calendarTitle), ["Holidays", "Work"])
    }

    func testUntickedCalendarsLeaveTheDayAndTheChoiceIsSaved() async {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [feed("work", account: "max@gmail.com", name: "Work", service: .google),
                     feed("holidays", account: "max@gmail.com", name: "Holidays", service: .google),
                     feed("shared", account: "iCloud", name: "Shared")]
        mac.events = [event("Standup", feed: "apple:work", hour: 10),
                      event("Day off", feed: "apple:holidays", hour: 12),
                      // One invitation in two calendars: shown while either is ticked.
                      event("Review", feed: "apple:holidays", hour: 14, uid: "same"),
                      event("Review", feed: "apple:shared", hour: 14, uid: "same")]
        let connections = connections(mac)
        let model = model(connections)
        model.begin()
        await connections.refresh(interval: model.interval)
        XCTAssertTrue(model.store.saveEvent(PlannerEvent(title: "Whytap note", start: day.addingTimeInterval(8 * 3600),
                                                         end: day.addingTimeInterval(8.5 * 3600))))
        XCTAssertEqual(model.events.map(\.event.title), ["Whytap note", "Standup", "Day off", "Review"])

        connections.setVisible(false, feedID: "apple:holidays")
        XCTAssertEqual(model.events.map(\.event.title), ["Whytap note", "Standup", "Review"])
        connections.setVisible(false, feedID: "apple:shared")
        XCTAssertEqual(model.events.map(\.event.title), ["Whytap note", "Standup"])
        connections.setVisible(false, feedID: "local")
        XCTAssertTrue(model.events.contains { $0.event.title == "Whytap note" }, "Whytap's own events have no tick")

        let reopened = self.connections(mac)
        XCTAssertFalse(reopened.isShown(feedID: "apple:holidays"), "the choice survives a restart")
        XCTAssertTrue(reopened.isShown(feedID: "apple:work"))
    }

    func testCallLinksFromGoogleAndTeamsDescriptionsStillJoin() {
        let google = "Join with Google Meet: https://meet.google.com/abc-defg-hij\nOr dial: +1 555 0100"
        let teams = "Microsoft Teams meeting\nJoin on your computer\nClick here to join the meeting<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0>"
        let zoom = "Location: https://acme.zoom.us/j/1234567890?pwd=abc"
        XCTAssertEqual(CalendarDateCodec.meetingURL(in: google)?.host, "meet.google.com")
        XCTAssertEqual(CalendarDateCodec.meetingURL(in: teams)?.host, "teams.microsoft.com")
        XCTAssertEqual(CalendarDateCodec.meetingURL(in: zoom)?.host, "acme.zoom.us")
        XCTAssertNil(CalendarDateCodec.meetingURL(in: "Lunch at https://example.com/menu"))
    }

    // MARK: - Accounts connected directly by an earlier build

    func testADirectConnectionKeepsWorkingAndIsNeverHidden() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerURLProtocol.self]
        let http = CalendarHTTP(session: URLSession(configuration: configuration))
        let storage = PlannerMemoryCredentials()
        let oauth = CalendarOAuthClient(http: http, storage: storage)
        let account = ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Work")
        defaults.set(try JSONEncoder().encode([account]), forKey: CalendarAccountSettings.accountsKey)
        try storage.save(CalendarCredential(provider: .microsoft, clientID: "fixture-client", accessToken: "fixture-access",
            refreshToken: "fixture-refresh", expiresAt: .distantFuture), id: account.id)
        var requests = 0
        PlannerURLProtocol.handler = { _ in requests += 1; return (200, ["value": []]) }
        let connections = connections(FakeMac(), oauth: oauth, http: http)
        XCTAssertEqual(connections.accounts, [account], "the direct account is kept")
        XCTAssertEqual(connections.macAccess, .notAsked, "and Calendar on this Mac is offered next to it")
        await connections.refresh(interval: DateInterval(start: day, duration: 86_400))
        XCTAssertGreaterThan(requests, 0, "it is still read")
        XCTAssertNil(connections.errors[account.id.uuidString])
        let directFeed = account.id.uuidString + ":calendar"
        connections.setVisible(false, feedID: directFeed)
        XCTAssertTrue(connections.isShown(feedID: directFeed), "only calendars of this Mac have ticks")
    }

    func testAnExpiredDirectSignInPointsToInternetAccounts() {
        let message = CalendarConnectionError.signInRequired.errorDescription ?? ""
        XCTAssertTrue(message.contains("Internet Accounts"))
        XCTAssertFalse(message.contains("Connect account"), "the old Connect account path is not offered any more")
    }

    // MARK: - Builder review of queue #465

    /// 1. Settings reads the list itself: relaunch, Allow in Settings, recovery in System Settings.
    func testSettingsReadsAlreadyEnabledCalendarsWithoutOpeningHover() {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [feed("work", account: "Exchange", name: "Work", service: .microsoft)]
        let connections = connections(mac)
        let settings = SettingsCalendarIntegrationsView(connections: connections)
        settings.recheckAppleAccess()
        XCTAssertEqual(connections.macAccess, .ready, "opening Settings on a fresh process populates calendars")
        XCTAssertEqual(connections.macCalendarGroups.first?.feeds.first?.id, "apple:work")
        XCTAssertEqual(mac.prompts, 0)
    }

    func testAllowInSettingsLoadsTheListWithoutHover() async throws {
        let mac = FakeMac()
        mac.feeds = [feed("home", account: "iCloud", name: "Home")]
        let connections = connections(mac)
        let flow = CalendarConnectionFlow(connections: connections)
        XCTAssertTrue(flow.startRegistered(provider: .apple, info: nil) { connections.prepareMacCalendars() })
        try await finish(flow)
        XCTAssertEqual(mac.prompts, 1)
        XCTAssertEqual(connections.macAccess, .ready)
    }

    func testRecoveryInSystemSettingsReloadsTheListFromSettings() {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .denied
        mac.feeds = [feed("home", account: "iCloud", name: "Home")]
        let connections = connections(mac)
        connections.prepareMacCalendars()
        XCTAssertEqual(connections.macAccess, .refused)
        XCTAssertTrue(connections.feeds.isEmpty, "nothing is read while access is off")
        mac.status = .fullAccess
        connections.prepareMacCalendars()
        XCTAssertEqual(connections.macAccess, .ready)
        XCTAssertEqual(connections.macCalendarGroups.map(\.title), ["iCloud"])
    }

    func testSettingsNeverReadsAnUnconnectedMac() {
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [feed("home", account: "iCloud", name: "Home")]
        let connections = connections(mac)
        connections.prepareMacCalendars()
        XCTAssertEqual(connections.macAccess, .notAsked)
        XCTAssertTrue(connections.feeds.isEmpty)
    }

    /// 2. An account is its EventKit source, not its title.
    func testAccountsWithTheSameTitleStaySeparate() {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [feed("office", account: "Work", name: "Calendar", service: .microsoft, sourceID: "src-exchange"),
                     feed("cloud", account: "Work", name: "Calendar", sourceID: "src-icloud"),
                     feed("cloud2", account: "Work", name: "Birthdays", sourceID: "src-icloud-2")]
        let connections = connections(mac)
        connections.refreshAppleIfEnabled(interval: DateInterval(start: day, duration: 86_400))
        let groups = connections.macCalendarGroups
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(Set(groups.map(\.id)).count, 3)
        XCTAssertEqual(Set(groups.map(\.title)).count, 3, "repeated names are told apart: \(groups.map(\.title))")
        XCTAssertTrue(groups.contains { $0.title == "Work · Exchange" && $0.service == .microsoft })
        XCTAssertEqual(groups.first { $0.id == "src-exchange" }?.feeds.map(\.id), ["apple:office"])
    }

    func testAccountsWithTheSameTitleAndNoSourceIDSplitByService() {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [feed("office", account: "Work", name: "Calendar", service: .microsoft),
                     feed("local", account: "Work", name: "Calendar", service: .apple)]
        let connections = connections(mac)
        connections.refreshAppleIfEnabled(interval: DateInterval(start: day, duration: 86_400))
        XCTAssertEqual(connections.macCalendarGroups.count, 2)
    }

    /// 3. A saved connection with access off keeps Disconnect next to Open Privacy Settings.
    func testSettingsKeepsDisconnectWhileAccessIsOff() {
        typealias View = SettingsCalendarIntegrationsView
        XCTAssertEqual(View.macActions(access: .refused, connected: true, working: false), [.disconnect, .openPrivacySettings])
        XCTAssertEqual(View.macActions(access: .refused, connected: false, working: false), [.openPrivacySettings])
        XCTAssertEqual(View.macActions(access: .notAsked, connected: false, working: false), [.allowAccess])
        XCTAssertEqual(View.macActions(access: .ready, connected: true, working: false), [.disconnect])
        XCTAssertEqual(View.macActions(access: .noCalendars, connected: true, working: false), [.disconnect])
        XCTAssertEqual(View.macActions(access: .notAsked, connected: false, working: true), [.cancel])
    }

    func testDisconnectingARevokedConnectionClearsIt() {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .denied
        let connections = connections(mac)
        connections.prepareMacCalendars()
        XCTAssertEqual(connections.macAccess, .refused)
        connections.disableApple()
        XCTAssertEqual(connections.macAccess, .notAsked)
        XCTAssertFalse(defaults.bool(forKey: CalendarAccountSettings.appleEnabledKey))
    }

    /// 4. Inactive entries of direct connections never use up the ticks of this Mac.
    func testOldDirectVisibilityPreferencesDoNotBlockLocalCalendarTicks() {
        let legacyAccount = UUID().uuidString
        defaults.set((0..<CalendarAccountSettings.maximumHiddenFeeds).map { "\(legacyAccount):calendar-\($0)" },
                     forKey: CalendarAccountSettings.hiddenFeedsKey)
        let connections = connections(FakeMac())
        connections.setVisible(false, feedID: "apple:work")
        XCTAssertFalse(connections.isShown(feedID: "apple:work"))
        XCTAssertNil(connections.errors["visibility"])
        let saved = defaults.stringArray(forKey: CalendarAccountSettings.hiddenFeedsKey) ?? []
        XCTAssertLessThanOrEqual(saved.count, CalendarAccountSettings.maximumHiddenFeeds, "backup and sync keep their bound")
        XCTAssertTrue(saved.contains("apple:work"))
        XCTAssertEqual(saved.filter { $0.hasPrefix(legacyAccount) }.count, CalendarAccountSettings.maximumHiddenFeeds - 1,
                       "only as many inactive entries as needed make room")
    }

    func testTheLimitStillHoldsForCalendarsOfThisMac() {
        defaults.set((0..<CalendarAccountSettings.maximumHiddenFeeds).map { "apple:cal-\($0)" },
                     forKey: CalendarAccountSettings.hiddenFeedsKey)
        let connections = connections(FakeMac())
        connections.setVisible(false, feedID: "apple:one-more")
        XCTAssertTrue(connections.isShown(feedID: "apple:one-more"))
        XCTAssertNotNil(connections.errors["visibility"])
    }

    /// 5. The recovery text names the button each surface shows.
    func testRecoveryTextNamesTheButtonOnBothSurfaces() {
        let message = CalendarConnectionError.appleConnectRefusedMessage
        XCTAssertTrue(message.contains(CalendarConnectionError.allowAccessTitle))
        XCTAssertFalse(message.contains("Connect"), "no button called Connect asks macOS any more")
        XCTAssertEqual(CalendarConnectionError.allowAccessTitle, "Allow access to calendars")
    }

    // MARK: - Builder review of queue #471

    /// Settings reads the calendar list only; the day open in Hover keeps its events.
    func testSettingsKeepsTheDayOpenInHover() async {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [feed("work", account: "iCloud", name: "Work", sourceID: "src")]
        let tomorrow = day.addingTimeInterval(86_400)
        mac.events = [CalendarFeedEvent(id: "apple:tomorrow", feedID: "apple:work",
            event: PlannerEvent(title: "Tomorrow's review", start: tomorrow.addingTimeInterval(10 * 3600),
                                end: tomorrow.addingTimeInterval(11 * 3600)), sourceURL: nil)]
        var listed = 0, readIntervals: [DateInterval] = []
        let access = AppleCalendarAccess(status: { mac.status }, request: { true },
            read: { interval in readIntervals.append(interval); return (mac.feeds, mac.events) },
            list: { listed += 1; return mac.feeds })
        let connections = CalendarConnections(defaults: defaults, oauth: CalendarOAuthClient(storage: PlannerMemoryCredentials()),
                                              apple: access)
        let model = model(connections)
        model.begin()
        model.moveDay(1)
        await connections.refresh(interval: model.interval)
        XCTAssertEqual(model.events.map(\.event.title), ["Tomorrow's review"])
        let reads = readIntervals.count

        // Settings opens (and Whytap becomes active again) while Hover shows tomorrow.
        mac.events = []   // today, as an event read for today would return
        connections.prepareMacCalendars()
        connections.prepareMacCalendars()
        XCTAssertEqual(listed, 2)
        XCTAssertEqual(readIntervals.count, reads, "Settings reads no events")
        XCTAssertEqual(model.events.map(\.event.title), ["Tomorrow's review"], "the selected day keeps its events")
        XCTAssertEqual(connections.macAccess, .ready)
    }

    func testARemovedCalendarTakesItsEventsWithIt() async {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [feed("work", account: "iCloud", name: "Work"), feed("old", account: "iCloud", name: "Old")]
        mac.events = [event("Kept", feed: "apple:work", hour: 9), event("Gone", feed: "apple:old", hour: 10)]
        let connections = connections(mac)
        let model = model(connections)
        model.begin()
        await connections.refresh(interval: model.interval)
        XCTAssertEqual(model.events.map(\.event.title), ["Kept", "Gone"])
        mac.feeds = [feed("work", account: "iCloud", name: "Work")]
        connections.prepareMacCalendars()
        XCTAssertEqual(model.events.map(\.event.title), ["Kept"])
        XCTAssertEqual(connections.macCalendarGroups.flatMap(\.feeds).map(\.id), ["apple:work"])
    }

    func testSettingsListBeforeAnyEventReadIsReady() {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        let connections = connections(mac)
        XCTAssertEqual(connections.macAccess, .loading)
        connections.prepareMacCalendars()
        XCTAssertEqual(connections.macAccess, .noCalendars, "an empty Mac is reported, not left loading")
        mac.feeds = [feed("home", account: "iCloud", name: "Home")]
        connections.prepareMacCalendars()
        XCTAssertEqual(connections.macAccess, .ready)
    }
}
