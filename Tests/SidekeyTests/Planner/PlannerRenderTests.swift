import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class PlannerRenderTests: XCTestCase {
    override func setUp() { super.setUp(); openCalendarForThisTest() }

    func testOffscreenPlannerFixtures() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_PLANNER_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_PLANNER_RENDER_DIR for offscreen Planner fixtures.")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "test.planner-render." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = PlannerStore(url: directory.appendingPathComponent("planner.json"))
        let navigation = PlannerNavigation()
        navigation.selectedDay = CalendarDateCodec.parse("2026-10-19T10:00:00+03:00")!
        let connections = CalendarConnections(defaults: defaults)
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for size in [NSSize(width: 980, height: 680), NSSize(width: 820, height: 560)] {
            try render(PlannerView(store: store, navigation: navigation, connections: connections), size: size,
                to: destination.appendingPathComponent("tasks-empty-\(Int(size.width)).png"))
        }
        _ = store.saveTask(PlannerTask(title: "Review the unified calendar layout"))
        _ = store.saveTask(PlannerTask(title: "Send the proposal after the design review and check the updated schedule with the team"))
        _ = store.saveTask(PlannerTask(title: "Забрать заказ и купить кофе"))
        _ = store.saveTask(PlannerTask(title: "Book meeting room", completed: true))
        try render(PlannerView(store: store, navigation: navigation, connections: connections), size: NSSize(width: 980, height: 680),
            to: destination.appendingPathComponent("tasks.png"))
        let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: navigation.selectedDay)!
        _ = store.saveEvent(PlannerEvent(title: "Design review", start: start, end: start.addingTimeInterval(3600),
            location: "Studio", meetingURL: URL(string: "https://teams.microsoft.com/l/meetup-join/fixture")))
        _ = store.saveEvent(PlannerEvent(title: "Coffee with Alex", start: start.addingTimeInterval(7200), end: start.addingTimeInterval(9000)))
        navigation.section = .calendar
        for size in [NSSize(width: 980, height: 680), NSSize(width: 820, height: 560)] {
            try render(PlannerView(store: store, navigation: navigation, connections: connections), size: size,
                to: destination.appendingPathComponent("calendar-\(Int(size.width)).png"))
        }
        try render(CalendarConnectView(connections: connections), size: NSSize(width: 532, height: 500),
            to: destination.appendingPathComponent("connect.png"))
        try render(PlannerEventEditor(event: store.archive.events[0], store: store), size: NSSize(width: 538, height: 510),
            to: destination.appendingPathComponent("event-editor.png"))
        for scheme in [ColorScheme.light, .dark] {
            for size in [NSSize(width: 980, height: 680), NSSize(width: 820, height: 560)] {
                for section in PlannerSection.allCases {
                    navigation.section = section
                    try render(PlannerView(store: store, navigation: navigation, connections: connections), size: size,
                        to: destination.appendingPathComponent("\(section == .tasks ? "tasks" : "calendar")-\(Int(size.width))-\(scheme).png"), scheme: scheme)
                }
            }
        }
        defaults.set((0..<CalendarAccountSettings.maximumHiddenFeeds).map { "fixture:\($0)" },
            forKey: CalendarAccountSettings.hiddenFeedsKey)
        let capped = CalendarConnections(defaults: defaults)
        capped.setVisible(false, feedID: "local")
        XCTAssertNotNil(capped.errors["visibility"])
        for scheme in [ColorScheme.light, .dark] {
            try render(CalendarSourcesView(connections: capped, onConnect: {})
                .background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 410, height: 400),
                to: destination.appendingPathComponent("calendar-limit-\(scheme).png"), scheme: scheme)
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL, scheme: ColorScheme = .dark) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).tint(.blue))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
