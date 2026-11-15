import AppKit
import XCTest
@testable import Sidekey

/// Deleting one clipboard history entry: the store removes exactly that row
/// and its image sidecar, leaves nothing readable in the database files, and
/// the History flow asks first and reports failures.
/// WHY: .project-docs/decisions/2026-10-22-clipboard-entry-delete.md
final class ClipboardEntryDeletionStoreTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    // MARK: - Text

    /// Break caught: the delete hits a neighbouring row, or the deleted text
    /// still appears in the History feed.
    func testDeletingTextRemovesOnlyThatEntry() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let assets = makeTempDir()
        let older = try store.insertClipboardTextEntry(createdAt: date(1), text: "keep older")
        let secret = try store.insertClipboardTextEntry(createdAt: date(2), text: "-----BEGIN PRIVATE KEY-----")
        let newer = try store.insertClipboardTextEntry(createdAt: date(3), text: "keep newer")

        XCTAssertTrue(try store.deleteClipboardEntry(id: secret, assetsDirectory: assets))

        let remaining = try store.latestClipboardEntries(limit: 50)
        XCTAssertEqual(remaining.map(\.id), [newer, older])
        XCTAssertEqual(HistoryStripFeed(store: store).cards(for: .clipboard).map(\.id),
                       ["clipboard-\(newer)", "clipboard-\(older)"])
    }

    // MARK: - Image

    /// Break caught: the full-size image survives on disk after its row is
    /// gone, or another entry's image is removed with it.
    func testDeletingImageRemovesItsSidecarAndKeepsOtherImages() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let assets = makeTempDir()
        let deletedUUID = UUID()
        let keptUUID = UUID()
        let deleted = try insertImage(store, uuid: deletedUUID, at: 1, assets: assets)
        let kept = try insertImage(store, uuid: keptUUID, at: 2, assets: assets)
        let deletedSidecar = assets.appendingPathComponent("\(deletedUUID.uuidString).png")
        let keptSidecar = assets.appendingPathComponent("\(keptUUID.uuidString).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletedSidecar.path))

        XCTAssertTrue(try store.deleteClipboardEntry(id: deleted, assetsDirectory: assets))

        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedSidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptSidecar.path))
        XCTAssertEqual(try store.latestClipboardEntries(limit: 50).map(\.id), [kept])
    }

    /// Break caught: an image whose sidecar was already removed (cap race,
    /// manual cleanup) can never be deleted from the list.
    func testDeletingImageWithMissingSidecarStillRemovesTheRow() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let assets = makeTempDir()
        let uuid = UUID()
        let id = try insertImage(store, uuid: uuid, at: 1, assets: assets)
        try FileManager.default.removeItem(at: assets.appendingPathComponent("\(uuid.uuidString).png"))

        XCTAssertTrue(try store.deleteClipboardEntry(id: id, assetsDirectory: assets))
        XCTAssertTrue(try store.latestClipboardEntries(limit: 50).isEmpty)
    }

    /// Break caught: a sidecar that cannot be removed leaves an unlisted
    /// copy on disk while the row disappears. The row must stay for a retry.
    func testSidecarThatCannotBeRemovedKeepsTheRow() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let assets = makeTempDir()
        let uuid = UUID()
        let id = try insertImage(store, uuid: uuid, at: 1, assets: assets)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: assets.path)

        XCTAssertThrowsError(try store.deleteClipboardEntry(id: id, assetsDirectory: assets))

        XCTAssertEqual(try store.latestClipboardEntries(limit: 50).map(\.id), [id])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: assets.appendingPathComponent("\(uuid.uuidString).png").path))
    }

    // MARK: - File URLs

    /// Break caught: deleting a copied file list touches the files it names.
    func testDeletingFileURLsRemovesRowAndLeavesTheFiles() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let assets = makeTempDir()
        let folder = makeTempDir()
        let file = folder.appendingPathComponent("report.txt")
        try Data("contents".utf8).write(to: file)
        let id = try store.insertClipboardFileURLsEntry(createdAt: date(1), urls: [file])

        XCTAssertTrue(try store.deleteClipboardEntry(id: id, assetsDirectory: assets))

        XCTAssertTrue(try store.latestClipboardEntries(limit: 50).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("contents".utf8))
    }

    // MARK: - Already gone

    /// Break caught: deleting an entry the cap already evicted (the list was
    /// stale) throws or deletes something else.
    func testDeletingAnEvictedOrAlreadyDeletedIdReturnsFalse() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let assets = makeTempDir()
        let evicted = try store.insertClipboardTextEntry(createdAt: date(1), text: "oldest")
        let second = try store.insertClipboardTextEntry(createdAt: date(2), text: "second")
        let third = try store.insertClipboardTextEntry(createdAt: date(3), text: "third")
        try store.enforceClipboardCap(maxRows: 2, assetsDirectory: assets)

        XCTAssertFalse(try store.deleteClipboardEntry(id: evicted, assetsDirectory: assets))
        XCTAssertTrue(try store.deleteClipboardEntry(id: second, assetsDirectory: assets))
        XCTAssertFalse(try store.deleteClipboardEntry(id: second, assetsDirectory: assets))
        XCTAssertEqual(try store.latestClipboardEntries(limit: 50).map(\.id), [third])
    }

    // MARK: - On-disk bytes

    /// Break caught: the row disappears from the list but the copied secret
    /// is still readable in the database's free pages or its WAL.
    func testDeletedTextIsNotLeftInTheDatabaseFiles() throws {
        let root = makeTempDir()
        let dbURL = root.appendingPathComponent("history.sqlite")
        let marker = "whytap-delete-marker-\(UUID().uuidString)"
        let store = try SQLiteHistoryStore(path: dbURL.path)
        for index in 0..<10 {
            try store.insertClipboardTextEntry(createdAt: date(Double(index)), text: "neighbour \(index)")
        }
        let id = try store.insertClipboardTextEntry(createdAt: date(20), text: marker)
        try store.insertClipboardTextEntry(createdAt: date(21), text: "newer neighbour")
        XCTAssertTrue(try databaseFiles(at: dbURL).contains(Data(marker.utf8)),
                      "precondition: the marker must be detectable before deletion")

        XCTAssertTrue(try store.deleteClipboardEntry(id: id, assetsDirectory: root))

        XCTAssertFalse(try databaseFiles(at: dbURL).contains(Data(marker.utf8)))
        XCTAssertEqual(try store.latestClipboardEntries(limit: 50).count, 11)
        // The connection keeps working normally afterwards.
        try store.insertClipboardTextEntry(createdAt: date(30), text: "after delete")
        XCTAssertEqual(try store.latestClipboardEntries(limit: 1).first.map(\.id).map { $0 > id }, true)
    }

    // MARK: - Helpers

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000 + seconds)
    }

    @discardableResult
    private func insertImage(_ store: SQLiteHistoryStore, uuid: UUID, at seconds: TimeInterval, assets: URL) throws -> Int64 {
        try store.insertClipboardImageEntry(
            createdAt: date(seconds),
            uuid: uuid,
            imageData: Data(repeating: 0xAB, count: 512),
            imageExtension: "png",
            thumbnailData: Data(repeating: 0xCD, count: 32),
            assetsDirectory: assets
        )
    }

    private func databaseFiles(at dbURL: URL) throws -> Data {
        var bytes = try Data(contentsOf: dbURL)
        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        if let walBytes = try? Data(contentsOf: wal) { bytes.append(walBytes) }
        return bytes
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whytap-clipboard-delete-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }
}

