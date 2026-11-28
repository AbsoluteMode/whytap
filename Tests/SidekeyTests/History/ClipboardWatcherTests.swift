import AppKit
import XCTest
@testable import Sidekey

/// Tests for `ClipboardWatcher`'s classification logic. The poller itself
/// (NSPasteboard.changeCount) is exercised only at the unit-of-classify
/// level — full integration with the system pasteboard is verified
/// manually because XCTest cannot deterministically race against the OS
/// pasteboard.
@MainActor
final class ClipboardWatcherTests: XCTestCase {
    private func makeStore() throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(path: ":memory:")
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-watcher-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - classify

    func testClassifyPlainTextReturnsTextKind() {
        let snapshot = ClipboardWatcher.PasteboardSnapshotInput(
            text: "hello world",
            tiffData: nil,
            pngData: nil,
            fileURLs: []
        )
        let kind = ClipboardWatcher.classify(snapshot)
        guard case .text(let s) = kind else {
            XCTFail("expected text, got \(String(describing: kind))")
            return
        }
        XCTAssertEqual(s, "hello world")
    }

    func testClassifyEmptyTextReturnsNil() {
        let snapshot = ClipboardWatcher.PasteboardSnapshotInput(
            text: "",
            tiffData: nil,
            pngData: nil,
            fileURLs: []
        )
        XCTAssertNil(ClipboardWatcher.classify(snapshot))
    }

    func testClassifyWhitespaceTextReturnsNil() {
        let snapshot = ClipboardWatcher.PasteboardSnapshotInput(
            text: "   \n\t  ",
            tiffData: nil,
            pngData: nil,
            fileURLs: []
        )
        XCTAssertNil(ClipboardWatcher.classify(snapshot))
    }

    func testClassifyPNGDataReturnsImageKind() {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let snapshot = ClipboardWatcher.PasteboardSnapshotInput(
            text: nil,
            tiffData: nil,
            pngData: pngBytes,
            fileURLs: []
        )
        let kind = ClipboardWatcher.classify(snapshot)
        guard case .image(let bytes, let ext) = kind else {
            XCTFail("expected image, got \(String(describing: kind))")
            return
        }
        XCTAssertEqual(bytes, pngBytes)
        XCTAssertEqual(ext, "png")
    }

    func testClassifyTIFFOnlyConvertsToTIFFKind() {
        let tiffBytes = Data([0x4D, 0x4D, 0x00, 0x2A])  // TIFF big-endian magic
        let snapshot = ClipboardWatcher.PasteboardSnapshotInput(
            text: nil,
            tiffData: tiffBytes,
            pngData: nil,
            fileURLs: []
        )
        let kind = ClipboardWatcher.classify(snapshot)
        guard case .image(_, let ext) = kind else {
            XCTFail("expected image, got \(String(describing: kind))")
            return
        }
        // Watcher prefers PNG bytes when both are available, falls back to
        // TIFF otherwise.
        XCTAssertEqual(ext, "tiff")
    }

    func testClassifyFileURLsReturnsFileURLsKind() {
        let urls = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.txt")]
        let snapshot = ClipboardWatcher.PasteboardSnapshotInput(
            text: nil,
            tiffData: nil,
            pngData: nil,
            fileURLs: urls
        )
        let kind = ClipboardWatcher.classify(snapshot)
        guard case .fileURLs(let returned) = kind else {
            XCTFail("expected fileURLs, got \(String(describing: kind))")
            return
        }
        XCTAssertEqual(returned, urls)
    }

    /// Priority is image > fileURLs > text — when multiple types are
    /// present on a single pasteboard event (Finder copy of an image
    /// produces both image and fileURL, plus a filename string), pick
    /// the richest content.
    func testClassifyPriorityImageOverFileURLsOverText() {
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let urls = [URL(fileURLWithPath: "/tmp/a.png")]
        let snapshot = ClipboardWatcher.PasteboardSnapshotInput(
            text: "a.png",
            tiffData: nil,
            pngData: imageBytes,
            fileURLs: urls
        )
        let kind = ClipboardWatcher.classify(snapshot)
        guard case .image = kind else {
            XCTFail("expected image to win priority, got \(String(describing: kind))")
            return
        }
    }

