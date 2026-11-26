import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class NotifyRenderTests: XCTestCase {
    func testOffscreenPillAndHistoryFixtures() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_NOTIFY_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_NOTIFY_RENDER_DIR for source-matched offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // SwiftPM doesn't package the production assets. Load the same PDFs
        // directly for this isolated fixture, without touching the user's logos.
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loadImage: (String) -> NSImage? = { name in
            NSImage(contentsOf: checkout.appendingPathComponent("Resources/UsefulLinkIcons/\(name).pdf"))
        }
        for name in ["codex", "claude-code"] {
            XCTAssertNotNil(loadImage(name))
        }
        let fixtures = [("telegram", "Message from Alex", "The build is ready", "#299FD6", "paperplane.fill"),
                        ("warning", "Deployment needs attention", "A deliberately long message that must fit the original left-side slot without overflowing", "#F2A03B", "exclamationmark.triangle.fill")]
        var events: [LocalNotificationEvent] = []
        for (id, title, body, tint, logo) in fixtures {
            let event = LocalNotificationEvent(id: id, source: id, sourceName: id, title: title, body: body,
                link: URL(string: "https://example.com"), timestamp: Date(), customDuration: 8,
                customTint: tint, customLogo: logo)
            events.append(event)
            let pill = IslandNotificationPill(event: event, deadline: Date().addingTimeInterval(6), duration: 8)
            let size = NSSize(width: 300 + IslandNotificationPill.panelLeadingOverflow,
                              height: 32 + IslandNotificationPill.panelBottomOverflow)
            for hovered in [false, true] {
                let view = pill.content(progress: 0.75, hovered: hovered)
                    .padding(.trailing, 8)
                    .frame(width: 300, height: 32, alignment: .topTrailing)
                    .padding(.leading, IslandNotificationPill.panelLeadingOverflow)
                    .padding(.bottom, IslandNotificationPill.panelBottomOverflow)
                try render(view, size: size,
                           to: directory.appendingPathComponent("card-\(id)-\(hovered).png"))
            }
            let reduced = pill.content(progress: 0.75, hovered: true, reduceMotion: true)
                .padding(.trailing, 8)
                .frame(width: 300, height: 32, alignment: .topTrailing)
                .padding(.leading, IslandNotificationPill.panelLeadingOverflow)
                .padding(.bottom, IslandNotificationPill.panelBottomOverflow)
            try render(reduced, size: size, to: directory.appendingPathComponent("card-\(id)-reduced.png"))
            let idle = try pixelBounds(directory.appendingPathComponent("card-\(id)-false.png"))
            let hover = try pixelBounds(directory.appendingPathComponent("card-\(id)-true.png"))
            let reducedBounds = try pixelBounds(directory.appendingPathComponent("card-\(id)-reduced.png"))
            // Enlargement is required. Check the rendered silhouette actually grows
            // while remaining inside the native panel, with intact rounded edges.
            XCTAssertGreaterThan(hover.bounds.width, idle.bounds.width)
            XCTAssertGreaterThan(hover.bounds.height, idle.bounds.height)
            XCTAssertEqual(hover.bounds.maxX, idle.bounds.maxX, accuracy: 1)
            XCTAssertEqual(hover.bounds.minY, idle.bounds.minY, accuracy: 1)
            XCTAssertGreaterThan(hover.bounds.minX, 0)
            XCTAssertLessThan(hover.bounds.maxX, hover.size.width)
            XCTAssertLessThan(hover.bounds.maxY, hover.size.height)
            XCTAssertEqual(reducedBounds.bounds, idle.bounds)

        }
        let tools = HStack {
            IslandHoverPanelControl(title: "Notify", systemImage: "bell", pdfResource: nil, label: nil,
                circleSize: 30, accessibilityLabel: "Notify", showsDot: true, action: {})
            IslandHoverPanelControl(title: "Monitor", systemImage: "chart.xyaxis.line", pdfResource: nil, label: nil,
                circleSize: 30, accessibilityLabel: "Monitor", action: {})
        }.padding(8).background(Color(white: 0.08))
        try render(tools, size: NSSize(width: 210, height: 70),
            to: directory.appendingPathComponent("notify-attention-monitor-quiet.png"))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let hub = LocalNotificationHub(directory: temporary)
        for event in events { _ = await hub.receive(event) }
        hub.setSuspended(true)
        let supervisor = NotifyScriptSupervisor(directory: temporary, hub: hub)
        try render(NotifyHoverPanel(hub: hub, supervisor: supervisor, onBack: {}),
                   size: NSSize(width: 312, height: 235), to: directory.appendingPathComponent("history.png"))
        await hub.clear()
        try render(NotifyHoverPanel(hub: hub, supervisor: supervisor, onBack: {}),
                   size: NSSize(width: 312, height: 235), to: directory.appendingPathComponent("history-cleared.png"))

        try render(settings(supervisor), size: NSSize(width: 760, height: 560),
                   to: directory.appendingPathComponent("settings-empty.png"))
        let registry = temporary.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let sources = [
            NotifyScript(id: "telegram", name: "Telegram · selected chats", command: ["/bin/sleep", "30"], tint: "#299FD6", logo: "paperplane.fill"),
            NotifyScript(id: "builds", name: "Build results", command: ["/bin/sleep", "30"], enabled: false, tint: "#F2A03B", logo: "hammer.fill")
        ]
        for source in sources {
            try JSONEncoder().encode(source).write(to: registry.appendingPathComponent(source.id + ".json"))
        }
        supervisor.start()
        defer { supervisor.stop() }
        for _ in 0..<100 where supervisor.sources.count != 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(supervisor.sources.count, 2)
        try render(settings(supervisor), size: NSSize(width: 760, height: 560),
                   to: directory.appendingPathComponent("settings-sources.png"))
        supervisor.setEnabled(false, id: "telegram")
        XCTAssertFalse(try JSONDecoder().decode(NotifyScript.self, from: Data(contentsOf: registry.appendingPathComponent("telegram.json"))).enabled)
        try render(settings(supervisor), size: NSSize(width: 760, height: 560),
                   to: directory.appendingPathComponent("settings-disabled.png"))
    }
    private func pixelBounds(_ url: URL) throws -> (bounds: CGRect, size: CGSize) {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent > 0.05 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX)
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
                CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
    }

    private func settings(_ supervisor: NotifyScriptSupervisor) -> some View {
        let suite = "NotifyRender." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let meetings = MeetingReadyNotifications(defaults: defaults, hub: LocalNotificationHub(directory: directory))
        let sounds = NotificationSoundSettings(defaults: defaults)
        return NotificationSourcesGroups(supervisor: supervisor, meetingNotifications: meetings, soundSettings: sounds,
                                         imageLoader: { NotifyLogoStore.image(named: $0) })
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(MacSettingsTheme.bgContent)
    }
    private func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let isSettings = url.lastPathComponent.hasPrefix("settings-")
        let schemes = isSettings ? [ColorScheme.light, .dark] : [.dark]
        let sizes = isSettings ? [NSSize(width: 560, height: size.height), size] : [size]
        for frameSize in sizes {
            for scheme in schemes {
                let targetURL = isSettings ? url.deletingLastPathComponent().appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + "-\(Int(frameSize.width))" + (scheme == .light ? "-light.png" : "-dark.png")) : url
                let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
                host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                host.frame = NSRect(origin: .zero, size: frameSize)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: targetURL)
                XCTAssertFalse(window.isVisible)
            }
        }
    }
}
