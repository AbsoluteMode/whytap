import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class NotificationSoundTests: XCTestCase {
    private func event(_ id: String) -> LocalNotificationEvent {
        LocalNotificationEvent(id: id, source: "fixture", sourceName: "Fixture", title: "Synthetic event",
                               body: "", link: nil, timestamp: Date())
    }

    /// The sound control is an icon, not a row: silent sources (the default)
    /// show a crossed-out speaker, any chosen sound a plain one.
    func testSpeakerIconIsCrossedOutOnlyWhileSilent() {
        XCTAssertEqual(NotificationSoundControl.symbolName(for: .none), "speaker.slash")
        for sound in NotificationSound.allCases where sound != .none {
            XCTAssertEqual(NotificationSoundControl.symbolName(for: sound), "speaker.wave.2")
        }
    }

    func testSoundsAreOptInAndSavedIndependentlyForEachSource() {
        let suite = "NotificationSoundTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preserved", forKey: "unrelated")
        let settings = NotificationSoundSettings(defaults: defaults)
        XCTAssertEqual(settings.sound(for: MeetingReadyNotifications.sourceID), .none)
        XCTAssertEqual(settings.sound(for: "fixture"), .none)
        settings.setSound(.glass, for: MeetingReadyNotifications.sourceID)
        settings.setSound(.ping, for: "fixture")
        let reloaded = NotificationSoundSettings(defaults: defaults)
        XCTAssertEqual(reloaded.sound(for: MeetingReadyNotifications.sourceID), .glass)
        XCTAssertEqual(reloaded.sound(for: "fixture"), .ping)
        reloaded.setSound(.none, for: "fixture")
        XCTAssertEqual(NotificationSoundSettings(defaults: defaults).sound(for: "fixture"), .none)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "preserved")
        defaults.set(["fixture": "unknown-future-sound"], forKey: "notifications.sourceSounds")
        XCTAssertEqual(NotificationSoundSettings(defaults: defaults).sound(for: "fixture"), .none)
    }

    func testOnlyNewArrivalsSoundAndQueueAdvanceAndHistoryStaySilent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var arrivals: [String] = []
        let hub = LocalNotificationHub(directory: root, onArrival: { arrivals.append($0.id) })
        _ = await hub.receive(event("small"))
        _ = await hub.receive(event("large"))
        _ = await hub.receive(event("queued-small"))
        _ = await hub.receive(event("small")) // Duplicate IDs never chime again.
        XCTAssertEqual(arrivals, ["small", "large", "queued-small"])
        hub.dismiss(); hub.dismiss(); hub.dismiss()
        await hub.markRead()
        await hub.load()
        XCTAssertEqual(arrivals.count, 3)
        let restored = LocalNotificationHub(directory: root, onArrival: { _ in XCTFail("History must stay silent") })
        await restored.load()
        _ = await restored.receive(event("small"))
        XCTAssertNil(restored.current)
        XCTAssertEqual(restored.history.count, 3)
    }

    func testSuspendedOverflowAndFailedStorageNeverSound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        let hub = LocalNotificationHub(directory: root, onArrival: { _ in count += 1 })
        hub.setSuspended(true)
        _ = await hub.receive(event("asleep"))
        XCTAssertEqual(count, 0)
        hub.setSuspended(false)
        for index in 0..<34 { _ = await hub.receive(event("burst-\(index)")) }
        XCTAssertEqual(count, 33)
        hub.setSuspended(true)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("synthetic".utf8).write(to: blocked)
        let failing = LocalNotificationHub(directory: blocked, onArrival: { _ in XCTFail("Unsaved event must stay silent") })
        let accepted = await failing.receive(event("failure"))
        XCTAssertFalse(accepted)
    }

    func testAvailableChoicesLoadWithoutPlayingAudio() throws {
        XCTAssertNil(NotificationSound.none.fileURL)
        for sound in NotificationSound.allCases where sound != .none {
            let url = try XCTUnwrap(sound.fileURL)
            XCTAssertNotNil(NSSound(contentsOf: url, byReference: true), "Missing system sound: \(sound.title)")
        }
    }
}
