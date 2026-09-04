import XCTest
@testable import Sidekey

/// Tests for the clipboard-history extension on `SQLiteHistoryStore`.
/// Clipboard entries are richer than agent/drop rows — text, image, file
/// URLs — so they get their own table and their own enum payload.
final class ClipboardHistoryStoreTests: XCTestCase {
    private func makeStore() throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(path: ":memory:")
    }

    // MARK: - Text

    func testInsertTextEntryAssignsIdAndRoundtrips() throws {
        let store = try makeStore()
        let id = try store.insertClipboardTextEntry(
            createdAt: Date(timeIntervalSince1970: 1_000),
            text: "hello"
        )

        XCTAssertGreaterThan(id, 0)

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, id)
        XCTAssertEqual(entries.first?.createdAt, Date(timeIntervalSince1970: 1_000))
        guard case .text(let s) = entries.first?.payload else {
            XCTFail("expected .text, got \(String(describing: entries.first?.payload))")
            return
        }
        XCTAssertEqual(s, "hello")
    }

    func testLatestSortsNewestFirst() throws {
        let store = try makeStore()
        _ = try store.insertClipboardTextEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            text: "first"
        )
        _ = try store.insertClipboardTextEntry(
            createdAt: Date(timeIntervalSince1970: 3),
            text: "third"
        )
        _ = try store.insertClipboardTextEntry(
            createdAt: Date(timeIntervalSince1970: 2),
            text: "second"
        )

        let entries = try store.latestClipboardEntries(limit: 10)
        let texts = entries.compactMap { entry -> String? in
            if case .text(let s) = entry.payload { return s }
            return nil
        }
        XCTAssertEqual(texts, ["third", "second", "first"])
    }

    func testLatestRespectsLimit() throws {
        let store = try makeStore()
        for i in 0..<5 {
            _ = try store.insertClipboardTextEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                text: "t\(i)"
            )
        }
        let entries = try store.latestClipboardEntries(limit: 3)
        XCTAssertEqual(entries.count, 3)
    }

    // MARK: - File URLs

    func testInsertFileURLsEntryRoundtrips() throws {
        let store = try makeStore()
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.png")]
        let id = try store.insertClipboardFileURLsEntry(
            createdAt: Date(timeIntervalSince1970: 1_500),
            urls: urls
        )

        XCTAssertGreaterThan(id, 0)

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        guard case .fileURLs(let returned) = entries.first?.payload else {
            XCTFail("expected .fileURLs")
            return
        }
        XCTAssertEqual(returned, urls)
    }

    func testEmptyFileURLsIsRejected() {
        guard let store = try? makeStore() else {
            XCTFail("store init")
            return
        }
        XCTAssertThrowsError(
            try store.insertClipboardFileURLsEntry(
                createdAt: Date(),
                urls: []
            )
        )
    }

    // MARK: - Image

    func testInsertImageEntryWritesSidecarAndStoresThumbnail() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let imageData = Data(repeating: 0xAB, count: 1024)
        let thumb = Data(repeating: 0xCD, count: 64)
        let id = try store.insertClipboardImageEntry(
            createdAt: Date(timeIntervalSince1970: 2_000),
            uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            imageData: imageData,
            imageExtension: "png",
            thumbnailData: thumb,
            assetsDirectory: assetsDir
        )
        XCTAssertGreaterThan(id, 0)

        let sidecar = assetsDir.appendingPathComponent("11111111-1111-1111-1111-111111111111.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let onDisk = try Data(contentsOf: sidecar)
        XCTAssertEqual(onDisk, imageData)

        let entries = try store.latestClipboardEntries(limit: 1)
        guard case .image(let imageEntry) = entries.first?.payload else {
            XCTFail("expected .image")
            return
        }
        XCTAssertEqual(imageEntry.uuid.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(imageEntry.fileExtension, "png")
        XCTAssertEqual(imageEntry.thumbnailData, thumb)
    }

    // MARK: - Cap eviction (FIFO + sidecar cleanup)

    func testEnforceCapEvictsOldestAndDeletesImageSidecars() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()

        // Insert 3 images with distinct timestamps.
        let oldestUUID = UUID()
        _ = try store.insertClipboardImageEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            uuid: oldestUUID,
            imageData: Data([0x01]),
            imageExtension: "png",
            thumbnailData: Data([0xAA]),
            assetsDirectory: assetsDir
        )
        _ = try store.insertClipboardImageEntry(
            createdAt: Date(timeIntervalSince1970: 2),
            uuid: UUID(),
            imageData: Data([0x02]),
            imageExtension: "png",
            thumbnailData: Data([0xBB]),
            assetsDirectory: assetsDir
        )
        _ = try store.insertClipboardImageEntry(
            createdAt: Date(timeIntervalSince1970: 3),
            uuid: UUID(),
            imageData: Data([0x03]),
            imageExtension: "png",
            thumbnailData: Data([0xCC]),
            assetsDirectory: assetsDir
        )

        let oldestSidecar = assetsDir.appendingPathComponent("\(oldestUUID.uuidString).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldestSidecar.path))

        // Cap at 2 — oldest must be evicted, sidecar deleted.
        try store.enforceClipboardCap(maxRows: 2, assetsDirectory: assetsDir)

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldestSidecar.path),
            "oldest image sidecar should be deleted when entry is evicted"
        )
    }

    func testEnforceCapNoOpWhenUnderLimit() throws {
        let store = try makeStore()
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        _ = try store.insertClipboardTextEntry(createdAt: Date(timeIntervalSince1970: 1), text: "a")
        _ = try store.insertClipboardTextEntry(createdAt: Date(timeIntervalSince1970: 2), text: "b")
        try store.enforceClipboardCap(maxRows: 50, assetsDirectory: assetsDir)
        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 2)
    }

    // MARK: - File-backed persistence

    /// Storage-layer invariant only. `AppDelegate` calls
    /// `ClipboardHistoryLaunchPurge.run` on launch, so in production
    /// the rows are wiped before any reader observes them; see
    /// `ClipboardHistoryLaunchPurgeTests`.
    func testClipboardEntriesPersistAcrossReopen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-clipboard-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let store = try SQLiteHistoryStore(path: tmp.path)
            _ = try store.insertClipboardTextEntry(
                createdAt: Date(timeIntervalSince1970: 100),
                text: "persist me"
            )
        }

        let reopened = try SQLiteHistoryStore(path: tmp.path)
        let entries = try reopened.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        guard case .text(let t) = entries.first?.payload else {
            XCTFail("expected text payload")
            return
        }
        XCTAssertEqual(t, "persist me")
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-clipboard-assets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
