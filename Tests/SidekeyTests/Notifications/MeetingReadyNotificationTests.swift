import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class MeetingReadyNotificationTests: XCTestCase {
    private func fixture() -> (UserDefaults, LocalNotificationHub, URL, String) {
        let suite = "MeetingReadyNotificationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (defaults, LocalNotificationHub(directory: directory), directory, suite)
    }

    func testNewAndExistingUsersDefaultToEnabledButOptOutSurvivesRelaunch() async throws {
        let (defaults, hub, directory, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        defaults.set("existing-user-setting", forKey: "unrelated")
        let source = MeetingReadyNotifications(defaults: defaults, hub: hub)
        XCTAssertTrue(source.enabled)
        source.enabled = false
        let reloaded = MeetingReadyNotifications(defaults: defaults, hub: hub)
        XCTAssertFalse(reloaded.enabled)
        let ignored = await reloaded.receive(.newMeetingAvailable(id: UUID()))
        XCTAssertFalse(ignored)
        XCTAssertTrue(hub.history.isEmpty)
        reloaded.enabled = true
        let received = await reloaded.receive(.newMeetingAvailable(id: UUID()))
        XCTAssertTrue(received)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "existing-user-setting")
        hub.setSuspended(true)
    }

    func testOnlySuccessfulCompletionNotifiesWithBrandAndExactMeetingAndDeduplicates() async throws {
        let (defaults, hub, directory, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let source = MeetingReadyNotifications(defaults: defaults, hub: hub)
        let id = UUID()
        let failed = await source.receive(.meetingFailed(id: id, error: "Synthetic failure"))
        XCTAssertFalse(failed)
        XCTAssertTrue(hub.history.isEmpty)
        let received = await source.receive(.newMeetingAvailable(id: id))
        XCTAssertTrue(received)
        let event = try XCTUnwrap(hub.current)
        XCTAssertEqual(event.meetingID, id)
        XCTAssertNil(event.link)
        XCTAssertTrue(event.canActivate)
        XCTAssertEqual(event.customLogo, "whytap")
        XCTAssertEqual(event.sourceName, "Meeting notes")
        XCTAssertEqual(event.resolvedDuration, 8)
        let duplicate = await source.receive(.newMeetingAvailable(id: id))
        XCTAssertFalse(duplicate)
        XCTAssertEqual(hub.history.count, 1)
        hub.setSuspended(true)

        let restored = LocalNotificationHub(directory: directory)
        await restored.load()
        XCTAssertNil(restored.current) // No old popups when the app launches.
        XCTAssertEqual(restored.history.first?.meetingID, id)
        let reloaded = MeetingReadyNotifications(defaults: defaults, hub: restored)
        let replay = await reloaded.receive(.newMeetingAvailable(id: id))
        XCTAssertFalse(replay)
        var opened: [UUID] = []
        restored.openMeeting = { opened.append($0) }
        restored.activate(try XCTUnwrap(restored.history.first), openLink: { _ in XCTFail("Internal navigation must stay in the app") })
        XCTAssertEqual(opened, [id])

        let nextID = UUID()
        _ = await reloaded.receive(.newMeetingAvailable(id: nextID))
        XCTAssertEqual(restored.current?.meetingID, nextID)
        XCTAssertEqual(restored.history.count, 2)
        restored.setSuspended(true)
    }

    /// A meeting finished without a notes model says it has a transcript,
    /// not notes, and opens that meeting.
    func testTranscriptOnlyMeetingNotifiesThatItsTranscriptIsReady() async throws {
        let (defaults, hub, directory, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let source = MeetingReadyNotifications(defaults: defaults, hub: hub)
        let id = UUID()
        let received = await source.receive(.meetingTranscriptAvailable(id: id))
        XCTAssertTrue(received)
        let event = try XCTUnwrap(hub.current)
        XCTAssertEqual(event.meetingID, id)
        XCTAssertEqual(event.title, "Meeting transcript is ready")
        XCTAssertEqual(event.body, "No notes model is chosen. Click to open the transcript.")
        hub.setSuspended(true)
    }

    func testLegacyHistoryAndExternalLinksKeepTheirNavigationAndCannotSupplyMeetingTarget() throws {
        let (_, hub, directory, suite) = fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let script = NotifyScript(id: "fixture", name: "Fixture", command: ["/bin/echo"])
        let data = try JSONSerialization.data(withJSONObject: [
            "title": "Done", "link": "https://example.com", "meetingID": UUID().uuidString
        ])
        let payload = try JSONDecoder().decode(NotifyPayload.self, from: data)
        let event = try LocalNotificationEvent.make(payload, script: script)
        XCTAssertNil(event.meetingID)
        let restored = try JSONDecoder().decode(LocalNotificationEvent.self, from: JSONEncoder().encode(event))
        XCTAssertNil(restored.meetingID)
        var opened: [URL] = []
        hub.openMeeting = { _ in XCTFail("An external link must retain its destination") }
        hub.activate(restored, openLink: { opened.append($0) })
        XCTAssertEqual(opened, [URL(string: "https://example.com")!])
    }

    func testOffscreenMeetingNotificationAndSettings() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_NOTIFY_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_NOTIFY_RENDER_DIR for offscreen visual checks.")
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let (defaults, hub, directory, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let source = MeetingReadyNotifications(defaults: defaults, hub: hub)
        let supervisor = NotifyScriptSupervisor(directory: directory, hub: hub)
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let icon = try XCTUnwrap(NSImage(contentsOf: checkout.appendingPathComponent("Resources/AppIcon.icns")))
        let loadImage: (String) -> NSImage? = { $0 == "whytap" ? icon : nil }
        _ = await source.receive(.newMeetingAvailable(id: UUID()))
        let event = try XCTUnwrap(hub.current)
        XCTAssertEqual(IslandNotificationPill.resolvedGlyph(for: event, imageExists: { loadImage($0) != nil }),
                       .brandImage(name: "whytap"))
        let soundSettings = NotificationSoundSettings(defaults: defaults)
        for enabled in [true, false] {
            source.enabled = enabled
            soundSettings.setSound(enabled ? .glass : .none, for: MeetingReadyNotifications.sourceID)
            for width in [560, 760] {
                let view = NotificationSourcesGroups(supervisor: supervisor, meetingNotifications: source,
                                                     soundSettings: soundSettings, imageLoader: loadImage)
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(white: 0.12)).environment(\.colorScheme, .dark)
                try render(view, size: NSSize(width: width, height: 650),
                           to: destination.appendingPathComponent("meeting-settings-\(enabled)-\(width).png"))
            }
        }
        hub.setSuspended(true)
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
    }
}
