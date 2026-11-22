import AppKit
import EventKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Calendar as released on 2026-11-22, with the real default (no override):
/// a user opens it from the tile, search, hotkey or a link, connects Calendar on
/// this Mac and macOS grants, refuses or later revokes access. Calendar on this
/// Mac is a fake, so no test asks macOS or reads the user's real calendars.
// WHY: .project-docs/decisions/2026-11-22-calendar-release.md
@MainActor
final class CalendarReleaseTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var directory: URL!
    private var day: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 23))! }

    /// What macOS would answer, and what the user's calendars hold.
    private final class FakeMac {
        var status: EKAuthorizationStatus = .notDetermined
        /// What the prompt answers when the user is asked.
        var answer: EKAuthorizationStatus = .fullAccess
        var prompts = 0
        var statusReads = 0
        var reads = 0
        var feeds: [CalendarFeed] = []
        var events: [CalendarFeedEvent] = []

        var access: AppleCalendarAccess {
            AppleCalendarAccess(
                status: { self.statusReads += 1; return self.status },
                request: {
                    // Like macOS: a prompt only while undecided, afterwards the saved answer.
                    if self.status == .notDetermined { self.prompts += 1; self.status = self.answer }
                    return self.status == .fullAccess
                },
                read: { _ in self.reads += 1; return (self.feeds, self.events) })
        }
    }

    override func setUp() async throws {
        XCTAssertNil(CalendarAvailability.testOverride, "another test leaked the Calendar override")
        suite = "calendar.release." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func connections(_ mac: FakeMac) -> CalendarConnections {
        CalendarConnections(defaults: defaults, oauth: CalendarOAuthClient(storage: PlannerMemoryCredentials()), apple: mac.access)
    }

    private func model(_ connections: CalendarConnections) -> CalendarHoverModel {
        CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")),
            connections: connections, now: { self.day.addingTimeInterval(9 * 3600) },
            connectionFlow: CalendarConnectionFlow(connections: connections, googleReview: { false }))
    }

    private func finish(_ flow: CalendarConnectionFlow) async throws {
        for _ in 0..<200 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(flow.working, "the connection did not finish")
    }

    private func appleEvent(_ title: String, hour: Int, feed: String = "apple:work", notes: String = "",
                            location: String = "", identifier: String? = nil) -> CalendarFeedEvent {
        let start = day.addingTimeInterval(TimeInterval(hour * 3600))
        let text = [location, notes].joined(separator: " ")
        return CalendarFeedEvent(id: "apple:\(title)", feedID: feed,
            event: PlannerEvent(title: title, start: start, end: start.addingTimeInterval(1800), location: location, notes: notes,
                meetingURL: CalendarDateCodec.meetingURL(in: text)),
            sourceURL: CalendarEventAction.appleEventURL(identifier: identifier ?? title))
    }

    // MARK: - Released: no Soon anywhere

    func testCalendarShipsOpenWithoutASoonBadge() {
        XCTAssertTrue(CalendarAvailability.shipped)
        XCTAssertTrue(CalendarAvailability.isOpen)
        XCTAssertNil(CalendarAvailability.blockReason)
        XCTAssertTrue(HoverTool.allCases.filter(\.isComingSoon).isEmpty)
        XCTAssertNil(HoverTool.calendar.comingSoonBadge)
    }

    func testTheTileOpensTheCalendarPanel() {
        XCTAssertEqual(HoverSlotRouter.effect(for: .calendar), .openPanel(.calendar))
        XCTAssertTrue(HoverSlotRouter.effect(for: .calendar).requiresExpansion)
        var active: [Bool] = []
        let model = CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")),
            connections: connections(FakeMac()), activityChanged: { active.append($0) })
        model.begin()
        XCTAssertTrue(model.visible)
        XCTAssertEqual(model.page, .agenda)
        XCTAssertTrue(model.isToday)
        model.end()
        XCTAssertEqual(active, [true, false])
    }

    func testSearchFindsCalendarWithItsOwnDescription() {
        XCTAssertTrue(IslandHoverToolSearch.results(for: "calendar").contains(.calendar))
        XCTAssertTrue(IslandHoverToolSearch.results(for: "календарь").contains(.calendar))
        let description = HoverToolRegistry.description(for: .calendar, mode: .fast, inputLanguage: nil, outputLanguage: nil)
        XCTAssertEqual(description, HoverToolRegistry.info(for: .calendar).description)
        XCTAssertNotEqual(description, CalendarAvailability.message)
    }

    func testASavedHotkeyCapturesItsKeyAgainAndAppearsInHelp() {
        let shortcut = HotkeyShortcut.combo(.optionD)
        XCTAssertEqual(ToolHotkeyBinding.resolve([.calendar: shortcut]).map(\.tool), [.calendar])
        XCTAssertTrue(WhytapLink.acceptsLinkHotkey(.calendar))
        var configuration = HotkeyConfiguration.defaults
        configuration.toolShortcuts[.calendar] = shortcut
        XCTAssertTrue(HelpWindowContent.hotkeyRows(for: configuration, includeAgent: false)
            .contains { $0.title == "Tool — Calendar" })
    }

    func testLinksOpenThePanelAndMayProposeAHotkey() throws {
        XCTAssertEqual(WhytapLink.destination(for: .calendar), .hoverPanel(.calendar))
        let url = try XCTUnwrap(URL(string: "whytap://hotkey/calendar?keys=ctrl+option+c"))
        guard case .propose? = WhytapLink.request(for: url) else { return XCTFail("an open Calendar takes a hotkey link") }
    }

    // MARK: - Saved data comes back

    func testConnectionsSavedWhileSoonWorkAgainUnchanged() async throws {
        let account = ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Work")
        let stored = try JSONEncoder().encode([account])
        defaults.set(stored, forKey: CalendarAccountSettings.accountsKey)
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        defaults.set(["apple:private"], forKey: "planner.calendar.hiddenFeeds")
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [CalendarFeed(id: "apple:private", accountID: nil, remoteID: "private", title: "Private · iCloud", provider: .apple)]
        let connections = connections(mac)
        XCTAssertNil(connections.connectionBlockReason)
        XCTAssertEqual(connections.accounts, [account])
        XCTAssertTrue(connections.appleEnabled)
        XCTAssertEqual(connections.hiddenFeeds, ["apple:private"])
        connections.refreshAppleIfEnabled(interval: DateInterval(start: day, duration: 86_400))
        XCTAssertEqual(mac.prompts, 0, "a saved Apple connection is not asked again")
        XCTAssertEqual(mac.reads, 1)
        XCTAssertEqual(connections.hiddenFeeds, ["apple:private"], "a still existing hidden calendar stays hidden")
        XCTAssertEqual(defaults.data(forKey: CalendarAccountSettings.accountsKey), stored)
    }

    // MARK: - Access to Calendar on this Mac

    func testNothingAsksMacOSUntilTheUserPressesConnect() async {
        let mac = FakeMac()
        let connections = connections(mac)
        let model = model(connections)
        model.begin()
        await connections.refresh(interval: model.interval)
        connections.refreshAppleIfEnabled(interval: model.interval)
        XCTAssertEqual(mac.prompts, 0)
        XCTAssertEqual(mac.statusReads, 0, "Apple Calendar not connected: EventKit is not touched at all")
        XCTAssertEqual(mac.reads, 0)
        XCTAssertTrue(connections.errors.isEmpty)
    }

    func testGrantedAccessConnectsAndShowsTheDay() async throws {
        let mac = FakeMac()
        mac.feeds = [CalendarFeed(id: "apple:work", accountID: nil, remoteID: "work", title: "Work · Google", provider: .apple,
                                  displayService: .google)]
        mac.events = [appleEvent("Standup", hour: 10)]
        let connections = connections(mac)
        let model = model(connections)
        model.begin()
        XCTAssertTrue(model.connect(.apple, info: nil))
        try await finish(model.connectionFlow)
        XCTAssertEqual(mac.prompts, 1, "one macOS prompt, after Connect")
        XCTAssertNil(model.connectionFlow.error)
        XCTAssertTrue(connections.appleEnabled)
        XCTAssertFalse(connections.appleAccessOff)
        XCTAssertTrue(defaults.bool(forKey: CalendarAccountSettings.appleEnabledKey))
        XCTAssertEqual(model.page, .agenda)
        XCTAssertEqual(model.connectState(.apple), .connected)
        await connections.refresh(interval: model.interval)
        XCTAssertEqual(model.events.map(\.event.title), ["Standup"])
        XCTAssertEqual(model.source("apple:work"), .provider(.google), "a Google calendar synced on this Mac shows Google's logo")
        XCTAssertNotNil(connections.lastSynced["apple"])
    }

    func testRefusedAccessSaysWhereToAllowItAndStoresNothing() async throws {
        let mac = FakeMac(); mac.answer = .denied
        let connections = connections(mac)
        let model = model(connections)
        model.begin()
        XCTAssertTrue(model.connect(.apple, info: nil))
        try await finish(model.connectionFlow)
        XCTAssertEqual(mac.prompts, 1)
        XCTAssertEqual(model.connectionFlow.error, CalendarConnectionError.appleConnectRefusedMessage)
        XCTAssertTrue(model.connectionFlow.error?.contains("System Settings → Privacy & Security → Calendars") == true)
        XCTAssertTrue(model.connectionFlow.error?.contains("then press Connect again") == true,
                      "nothing was connected, so the step after System Settings is named")
        XCTAssertTrue(connections.appleAccessOff, "Settings and the Connect page offer Open Privacy Settings")
        XCTAssertFalse(connections.appleEnabled)
        XCTAssertNil(defaults.object(forKey: CalendarAccountSettings.appleEnabledKey))
        XCTAssertEqual(model.page, .providers, "the message stays next to the Apple row")
        XCTAssertEqual(model.connectState(.apple), .connect)
        XCTAssertFalse(connections.isConnecting)

        // Connect again: macOS remembers the refusal, so there is no second prompt, only the same advice.
        XCTAssertTrue(model.connect(.apple, info: nil))
        try await finish(model.connectionFlow)
        XCTAssertEqual(mac.prompts, 1)
        XCTAssertEqual(model.connectionFlow.error, CalendarConnectionError.appleConnectRefusedMessage)

        // Reopening Calendar while access is still off keeps the advice.
        model.end(); model.begin()
        XCTAssertTrue(connections.appleAccessOff)
        XCTAssertEqual(model.connectionFlow.error, CalendarConnectionError.appleConnectRefusedMessage)
    }

    func testAllowingAccessAfterARefusalClearsTheWarningAndConnectNeedsNoPrompt() async throws {
        let mac = FakeMac(); mac.answer = .denied
        mac.feeds = [CalendarFeed(id: "apple:work", accountID: nil, remoteID: "work", title: "Work · iCloud", provider: .apple)]
        mac.events = [appleEvent("Planning", hour: 15)]
        let connections = connections(mac)
        let model = model(connections)
        model.begin()
        XCTAssertTrue(model.connect(.apple, info: nil))
        try await finish(model.connectionFlow)
        XCTAssertTrue(connections.appleAccessOff)

        // In System Settings the user turns Whytap on, then reopens Calendar.
        mac.status = .fullAccess
        model.end(); model.begin()
        XCTAssertFalse(connections.appleAccessOff, "the live status replaces the stale refusal")
        XCTAssertFalse(connections.appleConnectRefused)
        XCTAssertNil(model.connectionFlow.error, "no stale denial under the Apple row")
        XCTAssertNil(connections.errors["apple"])
        XCTAssertEqual(model.connectState(.apple), .connect, "the refusal saved nothing; Connect is the explicit next step")
        XCTAssertEqual(mac.reads, 0, "checking access never reads events of an unconnected calendar")

        XCTAssertTrue(model.connect(.apple, info: nil))
        try await finish(model.connectionFlow)
        XCTAssertEqual(mac.prompts, 1, "macOS already allows it: no second prompt")
        XCTAssertTrue(connections.appleEnabled)
        XCTAssertEqual(model.page, .agenda)
        await connections.refresh(interval: model.interval)
        XCTAssertEqual(model.events.map(\.event.title), ["Planning"])
    }

    func testAddEventsOnlyCannotReadAndGetsTheSameAdvice() async throws {
        let mac = FakeMac(); mac.status = .writeOnly
        let connections = connections(mac)
        do { try await connections.enableApple(); XCTFail("write-only access cannot show events") }
        catch CalendarConnectionError.appleConnectRefused { }
        XCTAssertTrue(connections.appleAccessOff)
        XCTAssertFalse(connections.appleEnabled)
    }

    func testRevokedAccessClearsEventsAndRecoversWhenAllowedAgain() async throws {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [CalendarFeed(id: "apple:work", accountID: nil, remoteID: "work", title: "Work · iCloud", provider: .apple)]
        mac.events = [appleEvent("Review", hour: 14)]
        let connections = connections(mac)
        let model = model(connections)
        var privacyOpened = 0
        model.openPrivacySettings = { privacyOpened += 1 }
        model.begin()
        await connections.refresh(interval: model.interval)
        XCTAssertEqual(model.events.map(\.event.title), ["Review"])
        XCTAssertEqual(model.connectState(.apple), .connected)

        mac.status = .denied   // the user turns Whytap off in System Settings
        model.end(); model.begin()
        XCTAssertEqual(mac.prompts, 0, "a revoked access is reported, never re-prompted")
        XCTAssertTrue(model.events.isEmpty, "no stale events stay on screen")
        XCTAssertTrue(connections.feeds.isEmpty)
        XCTAssertEqual(connections.errors["apple"], CalendarConnectionError.appleAccessOffMessage)
        XCTAssertTrue(connections.appleAccessOff)
        XCTAssertTrue(connections.appleEnabled, "the connection is kept, so allowing access again is enough")

        // The Apple row no longer claims Connected, and pressing it leads to System Settings.
        model.page = .providers
        XCTAssertEqual(model.connectState(.apple), .accessOff)
        XCTAssertEqual(model.connectAccessibilityLabel(.apple), "Apple Calendar, access off. Open Privacy Settings")
        XCTAssertFalse(model.connect(.apple, info: nil))
        XCTAssertEqual(privacyOpened, 1)
        XCTAssertEqual(model.page, .providers, "the user is not sent back to an empty day")
        XCTAssertFalse(model.connectionFlow.working)

        mac.status = .fullAccess   // allowed again, then Whytap becomes active
        model.recheckAppleAccess()
        XCTAssertNil(connections.errors["apple"])
        XCTAssertFalse(connections.appleAccessOff)
        XCTAssertEqual(model.connectState(.apple), .connected)
        await connections.refresh(interval: model.interval)
        XCTAssertEqual(model.events.map(\.event.title), ["Review"])
    }

    // MARK: - Settings alone, Calendar never opened

    private func renderSettings(_ connections: CalendarConnections) async throws {
        let host = NSHostingView(rootView: SettingsCalendarIntegrationsView(connections: connections).frame(width: 520))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 520, height: 900),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50))
    }

    func testSettingsAloneShowsARevokedAccessFromTheLiveStatus() async throws {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .denied
        let connections = connections(mac)
        XCTAssertFalse(connections.appleAccessOff, "nothing was checked yet")
        let host = NSHostingView(rootView: SettingsCalendarIntegrationsView(connections: connections).frame(width: 520))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 520, height: 900),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(connections.appleAccessOff, "opening Settings reads the current permission")
        XCTAssertEqual(connections.errors["apple"], CalendarConnectionError.appleAccessOffMessage)
        XCTAssertEqual(mac.prompts, 0)
        XCTAssertEqual(mac.reads, 0, "Settings checks the status only, it reads no events")

        mac.status = .fullAccess   // back from System Settings with Settings still open: Whytap becomes active
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(connections.appleAccessOff)
        XCTAssertNil(connections.errors["apple"])
        XCTAssertEqual(mac.reads, 0)
    }

    func testSettingsNeverChecksAnUnconnectedCalendar() async throws {
        let mac = FakeMac(); mac.status = .denied
        let connections = connections(mac)
        try await renderSettings(connections)
        XCTAssertEqual(mac.statusReads, 0)
        XCTAssertEqual(mac.prompts, 0)
        XCTAssertFalse(connections.appleAccessOff)
    }

    func testSettingsClearsAStaleRefusalOnceAccessIsAllowed() async throws {
        let mac = FakeMac(); mac.answer = .denied
        let connections = connections(mac)
        let flow = CalendarConnectionFlow(connections: connections)
        XCTAssertTrue(flow.startRegistered(provider: .apple, info: nil))
        try await finish(flow)
        XCTAssertEqual(flow.error, CalendarConnectionError.appleConnectRefusedMessage)
        mac.status = .fullAccess
        connections.checkAppleAccess()
        flow.clearAppleRefusalIfAllowed()
        XCTAssertNil(flow.error)
        XCTAssertFalse(connections.appleAccessOff)
        XCTAssertFalse(connections.appleConnectRefused)
    }

    func testDisconnectingAppleForgetsTheAccessWarning() {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .denied
        let connections = connections(mac)
        connections.refreshAppleIfEnabled(interval: DateInterval(start: day, duration: 86_400))
        XCTAssertTrue(connections.appleAccessOff)
        connections.disableApple()
        XCTAssertFalse(connections.appleAccessOff)
        XCTAssertNil(connections.errors["apple"])
        XCTAssertFalse(defaults.bool(forKey: CalendarAccountSettings.appleEnabledKey))
    }

    // MARK: - Empty and filled days

    func testAMacWithNoCalendarsShowsAnEmptyDayWithoutAnError() async {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        let connections = connections(mac)
        let model = model(connections)
        model.begin()
        await connections.refresh(interval: model.interval)
        XCTAssertEqual(mac.reads, 1)
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertTrue(connections.feeds.isEmpty)
        XCTAssertTrue(connections.errors.isEmpty)
        XCTAssertFalse(connections.refreshing)
    }

    func testNoConnectionAtAllShowsAnEmptyDay() async {
        let connections = connections(FakeMac())
        let model = model(connections)
        model.begin()
        await connections.refresh(interval: model.interval)
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertTrue(connections.accounts.isEmpty)
        XCTAssertFalse(connections.appleEnabled)
    }

    func testAnEventWithACallLinkJoinsTheCallAndAnotherOpensInCalendar() async {
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let mac = FakeMac(); mac.status = .fullAccess
        mac.feeds = [CalendarFeed(id: "apple:work", accountID: nil, remoteID: "work", title: "Work · Exchange", provider: .apple,
                                  displayService: .microsoft)]
        mac.events = [appleEvent("Sync", hour: 11, notes: "Join: https://example.zoom.us/j/123456789"),
                      appleEvent("Focus", hour: 13, identifier: "ABC-1")]
        let connections = connections(mac)
        let model = model(connections)
        var opened: [URL] = []
        model.openURL = { opened.append($0) }
        model.begin()
        await connections.refresh(interval: model.interval)
        let events = model.events
        XCTAssertEqual(events.map(\.event.title), ["Sync", "Focus"])
        XCTAssertEqual(model.actionTitle(events[0]), "Join meeting")
        XCTAssertEqual(model.actionTitle(events[1]), "Open in Calendar")
        XCTAssertEqual(model.previewContent(events[0]).source, .provider(.microsoft))
        XCTAssertEqual(model.previewContent(events[0]).link, CalendarEventPreviewContent.linkText(events[0].event.meetingURL!))
        XCTAssertTrue(model.perform(events[0]))
        XCTAssertTrue(model.perform(events[1]))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.zoom.us/j/123456789",
            "ical://ekevent/ABC-1?method=show&options=more"])
    }
}
