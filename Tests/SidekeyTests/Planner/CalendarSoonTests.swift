import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Calendar ships closed with a "Soon" badge. These tests run with the real
/// default (no override): it can be seen, never used, never asks for access.
// WHY: .project-docs/decisions/2026-11-21-calendar-soon.md
@MainActor
final class CalendarSoonTests: XCTestCase {
    private var storage: PlannerMemoryCredentials!
    private var http: CalendarHTTP!
    private var oauth: CalendarOAuthClient!
    private var defaults: UserDefaults!
    private var suite = ""
    private var requests = 0

    override func setUp() async throws {
        XCTAssertNil(CalendarAvailability.testOverride, "another test leaked the Calendar override")
        storage = PlannerMemoryCredentials()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerURLProtocol.self]
        http = CalendarHTTP(session: URLSession(configuration: configuration))
        oauth = CalendarOAuthClient(http: http, storage: storage)
        requests = 0
        PlannerURLProtocol.handler = { [unowned self] _ in requests += 1; return (200, [:]) }
        suite = "calendar.soon." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        PlannerURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suite)
    }

    /// A user who had Apple Calendar and a Google account connected before it was closed.
    private func previouslyConnected(activity: ((Bool) -> Void)? = nil) throws -> CalendarConnections {
        let account = ConnectedCalendarAccount(id: UUID(), provider: .google, label: "Work")
        defaults.set(try JSONEncoder().encode([account]), forKey: CalendarAccountSettings.accountsKey)
        defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        try storage.save(CalendarCredential(provider: .google, clientID: "fixture-client", accessToken: "fixture-access",
            refreshToken: "fixture-refresh", expiresAt: .distantPast), id: account.id)
        return CalendarConnections(defaults: defaults, oauth: oauth, http: http, activityChanged: activity ?? { _ in })
    }

    // MARK: - The switch

    func testShipsClosed() {
        XCTAssertFalse(CalendarAvailability.shipped)
        XCTAssertFalse(CalendarAvailability.isOpen)
        XCTAssertEqual(CalendarAvailability.blockReason, CalendarAvailability.message)
        XCTAssertEqual(CalendarAvailability.badge, "Soon")
    }

    func testOnlyCalendarIsComingSoonAndTheOverrideOpensIt() {
        XCTAssertEqual(HoverTool.allCases.filter(\.isComingSoon), [.calendar])
        XCTAssertEqual(HoverTool.calendar.comingSoonBadge, "Soon")
        XCTAssertNil(HoverTool.tasks.comingSoonBadge)
        openCalendarForThisTest()
        XCTAssertTrue(CalendarAvailability.isOpen)
        XCTAssertFalse(HoverTool.calendar.isComingSoon)
        XCTAssertNil(HoverTool.calendar.comingSoonBadge)
        XCTAssertNil(CalendarAvailability.blockReason)
    }

    // MARK: - Visible, but nothing opens

    func testCalendarStaysListedAndSearchableWithASoonDescription() {
        XCTAssertTrue(IslandHoverToolSearch.results(for: "calendar").contains(.calendar))
        XCTAssertTrue(IslandHoverToolSearch.results(for: "календарь").contains(.calendar))
        XCTAssertEqual(HoverToolRegistry.info(for: .calendar).title, "Calendar")
        XCTAssertEqual(HoverToolRegistry.description(for: .calendar, mode: .fast, inputLanguage: nil, outputLanguage: nil),
                       CalendarAvailability.message)
    }

    func testEveryActivationPathResolvesToNothing() {
        XCTAssertEqual(HoverSlotRouter.effect(for: .calendar), .comingSoon)
        XCTAssertFalse(HoverSlotEffect.comingSoon.requiresExpansion)
        XCTAssertNil(HoverSlotEffect.comingSoon.hotkeyTranslationToggle)
        var calls = 0
        var actions = IslandActions.noOp
        actions.openCalendar = { calls += 1 }
        HoverSlotRouter.effect(for: .calendar).invoke(on: actions)
        XCTAssertEqual(calls, 0, "a closed Calendar must not run the open action")
        XCTAssertEqual(HoverSlotRouter.effect(for: .tasks), .openPanel(.tasks))
        XCTAssertEqual(HoverSlotRouter.effect(for: .monitor), .openPanel(.monitor))
    }

    func testOpenedCalendarRoutesAsBefore() {
        openCalendarForThisTest()
        XCTAssertEqual(HoverSlotRouter.effect(for: .calendar), .openPanel(.calendar))
    }

    func testHotkeyNeverCapturesAKeyButKeepsTheSavedShortcut() {
        let shortcut = HotkeyShortcut.combo(.optionD)
        let bindings = ToolHotkeyBinding.resolve([.calendar: shortcut, .tasks: shortcut])
        XCTAssertEqual(bindings.map(\.tool), [.tasks])
        openCalendarForThisTest()
        XCTAssertEqual(Set(ToolHotkeyBinding.resolve([.calendar: shortcut, .tasks: shortcut]).map(\.tool)), [.calendar, .tasks])
    }

    func testLinksOnlyShowThePaneAndNeverProposeAHotkey() throws {
        XCTAssertEqual(WhytapLink.destination(for: .calendar), .toolboxTool(.calendar))
        XCTAssertFalse(WhytapLink.acceptsLinkHotkey(.calendar))
        XCTAssertTrue(WhytapLink.acceptsLinkHotkey(.tasks))
        let url = try XCTUnwrap(URL(string: "whytap://hotkey/calendar?keys=option+shift+c"))
        guard case .show(let destination)? = WhytapLink.request(for: url) else { return XCTFail("a closed Calendar proposed a hotkey") }
        XCTAssertEqual(destination, .settings(.tab(.hotkeys)))
    }

    // MARK: - Nothing connects, nothing is requested

    func testConnectionIsRefusedWithoutAskingMacOSOrAProvider() async throws {
        let connections = CalendarConnections(defaults: defaults, oauth: oauth, http: http)
        XCTAssertEqual(connections.connectionBlockReason, CalendarAvailability.message)
        XCTAssertFalse(connections.beginConnecting(provider: .apple))
        XCTAssertFalse(connections.isConnecting)
        do { try await connections.enableApple(); XCTFail("Apple Calendar was enabled while closed") }
        catch CalendarConnectionError.comingSoon { }
        catch { XCTFail("unexpected error \(error)") }
        XCTAssertFalse(connections.appleEnabled)
        XCTAssertNil(defaults.object(forKey: CalendarAccountSettings.appleEnabledKey), "nothing is stored while closed")
        XCTAssertThrowsError(try connections.add(ConnectedCalendarAccount(id: UUID(), provider: .google, label: "New")))
        XCTAssertTrue(connections.accounts.isEmpty)
        XCTAssertEqual(requests, 0)
    }

    func testConnectFlowNeverStartsEvenWithAFullyRegisteredClient() async throws {
        let connections = CalendarConnections(defaults: defaults, oauth: oauth, http: http)
        var authorized = 0
        var activity: [Bool] = []
        let flow = CalendarConnectionFlow(connections: connections, activityChanged: { activity.append($0) },
            googleReview: { true }, authorize: { _, _, _, _ in authorized += 1; throw CalendarConnectionError.cancelled })
        let info: [String: Any] = ["WhytapCalendarOAuthClients": [
            "google": ["clientID": "fixture-client", "clientSecret": "fixture", "publicAccessApproved": "true"],
            "microsoft": ["clientID": "fixture-client"],
            "zoom": ["clientID": "fixture-client", "publicAccessApproved": "true"]]]
        for provider in [CalendarProvider.apple, .google, .microsoft, .zoom] {
            XCTAssertFalse(flow.startRegistered(provider: provider, info: info), provider.title)
            XCTAssertEqual(flow.error, CalendarAvailability.message)
            XCTAssertFalse(flow.start(provider: provider, clientID: "fixture-client", secret: "", label: "", info: info, onSuccess: {}))
        }
        XCTAssertFalse(flow.working)
        XCTAssertFalse(connections.isConnecting)
        XCTAssertEqual(authorized, 0)
        XCTAssertTrue(activity.isEmpty, "Settings update restarts must not be held by a closed Calendar")
        XCTAssertEqual(requests, 0)
    }

    func testPreviouslyEnabledCalendarsDoNothingButKeepTheirSavedData() async throws {
        let connections = try previouslyConnected()
        XCTAssertEqual(connections.accounts.count, 1)
        let savedAccounts = defaults.data(forKey: CalendarAccountSettings.accountsKey)
        let interval = DateInterval(start: Date(), duration: 86_400)
        await connections.refresh(interval: interval)
        connections.refreshAppleIfEnabled(interval: interval)
        XCTAssertEqual(requests, 0, "no provider request for a calendar that was connected before")
        XCTAssertFalse(connections.refreshing)
        XCTAssertTrue(connections.events.isEmpty)
        XCTAssertTrue(connections.feeds.isEmpty)
        XCTAssertTrue(connections.errors.isEmpty, "no EventKit read, so no denied error either")
        XCTAssertTrue(connections.lastSynced.isEmpty)
        // The brother's work and users' connections survive: the switch only stops them running.
        XCTAssertEqual(defaults.data(forKey: CalendarAccountSettings.accountsKey), savedAccounts)
        XCTAssertTrue(defaults.bool(forKey: CalendarAccountSettings.appleEnabledKey))
    }

    func testReopeningCalendarBringsBackThePreviousConnections() async throws {
        let connections = try previouslyConnected()
        openCalendarForThisTest()
        XCTAssertNil(connections.connectionBlockReason)
        PlannerURLProtocol.handler = { [unowned self] request in
            requests += 1
            if request.url?.host == "oauth2.googleapis.com" {
                return (200, ["access_token": "fixture-updated", "refresh_token": "fixture-rotated", "expires_in": 3600, "token_type": "bearer"])
            }
            return (200, ["items": []])
        }
        await connections.refresh(interval: DateInterval(start: Date(), duration: 86_400))
        XCTAssertGreaterThan(requests, 0, "once opened the stored account is read again")
    }

    func testHoverModelDoesNotOpenOrConnect() throws {
        var active: [Bool] = []
        let connections = CalendarConnections(defaults: defaults, oauth: oauth, http: http)
        let model = CalendarHoverModel(
            store: PlannerStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("soon-\(UUID().uuidString).json")),
            connections: connections, activityChanged: { active.append($0) })
        model.begin()
        XCTAssertFalse(model.visible)
        XCTAssertTrue(active.isEmpty)
        XCTAssertFalse(model.connect(.apple, info: nil))
        XCTAssertFalse(model.connectionFlow.working)
        XCTAssertFalse(connections.isConnecting)
    }

    // MARK: - What the user sees

    /// Headless SwiftUI exposes no accessibility tree, so the card is checked by what it
    /// replaces: one compact card instead of four provider cards with Connect/Disconnect.
    func testSettingsShowsOneCompactSoonCardInsteadOfTheProviderCards() async throws {
        let connections = try previouslyConnected()
        func height() async throws -> CGFloat {
            let host = NSHostingView(rootView: SettingsCalendarIntegrationsView(connections: connections).frame(width: 520))
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 520, height: 900),
                styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30))
            return host.fittingSize.height
        }
        let closed = try await height()
        XCTAssertGreaterThan(closed, 60)
        openCalendarForThisTest()
        let open = try await height()
        XCTAssertGreaterThan(open, closed * 2, "closed \(closed) pt, open \(open) pt")
    }
}
