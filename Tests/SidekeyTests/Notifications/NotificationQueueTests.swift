import XCTest
@testable import Sidekey

@MainActor
final class NotificationQueueTests: XCTestCase {
    private func event(_ id: String, duration: TimeInterval = 2) -> LocalNotificationEvent {
        LocalNotificationEvent(id: id, source: "test", sourceName: "Test", title: "Event \(id)", body: "",
            link: URL(string: "codex://threads/\(id)"), timestamp: Date(), customDuration: duration, customLogo: "codex")
    }

    func testCardsKeepArrivalOrderIndividualLinksAndDuplicateProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        _ = await hub.receive(event("first")); _ = await hub.receive(event("second"))
        let duplicate = await hub.receive(event("second"))
        XCTAssertFalse(duplicate)
        XCTAssertEqual(hub.current?.id, "first")
        XCTAssertEqual(hub.current?.link?.absoluteString, "codex://threads/first")
        hub.dismiss(id: "second") // Queued cards cannot dismiss the visible card.
        XCTAssertEqual(hub.current?.id, "first")
        hub.dismiss()
        XCTAssertEqual(hub.current?.id, "second")
        hub.dismiss()
        XCTAssertNil(hub.current)
        XCTAssertEqual(hub.unreadCount, 2)
    }

    func testClearAllClearsQueueAndAttentionButKeepsNewDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        for index in 0..<40 { _ = await hub.receive(event("item-\(index)")) }
        XCTAssertEqual(hub.history.count, 40)
        var presented = 0
        while hub.current != nil { presented += 1; hub.dismiss() }
        XCTAssertEqual(presented, 33)
        _ = await hub.receive(event("preclear"))
        await hub.clear()
        XCTAssertNil(hub.current); XCTAssertNil(hub.deadline)
        XCTAssertEqual(hub.unreadCount, 0)
        let restored = LocalNotificationHub(directory: root); await restored.load()
        XCTAssertTrue(restored.history.isEmpty)
        _ = await hub.receive(event("fresh"))
        XCTAssertEqual(hub.current?.id, "fresh")
        XCTAssertEqual(hub.unreadCount, 1)
        hub.setSuspended(true)
        XCTAssertNil(hub.current)
        let unattended = LocalNotificationHub(directory: root); await unattended.load()
        XCTAssertEqual(unattended.unreadCount, 1)
        await unattended.markRead()
        XCTAssertEqual(unattended.unreadCount, 0)
    }

    func testHoverPausesExpiryAndNewCardsWaitTheirTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        // Half-second cards: the same rule as the default 2 s, a quarter of the wait.
        _ = await hub.receive(event("first", duration: 0.5)); hub.setHovered(true)
        _ = await hub.receive(event("second", duration: 0.5))
        try await Task.sleep(nanoseconds: 600_000_000) // longer than the card's own time
        XCTAssertEqual(hub.current?.id, "first")
        hub.setHovered(false)
        XCTAssertGreaterThan(hub.deadline?.timeIntervalSinceNow ?? 0, 0.4)
        // The expiry timer can fire late on a loaded Mac: wait for the turn, not a fixed time.
        let resumed = Date()
        while hub.current?.id != "second", Date().timeIntervalSince(resumed) < 30 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(hub.current?.id, "second")
        XCTAssertGreaterThan(Date().timeIntervalSince(resumed), 0.35, "the first card kept its remaining time")
        hub.setSuspended(true)
        XCTAssertEqual(hub.history.count, 2)
    }
}