    func testClassifyFileURLsBeatsText() {
        let urls = [URL(fileURLWithPath: "/tmp/a.txt")]
        let snapshot = ClipboardWatcher.PasteboardSnapshotInput(
            text: "/tmp/a.txt",
            tiffData: nil,
            pngData: nil,
            fileURLs: urls
        )
        let kind = ClipboardWatcher.classify(snapshot)
        guard case .fileURLs = kind else {
            XCTFail("expected fileURLs, got \(String(describing: kind))")
            return
        }
    }

    // MARK: - Suppression

    func testPollSkipsCaptureWhenSuppressionFlagIsSet() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let suppression = ClipboardSuppression()
        suppression.setSuppressed(true)

        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date(timeIntervalSince1970: 1_000) }
        )
        watcher.handleChange(
            snapshot: .init(text: "should be ignored", tiffData: nil, pngData: nil, fileURLs: []),
            changeCount: 1
        )

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertTrue(entries.isEmpty, "suppression flag must block capture")
    }

    /// A Drop restore finishing (its own hold raised and released) while
    /// another owner still holds suppression must not let the watcher record
    /// that owner's writes; once the last hold is released, a real copy is
    /// recorded again.
    func testAnotherOwnerReleasingItsHoldDoesNotLiftSuppression() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }
        let store = try makeStore()
        let suppression = ClipboardSuppression()
        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date(timeIntervalSince1970: 1_000) }
        )
        suppression.setSuppressed(true)      // selection fallback's Cmd+C dance
        suppression.setSuppressed(true)      // a Drop restore starts...
        suppression.setSuppressed(false)     // ...and finishes
        watcher.handleChange(
            snapshot: .init(text: "synthetic copy", tiffData: nil, pngData: nil, fileURLs: []),
            changeCount: 1
        )
        XCTAssertTrue(try store.latestClipboardEntries(limit: 10).isEmpty,
                      "the dance's own write stays out of history while its hold is held")
        suppression.setSuppressed(false)     // the dance releases its hold
        suppression.setSuppressed(false)     // an extra release is ignored
        XCTAssertFalse(suppression.isSuppressed)
        watcher.handleChange(
            snapshot: .init(text: "user copy", tiffData: nil, pngData: nil, fileURLs: []),
            changeCount: 2
        )
        XCTAssertEqual(try store.latestClipboardEntries(limit: 10).count, 1)
        suppression.setSuppressed(true)
        XCTAssertTrue(suppression.isSuppressed, "a release without a hold never goes negative")
    }

    /// Race protection: even after the suppression flag is cleared, any
    /// pasteboard `changeCount` <= the recorded "skip-through" threshold
    /// MUST be skipped. This guards the window between the drop
    /// pipeline's `setSuppressed(false)` and the next 500 ms poll. The
    /// poll might see one or more changeCount bumps caused by drop
    /// itself (write + restore) that landed entirely between two poll
    /// ticks; without the threshold those bumps would be classified as
    /// fresh user copies and inserted as Sidekey artifacts.
    func testHandleChangeSkipsWhenChangeCountAtOrBelowSuppressionThreshold() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let suppression = ClipboardSuppression()
        // Drop pipeline completed: flag cleared, but it raised the
        // skip-through threshold to changeCount 5 (write at 4, restore
        // at 5). The watcher had `lastSeen = 2` from its last
        // observation before the drop started.
        suppression.setSuppressed(false)
        suppression.suppressThrough(changeCount: 5)

        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date(timeIntervalSince1970: 1_000) }
        )
        // The first poll after drop sees changeCount = 5 (the restored
        // snapshot bumped it twice from baseline). Must NOT insert.
        watcher.handleChange(
            snapshot: .init(text: "user-original-clipboard", tiffData: nil, pngData: nil, fileURLs: []),
            changeCount: 5
        )

        XCTAssertTrue(
            try store.latestClipboardEntries(limit: 10).isEmpty,
            "changeCount <= suppressThrough threshold must not produce a clipboard entry"
        )
    }

    /// Once the user does a genuine copy AFTER the threshold, the
    /// watcher must resume capture. Threshold = 5 → user copy bumps
    /// changeCount to 6 → must classify and insert.
    func testHandleChangeCapturesWhenChangeCountExceedsSuppressionThreshold() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let suppression = ClipboardSuppression()
        suppression.setSuppressed(false)
        suppression.suppressThrough(changeCount: 5)

        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date(timeIntervalSince1970: 1_000) }
        )
        watcher.handleChange(
            snapshot: .init(text: "real user copy", tiffData: nil, pngData: nil, fileURLs: []),
            changeCount: 6
        )

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1, "post-threshold copies must be recorded")
        guard case .text(let s) = entries.first?.payload else {
            XCTFail("expected text payload")
            return
        }
        XCTAssertEqual(s, "real user copy")
    }

    /// The threshold must be monotonic — calling `suppressThrough` with a
    /// lower value than already recorded must NOT rewind the threshold.
    /// Otherwise a second drop completing before its restore could lower
    /// the threshold under a previous drop's restored changeCount.
    func testSuppressionThresholdIsMonotonic() {
        let suppression = ClipboardSuppression()
        suppression.suppressThrough(changeCount: 10)
        suppression.suppressThrough(changeCount: 5)
        XCTAssertEqual(
            suppression.skipThroughChangeCount,
            10,
            "threshold must never rewind"
        )
        suppression.suppressThrough(changeCount: 15)
        XCTAssertEqual(
            suppression.skipThroughChangeCount,
            15,
            "threshold must advance when given a higher value"
        )
    }

    /// While the suppression flag is set, the watcher must skip
    /// regardless of the threshold. Flag wins — threshold is a
    /// secondary guard for the post-flag-clearing race window.
    func testFlagOverridesThresholdWhenBothPresent() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let suppression = ClipboardSuppression()
        suppression.setSuppressed(true)
        // threshold left at default (-1) — flag must still suppress.
        XCTAssertEqual(suppression.skipThroughChangeCount, -1)

        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date(timeIntervalSince1970: 1_000) }
        )
        watcher.handleChange(
            snapshot: .init(text: "ignored", tiffData: nil, pngData: nil, fileURLs: []),
            changeCount: 9_999
        )
        XCTAssertTrue(try store.latestClipboardEntries(limit: 10).isEmpty)
    }

    // MARK: - Insert flow

    func testHandleChangeInsertsTextEntry() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let suppression = ClipboardSuppression()

        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date(timeIntervalSince1970: 2_000) }
        )
        watcher.handleChange(
            snapshot: .init(text: "captured", tiffData: nil, pngData: nil, fileURLs: []),
            changeCount: 1
        )

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        guard case .text(let s) = entries.first?.payload else {
            XCTFail("expected text")
            return
        }
        XCTAssertEqual(s, "captured")
    }

    func testHandleChangeDeduplicatesSameChangeCount() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let suppression = ClipboardSuppression()

        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date(timeIntervalSince1970: 3_000) }
        )
        let snapshot = ClipboardWatcher.PasteboardSnapshotInput(
            text: "once",
            tiffData: nil,
            pngData: nil,
            fileURLs: []
        )
        watcher.handleChange(snapshot: snapshot, changeCount: 7)
        watcher.handleChange(snapshot: snapshot, changeCount: 7)
        watcher.handleChange(snapshot: snapshot, changeCount: 7)

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1, "same changeCount must not produce duplicates")
    }

    func testHandleChangeInsertsImageEntry() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let suppression = ClipboardSuppression()

        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date(timeIntervalSince1970: 4_000) }
        )
        let pngBytes = ClipboardWatcherTests.makeSimplePNG()
        watcher.handleChange(
            snapshot: .init(text: nil, tiffData: nil, pngData: pngBytes, fileURLs: []),
            changeCount: 1
        )

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        guard case .image(let payload) = entries.first?.payload else {
            XCTFail("expected image")
            return
        }
        XCTAssertEqual(payload.fileExtension, "png")
        XCTAssertFalse(payload.thumbnailData.isEmpty)

        let sidecar = payload.sidecarURL(in: assetsDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testHandleChangeInsertsFileURLsEntry() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let suppression = ClipboardSuppression()

        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date(timeIntervalSince1970: 5_000) }
        )
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        watcher.handleChange(
            snapshot: .init(text: nil, tiffData: nil, pngData: nil, fileURLs: urls),
            changeCount: 1
        )

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        guard case .fileURLs(let returned) = entries.first?.payload else {
            XCTFail("expected fileURLs")
            return
        }
        XCTAssertEqual(returned, urls)
    }

    func testHandleChangeEnforcesCapAfterInsert() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let suppression = ClipboardSuppression()

        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: suppression,
            clock: { Date() },
            maxEntries: 2
        )
        watcher.handleChange(snapshot: .init(text: "a", tiffData: nil, pngData: nil, fileURLs: []), changeCount: 1)
        watcher.handleChange(snapshot: .init(text: "b", tiffData: nil, pngData: nil, fileURLs: []), changeCount: 2)
        watcher.handleChange(snapshot: .init(text: "c", tiffData: nil, pngData: nil, fileURLs: []), changeCount: 3)

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 2, "max=2 cap must evict oldest")
        // newest = "c" first
        let texts = entries.compactMap { entry -> String? in
            if case .text(let s) = entry.payload { return s }
            return nil
        }
        XCTAssertEqual(texts, ["c", "b"])
    }

    // MARK: - Exclusion markers

    private static let markerSets: [Set<ClipboardWatcher.ExclusionMarker>] = [
        [.concealed], [.transient], [.concealed, .transient], [.autoGenerated],
    ]

    private static func payloads(at dir: URL) -> [ClipboardWatcher.PasteboardSnapshotInput] {
        [
            .init(text: "secret-text", tiffData: nil, pngData: nil, fileURLs: []),
            .init(text: nil, tiffData: nil, pngData: makeSimplePNG(), fileURLs: []),
            .init(text: nil, tiffData: Data([0x4D, 0x4D, 0x00, 0x2A]), pngData: nil, fileURLs: []),
            .init(text: "secret.key", tiffData: nil, pngData: nil, fileURLs: [dir.appendingPathComponent("secret.key")]),
        ]
    }

    private static func marked(
        _ snapshot: ClipboardWatcher.PasteboardSnapshotInput,
        _ markers: Set<ClipboardWatcher.ExclusionMarker>
    ) -> ClipboardWatcher.PasteboardSnapshotInput {
        var copy = snapshot
        copy.exclusionMarkers = markers
        return copy
    }

    func testClassifyNeverReturnsAMarkedPayload() {
        for markers in Self.markerSets {
            for payload in Self.payloads(at: URL(fileURLWithPath: "/tmp")) {
                XCTAssertNotNil(ClipboardWatcher.classify(payload))
                XCTAssertNil(ClipboardWatcher.classify(Self.marked(payload, markers)), "\(markers)")
            }
        }
    }

    /// Concealed, transient, both and auto-generated changes write no row
    /// and no image sidecar, whatever their payload.
    func testHandleChangeStoresNothingForMarkedChanges() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }
        let store = try makeStore()
        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: ClipboardSuppression(),
            clock: { Date(timeIntervalSince1970: 6_000) }
        )
        var changeCount = 100
        for markers in Self.markerSets {
            for payload in Self.payloads(at: assetsDir) {
                changeCount += 1
                watcher.handleChange(snapshot: Self.marked(payload, markers), changeCount: changeCount)
            }
        }

        XCTAssertTrue(try store.latestClipboardEntries(limit: 100).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: assetsDir.path), [])
    }

    /// A skipped change still counts as seen: replaying it does not record
    /// its payload, while the next ordinary copy is recorded.
    func testMarkedChangeAdvancesLastSeenChangeCount() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }
        let store = try makeStore()
        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: ClipboardSuppression(),
            clock: { Date(timeIntervalSince1970: 7_000) }
        )
        let secret = ClipboardWatcher.PasteboardSnapshotInput(text: "secret", tiffData: nil, pngData: nil, fileURLs: [])

        watcher.handleChange(snapshot: Self.marked(secret, [.concealed]), changeCount: 41)
        watcher.handleChange(snapshot: secret, changeCount: 41)
        XCTAssertTrue(try store.latestClipboardEntries(limit: 10).isEmpty)

        watcher.handleChange(
            snapshot: .init(text: "ordinary", tiffData: nil, pngData: nil, fileURLs: []),
            changeCount: 42
        )
        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        guard case .text(let s) = entries.first?.payload else {
            XCTFail("expected text")
            return
        }
        XCTAssertEqual(s, "ordinary")
    }

    // MARK: - readSnapshot on isolated pasteboards

    private func withBoard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try body(board)
    }

    func testReadSnapshotReportsMarkersWithoutReadingThePayload() {
        for markers in Self.markerSets {
            withBoard { board in
                board.clearContents()
                let item = NSPasteboardItem()
                item.setString("secret", forType: .string)
                item.setData(Self.makeSimplePNG(), forType: .png)
                for marker in markers {
                    item.setData(Data(), forType: marker.pasteboardType)
                }
                board.writeObjects([item])

                XCTAssertEqual(
                    ClipboardWatcher.readSnapshot(from: board),
                    .init(text: nil, tiffData: nil, pngData: nil, fileURLs: [], exclusionMarkers: markers)
                )
            }
        }
    }

    /// One marked item excludes the whole change, even when it is not the
    /// first item.
    func testReadSnapshotHonoursAMarkerOnALaterItem() {
        withBoard { board in
            board.clearContents()
            let plain = NSPasteboardItem()
            plain.setString("visible", forType: .string)
            let concealed = NSPasteboardItem()
            concealed.setString("secret", forType: .string)
            concealed.setData(Data(), forType: ClipboardWatcher.ExclusionMarker.concealed.pasteboardType)
            board.writeObjects([plain, concealed])

            let snapshot = ClipboardWatcher.readSnapshot(from: board)
            XCTAssertEqual(snapshot.exclusionMarkers, [.concealed])
            XCTAssertNil(snapshot.text)
        }
    }

    func testUnmarkedTextImageAndFileCopiesAreRecordedFromThePasteboard() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }
        let store = try makeStore()
        let watcher = ClipboardWatcher(
            store: store,
            assetsDirectory: assetsDir,
            suppression: ClipboardSuppression(),
            clock: { Date(timeIntervalSince1970: 8_000) }
        )
        let fileURL = assetsDir.appendingPathComponent("report.pdf")
        let writes: [(NSPasteboard) -> Void] = [
            { $0.setString("plain text", forType: .string) },
            { $0.setData(Self.makeSimplePNG(), forType: .png) },
            { $0.writeObjects([fileURL as NSURL]) },
        ]
        var changeCount = 200
        for write in writes {
            try withBoard { board in
                board.clearContents()
                write(board)
                let snapshot = ClipboardWatcher.readSnapshot(from: board)
                XCTAssertTrue(snapshot.exclusionMarkers.isEmpty)
                changeCount += 1
                watcher.handleChange(snapshot: snapshot, changeCount: changeCount)
            }
        }

        let payloads = try store.latestClipboardEntries(limit: 10).map(\.payload)
        XCTAssertEqual(payloads.count, 3)
        guard case .fileURLs(let urls) = payloads[0],
              case .image(let image) = payloads[1],
              case .text(let text) = payloads[2] else {
            XCTFail("expected fileURLs, image and text, newest first: \(payloads)")
            return
        }
        XCTAssertEqual(urls, [fileURL])
        XCTAssertEqual(image.fileExtension, "png")
        XCTAssertEqual(text, "plain text")
    }

    // MARK: - Helpers

    /// Generates a 1×1 PNG using NSImage / NSBitmapImageRep so the
    /// thumbnail generator and CGImageSource have something legal to
    /// parse. Pure-Swift Data-of-bytes won't pass NSImage(data:) when
    /// the thumbnailer tries to render.
    static func makeSimplePNG() -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            return Data()
        }
        return png
    }
}
