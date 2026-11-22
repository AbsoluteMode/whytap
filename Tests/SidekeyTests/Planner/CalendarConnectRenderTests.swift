import AppKit
import EventKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Offscreen pictures of Calendar's Connect page in Hover and the Calendars
/// section of Settings → Integrations in each access state. Set
/// WHYTAP_CALENDAR_CONNECT_RENDER_DIR to write them; otherwise skipped.
@MainActor
final class CalendarConnectRenderTests: XCTestCase {
    private struct State {
        let name: String
        let status: EKAuthorizationStatus
        let connected: Bool
        let feeds: [CalendarFeed]
    }

    private static let macCalendars = [
        CalendarFeed(id: "apple:home", accountID: nil, remoteID: "home", title: "Home · iCloud", provider: .apple,
                     sourceTitle: "iCloud", calendarTitle: "Home"),
        CalendarFeed(id: "apple:family", accountID: nil, remoteID: "family", title: "Family · iCloud", provider: .apple,
                     sourceTitle: "iCloud", calendarTitle: "Family"),
        CalendarFeed(id: "apple:work", accountID: nil, remoteID: "work", title: "max@gmail.com · Google", provider: .apple,
                     displayService: .google, sourceTitle: "max@gmail.com", calendarTitle: "max@gmail.com"),
        CalendarFeed(id: "apple:holidays", accountID: nil, remoteID: "holidays", title: "Holidays · Google", provider: .apple,
                     displayService: .google, sourceTitle: "max@gmail.com", calendarTitle: "Holidays in Russia"),
        CalendarFeed(id: "apple:exchange", accountID: nil, remoteID: "exchange", title: "Calendar · Exchange", provider: .apple,
                     displayService: .microsoft, sourceTitle: "Exchange", calendarTitle: "Calendar"),
    ]

    private let states = [
        State(name: "1-not-asked", status: .notDetermined, connected: false, feeds: []),
        State(name: "2-refused", status: .denied, connected: false, feeds: []),
        State(name: "3-no-calendars", status: .fullAccess, connected: true, feeds: []),
        State(name: "4-calendars", status: .fullAccess, connected: true, feeds: macCalendars),
    ]

    func testOffscreenConnectStates() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_CALENDAR_CONNECT_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_CALENDAR_CONNECT_RENDER_DIR for offscreen Calendar Connect pictures.")
        }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for state in states {
            let suite = "test.calendar-connect-render." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(state.connected, forKey: CalendarAccountSettings.appleEnabledKey)
            defaults.set(["apple:holidays"], forKey: "planner.calendar.hiddenFeeds")
            let feeds = state.feeds
            let status = state.status
            let connections = CalendarConnections(defaults: defaults,
                oauth: CalendarOAuthClient(storage: PlannerMemoryCredentials()),
                apple: AppleCalendarAccess(status: { status }, request: { status == .fullAccess },
                                           read: { _ in (feeds, []) }))
            if state.status == .denied {
                do { try await connections.enableApple() } catch {}
            }
            connections.refreshAppleIfEnabled(interval: DateInterval(start: Date(), duration: 86_400))
            let model = CalendarHoverModel(store: PlannerStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("connect-render-\(UUID().uuidString).json")), connections: connections)
            model.page = .providers
            try render(CalendarHoverView(model: model, liveUpdates: false, onBack: {})
                .frame(width: 380).background(Color.black),
                size: NSSize(width: 380, height: CalendarHoverView.contentHeight), dark: true,
                to: destination.appendingPathComponent("hover-\(state.name).png"))
            for dark in [false, true] {
                try render(SettingsCalendarIntegrationsView(connections: connections).padding(24)
                    .background(MacSettingsTheme.bgContent),
                    size: NSSize(width: 560, height: 760), dark: dark,
                    to: destination.appendingPathComponent("settings-\(state.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