/// The History Delete… flow: ask without quoting the copy, delete only after
/// a yes, and say so when it did not work.
@MainActor
final class ClipboardEntryDeletionFlowTests: XCTestCase {
    final class Calls {
        var confirmed: [ClipboardHistoryEntryPayload] = []
        var failures = 0
    }

    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        try await super.tearDown()
    }

    /// Break caught: the row is deleted although the user chose Cancel.
    func testCancelKeepsTheEntry() async throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let id = try store.insertClipboardTextEntry(createdAt: Date(), text: "secret")
        let calls = Calls()

        let target = try card(store, id)

        let outcome = await deletion(store, answer: false, calls: calls).delete(target)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(outcome.removesEntry)
        XCTAssertEqual(calls.confirmed, [.text("secret")])
        XCTAssertEqual(try store.latestClipboardEntries(limit: 50).map(\.id), [id])
    }

    /// Break caught: a confirmed delete leaves the row, or reports a failure.
    func testConfirmedDeleteRemovesTheEntry() async throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let id = try store.insertClipboardTextEntry(createdAt: Date(), text: "secret")
        let calls = Calls()

        let target = try card(store, id)

        let outcome = await deletion(store, answer: true, calls: calls).delete(target)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertTrue(outcome.removesEntry)
        XCTAssertEqual(calls.failures, 0)
        XCTAssertTrue(try store.latestClipboardEntries(limit: 50).isEmpty)
    }

    /// Break caught: a stale row (already evicted) shows an error instead of
    /// simply disappearing from the list.
    func testEntryEvictedBeforeConfirmationIsTreatedAsRemoved() async throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let id = try store.insertClipboardTextEntry(createdAt: Date(), text: "old")
        let staleCard = try card(store, id)
        XCTAssertTrue(try store.deleteClipboardEntry(id: id, assetsDirectory: makeTempDir()))
        let calls = Calls()

        let outcome = await deletion(store, answer: true, calls: calls).delete(staleCard)

        XCTAssertEqual(outcome, .alreadyGone)
        XCTAssertTrue(outcome.removesEntry)
        XCTAssertEqual(calls.failures, 0)
    }

    /// Break caught: a failed delete is silent, so the user believes the
    /// secret is gone while it is still listed.
    func testFailureIsReportedAndTheEntryStays() async throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let assets = makeTempDir()
        let id = try store.insertClipboardImageEntry(
            createdAt: Date(), uuid: UUID(), imageData: Data([1, 2, 3]),
            imageExtension: "png", thumbnailData: Data([4]), assetsDirectory: assets
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: assets.path)
        let calls = Calls()

        let target = try card(store, id)

        let outcome = await deletion(store, assets: assets, answer: true, calls: calls).delete(target)

        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(outcome.removesEntry)
        XCTAssertEqual(calls.failures, 1)
        XCTAssertEqual(try store.latestClipboardEntries(limit: 50).map(\.id), [id])
    }

    /// Break caught: Agent or Drop rows reach the clipboard delete path.
    func testNonClipboardCardsAreNotDeletedOrConfirmed() async throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let calls = Calls()
        let drop = HistoryStripCard.drop(.init(id: 1, createdAt: Date(), formattedText: "x", targetApp: nil))

        let outcome = await deletion(store, answer: true, calls: calls).delete(drop)

        XCTAssertEqual(outcome, .notClipboard)
        XCTAssertTrue(calls.confirmed.isEmpty)
    }

    // MARK: - Alert

    /// Break caught: Delete becomes the default/first button, or the alert
    /// quotes the copied secret on screen.
    func testConfirmationDefaultsToCancelAndNeverQuotesTheCopy() {
        let alert = ClipboardEntryDeletionAlerts.makeConfirmation(for: .text("SECRET-VALUE"))

        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Delete"])
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
        // Escape cancels; no key (Return included) can choose Delete.
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\u{1b}")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertFalse(alert.messageText.contains("SECRET-VALUE"))
        XCTAssertFalse(alert.informativeText.contains("SECRET-VALUE"))
        XCTAssertTrue(alert.informativeText.contains("Backups already uploaded are not changed"))
    }

    /// Break caught: the file-list question implies the files are deleted.
    func testFileListConfirmationSaysTheFilesStay() {
        let alert = ClipboardEntryDeletionAlerts.makeConfirmation(
            for: .fileURLs([URL(fileURLWithPath: "/tmp/a.txt")]))

        XCTAssertEqual(alert.messageText, "Delete this copied file list?")
        XCTAssertTrue(alert.informativeText.contains("The files themselves are not touched."))
    }

    // MARK: - Helpers

    private func deletion(
        _ store: SQLiteHistoryStore,
        assets: URL? = nil,
        answer: Bool,
        calls: Calls
    ) -> ClipboardEntryDeletion {
        ClipboardEntryDeletion(
            store: store,
            assetsDirectory: assets ?? makeTempDir(),
            prompts: ClipboardEntryDeletionPrompts(
                confirm: { payload in
                    calls.confirmed.append(payload)
                    return answer
                },
                reportFailure: { calls.failures += 1 }
            )
        )
    }

    private func card(_ store: SQLiteHistoryStore, _ id: Int64) throws -> HistoryStripCard {
        let entry = try XCTUnwrap(store.latestClipboardEntries(limit: 50).first { $0.id == id })
        return .clipboard(.init(id: entry.id, createdAt: entry.createdAt, payload: entry.payload))
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whytap-clipboard-delete-flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }
}
