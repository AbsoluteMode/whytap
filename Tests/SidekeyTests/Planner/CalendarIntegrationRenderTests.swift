import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class CalendarIntegrationRenderTests: XCTestCase {
    override func setUp() { super.setUp(); openCalendarForThisTest() }

    func testOffscreenCalendarIntegrationStates() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_CALENDAR_INTEGRATIONS_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_CALENDAR_INTEGRATIONS_RENDER_DIR for offscreen integration fixtures.")
        }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let suite = "test.calendar-integration-render." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending: (CalendarProvider) -> CalendarConnectionReadiness = { provider in
            .shared(provider, configuration: provider == .apple || provider == .zoom ? nil : .init(clientID: "fixture"), googleReview: false)
        }
        let connections = CalendarConnections(defaults: defaults)
        for dark in [false, true] {
            for width in [500.0, 739.0, 1059.0] {
                try render(SettingsCalendarIntegrationsView(connections: connections, readiness: pending).padding(24),
                    size: NSSize(width: width, height: 800), dark: dark,
                    to: destination.appendingPathComponent("pending-\(Int(width))-\(dark).png"))
            }
            try render(interactionStates(), size: NSSize(width: 680, height: 320), dark: dark,
                to: destination.appendingPathComponent("interaction-states-\(dark).png"))
            try render(interactionStates(reduceMotion: true),
                size: NSSize(width: 680, height: 320), dark: dark,
                to: destination.appendingPathComponent("reduced-motion-\(dark).png"))
        }
        let account = ConnectedCalendarAccount(id: UUID(), provider: .microsoft,
            label: "Work · Product and engineering — рабочий календарь для встреч и обсуждений проекта")
        try connections.add(account)
        for dark in [false, true] {
            try render(CalendarSourcesView(connections: connections, onConnect: {}),
                size: NSSize(width: 410, height: 400), dark: dark,
                to: destination.appendingPathComponent("sources-long-account-\(dark).png"))
        }
        XCTAssertTrue(connections.beginConnecting(provider: .microsoft))
        defer { connections.endConnecting() }
        try render(SettingsCalendarIntegrationsView(connections: connections, readiness: pending).padding(24),
            size: NSSize(width: 500, height: 900), dark: false, to: destination.appendingPathComponent("busy-long-account.png"))
        defaults.set(Data("invalid synthetic metadata".utf8), forKey: CalendarAccountSettings.accountsKey)
        let damaged = CalendarConnections(defaults: defaults)
        try render(SettingsCalendarIntegrationsView(connections: damaged, readiness: pending).padding(24),
            size: NSSize(width: 500, height: 1000), dark: true, to: destination.appendingPathComponent("preserved-error.png"))
        connections.endConnecting()
        let info: [String: Any] = ["WhytapCalendarOAuthClients": ["google": ["clientID": "fixture"], "microsoft": ["clientID": "fixture"]]]
        for dark in [false, true] {
            for width in [500.0, 739.0, 1059.0] {
                let authorization = AsyncThrowingStream<(code: String, redirect: String), Error>.makeStream()
                let flow = CalendarConnectionFlow(connections: connections, googleReview: { false }, authorize: { _, _, _, _ in
                    var iterator = authorization.stream.makeAsyncIterator()
                    guard let result = try await iterator.next() else { throw CancellationError() }
                    return result
                })
                defer { authorization.continuation.finish(); flow.cancel() }
                XCTAssertTrue(flow.startRegistered(provider: .microsoft, info: info))
                XCTAssertTrue(flow.working)
                try render(SettingsCalendarIntegrationsView(connections: connections, readiness: pending,
                    configurationInfo: info, flow: flow).padding(24), size: NSSize(width: width, height: 1000), dark: dark,
                    to: destination.appendingPathComponent("direct-connecting-\(Int(width))-\(dark).png"))
                flow.cancel()
                for _ in 0..<100 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertFalse(flow.working)
                XCTAssertFalse(flow.startRegistered(provider: .google, info: info))
                try render(SettingsCalendarIntegrationsView(connections: connections, readiness: pending,
                    configurationInfo: info, flow: flow).padding(24), size: NSSize(width: width, height: 1000), dark: dark,
                    to: destination.appendingPathComponent("direct-error-\(Int(width))-\(dark).png"))
            }
        }
    }

    private func interactionStates(reduceMotion: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach([false, true], id: \.self) { primary in
                HStack(spacing: 18) {
                    ForEach(0..<5) { index in
                        VStack(spacing: 8) {
                            Text(["Normal", "Hover", "Pressed", "Focus", "Disabled"][index]).font(.caption)
                            IntegrationControlSurface(primary: primary, focused: index == 3 || index == 4,
                                enabled: index != 4, hovering: index == 1 || index == 4, pressed: index == 2 || index == 4,
                                reduceMotion: reduceMotion) {
                                    Text("Connect")
                                }
                        }
                    }
                }
            }
            IntegrationAction(title: "Connect", primary: true, action: {})
            IntegrationLink(title: "Calendar privacy", destination: URL(string: "https://example.invalid/privacy")!)
        }.padding(24)
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(MacSettingsTheme.bgContent).environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, size)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
