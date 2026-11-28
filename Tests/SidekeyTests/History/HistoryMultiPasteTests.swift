import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Scenarios for pasting several History rows without reopening History:
/// ⌘-click marks rows in order, Enter pastes them, Escape clears the marks.
@MainActor
final class HistoryMultiPasteTests: XCTestCase {
    private func fileCard(_ id: Int64, _ paths: String...) -> HistoryStripCard {
        .clipboard(.init(
            id: id,
            createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
            payload: .fileURLs(paths.map { URL(fileURLWithPath: $0) })
        ))
    }

    private func textCard(_ id: Int64, _ text: String) -> HistoryStripCard {
        .clipboard(.init(id: id, createdAt: Date(timeIntervalSince1970: TimeInterval(id)), payload: .text(text)))
    }

    private func dropCard(_ id: Int64, _ text: String) -> HistoryStripCard {
        .drop(.init(id: id, createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
                    formattedText: text, targetApp: "Notes"))
    }

    private func imageCard(_ id: Int64) -> HistoryStripCard {
        .clipboard(.init(
            id: id,
            createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
            payload: .image(.init(uuid: Self.imageUUID(id), fileExtension: "png", thumbnailData: Data()))
        ))
    }

    private static func imageUUID(_ id: Int64) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012lld", id))!
    }

    /// A simulated pasteboard and paste target on a virtual clock. The
    /// target reads the pasteboard `readDelayMs` after each Cmd+V, the way
    /// Chromium reads only when the page handles the paste event, and takes
    /// whatever is on the pasteboard at that moment: if the series replaced
    /// it already, the target pastes the wrong thing.
    private final class Recorder {
        var events: [String] = []
        var pasteResults: [Bool] = []
        /// Zero-based writes the pasteboard refuses, or that have nothing to paste.
        var failingWrites: Set<Int> = []
        var emptyWrites: Set<Int> = []
        private var writeIndex = 0
        var timing = HistoryPasteReadWaiter.Timing.standard

        private(set) var now: UInt64 = 0
        private(set) var changeCount = 0
        /// Label of what is on the pasteboard now.
        private(set) var content = "original"
        private var contentSignalsReads = false
        /// Target read delay after Cmd+V; nil = the target never reads.
        var readDelayMs: UInt64? = 30
        private var pendingReads: [UInt64] = []
        private(set) var reads = 0
        /// What the target pasted, in order.
        private(set) var received: [String] = []
        /// `received.count` when the user's clipboard came back.
        private(set) var receivedAtRestore: Int?
        /// A copy by the user at this virtual time.
        var userCopyAtMs: UInt64?
        /// Another app's copy lands while a refused write is in progress.
        var copyLandsDuringRefusedWrite = false
        /// Generations handed to `suppressOwn`, in order.
        private(set) var suppressed: [Int] = []

        static func label(_ group: HistoryPasteGroup) -> String {
            switch group {
            case .text(let t): return "text \(t.debugDescription)"
            case .attachments(let items):
                if items.count == 1, case .image(let image) = items[0] {
                    return "image \(Int(image.uuid.uuidString.suffix(12))!)"
                }
                return "\(items.count) attachments"
            }
        }

        private func advance(_ ms: UInt64) {
            now += ms
            if let at = userCopyAtMs, at <= now {
                userCopyAtMs = nil
                changeCount += 1
                content = "user copy"
                contentSignalsReads = false
            }
            while let next = pendingReads.first, next <= now {
                pendingReads.removeFirst()
                received.append(content)
                if contentSignalsReads { reads += 1 }
            }
        }

        func paster() -> HistoryMultiPaster {
            let waiter = HistoryPasteReadWaiter(
                readCount: { [unowned self] in reads },
                changeCount: { [unowned self] in changeCount },
                nowMs: { [unowned self] in now },
                sleepMs: { [unowned self] ms in advance(ms) },
                timing: timing
            )
            return HistoryMultiPaster(
                targetIsCurrent: { _ in true },
                write: { [unowned self] group in
                    events.append("write \(Self.label(group))")
                    defer { writeIndex += 1 }
                    if emptyWrites.contains(writeIndex) { return .nothing }
                    if failingWrites.contains(writeIndex) {
                        changeCount += 1   // the refused write cleared the pasteboard
                        content = ""
                        let cleared = changeCount
                        if copyLandsDuringRefusedWrite {
                            changeCount += 1
                            content = "other copy"
                        }
                        return .failed(clearedChangeCount: cleared)
                    }
                    changeCount += 1
                    content = Self.label(group)
                    let signals: Bool
                    if case .attachments(let items) = group, items.contains(where: {
                        if case .file = $0 { return true } else { return false }
                    }) {
                        signals = false
                    } else {
                        signals = true
                    }
                    contentSignalsReads = signals
                    return .written(.init(changeCount: changeCount, readsBefore: signals ? reads : nil))
                },
                paste: { [unowned self] _, _ in
                    events.append("cmd-v")
                    let ok = pasteResults.isEmpty ? true : pasteResults.removeFirst()
                    if ok, let delay = readDelayMs { pendingReads.append(now + delay) }
                    return ok
                },
                awaitConsumed: { [unowned self] receipt in
                    events.append("waited \(await waiter.wait(for: receipt))")
                },
                changeCount: { [unowned self] in changeCount },
                restore: { [unowned self] in
                    events.append("restore")
                    receivedAtRestore = received.count
                    changeCount += 1
                    content = "original"
                    contentSignalsReads = false
                },
                suppressOwn: { [unowned self] in suppressed.append($0) }
            )
        }
    }

    // MARK: - One row (unchanged behavior)

    func testEnterWithoutMarksPastesTheHoveredRowOnly() {
        let hovered = textCard(1, "hello")
        XCTAssertEqual(
            HistoryKeyDecision.action(keyCode: 36, hovered: hovered, selection: []),
            .paste([hovered])
        )
        XCTAssertEqual(
            HistoryKeyDecision.action(keyCode: 76, hovered: hovered, selection: []),
            .paste([hovered]),
            "Numpad Enter keeps working"
        )
    }

    func testOneRowIsOnePasteWrittenAsBefore() async {
        let recorder = Recorder()
        let groups = HistoryPastePlan.groups(for: [fileCard(1, "/tmp/a.pdf")])
        XCTAssertEqual(groups, [.attachments([.file(URL(fileURLWithPath: "/tmp/a.pdf"))])])
        let posted = await recorder.paster().run(groups)
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(recorder.events, ["write 1 attachments", "cmd-v", "waited gap", "restore"])
    }

    func testSingleRowPasteboardContentIsUnchanged() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HistoryMultiPasteTests.single.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let assets = FileManager.default.temporaryDirectory

        for group in HistoryPastePlan.groups(for: [textCard(1, "only text")]) {
            HistoryPasteboardWriter.write(group, to: pasteboard, assetsDirectory: assets)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "only text")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    // MARK: - Three files in a row

    func testThreeMarkedFilesArriveInOnePaste() async throws {
        let a = fileCard(1, "/tmp/a.pdf")
        let b = fileCard(2, "/tmp/b.png")
        let c = fileCard(3, "/tmp/c.zip")
        let selection = HistoryPasteSelection()
        selection.toggle(c)
        selection.toggle(a)
        selection.toggle(b)
        XCTAssertEqual(selection.position(of: c), 1, "Mark order, not list order")
        XCTAssertEqual(selection.position(of: a), 2)
        XCTAssertEqual(selection.position(of: b), 3)

        guard case .paste(let cards) = HistoryKeyDecision.action(
            keyCode: 36, hovered: a, selection: selection.cards
        ) else { return XCTFail("Enter must paste the marked rows") }
        XCTAssertEqual(cards, [c, a, b], "Marks win over the hovered row")

        let groups = HistoryPastePlan.groups(for: cards)
        XCTAssertEqual(groups, [.attachments([
            .file(URL(fileURLWithPath: "/tmp/c.zip")),
            .file(URL(fileURLWithPath: "/tmp/a.pdf")),
            .file(URL(fileURLWithPath: "/tmp/b.png")),
        ])])

        let recorder = Recorder()
        await recorder.paster().run(groups)
        XCTAssertEqual(recorder.events, ["write 3 attachments", "cmd-v", "waited gap", "restore"])

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HistoryMultiPasteTests.files.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        HistoryPasteboardWriter.write(try XCTUnwrap(groups.first), to: pasteboard,
                                      assetsDirectory: FileManager.default.temporaryDirectory)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(urls?.map(\.path), ["/tmp/c.zip", "/tmp/a.pdf", "/tmp/b.png"])
    }

    func testFileRowWithSeveralFilesKeepsAllOfThem() {
        let groups = HistoryPastePlan.groups(for: [fileCard(1, "/tmp/a", "/tmp/b"), fileCard(2, "/tmp/c")])
        XCTAssertEqual(groups, [.attachments([
            .file(URL(fileURLWithPath: "/tmp/a")),
            .file(URL(fileURLWithPath: "/tmp/b")),
            .file(URL(fileURLWithPath: "/tmp/c")),
        ])])
    }

    func testImagesNeverShareAPasteWithFilesOrOtherImages() {
        // A pasteboard that holds file URLs and an image gives Chromium the
        // files only; two image items give it the first image only.
        let groups = HistoryPastePlan.groups(for: [
            fileCard(1, "/tmp/a"), imageCard(2), imageCard(3), fileCard(4, "/tmp/b"), fileCard(5, "/tmp/c"),
        ])
        XCTAssertEqual(groups.map(Recorder.label), [
            "1 attachments", "image 2", "image 3", "2 attachments",
        ])
    }

    // MARK: - Text rows

    func testMarkedTextsArriveAsOnePasteOneLineEach() async {
        let groups = HistoryPastePlan.groups(for: [textCard(1, "first"), dropCard(2, "second")])
        XCTAssertEqual(groups, [.text("first\nsecond")])
        let recorder = Recorder()
        await recorder.paster().run(groups)
        XCTAssertEqual(recorder.events, ["write text \"first\\nsecond\"", "cmd-v", "waited read", "restore"])
    }

    // MARK: - Mixed text and files

    func testMixedRowsPasteInMarkOrderWithAGapBetweenPastes() async {
        let groups = HistoryPastePlan.groups(for: [
            textCard(1, "Invoice:"),
            fileCard(2, "/tmp/invoice.pdf"),
            fileCard(3, "/tmp/receipt.pdf"),
            dropCard(4, "Thanks"),
        ])
        XCTAssertEqual(groups, [
            .text("Invoice:"),
            .attachments([
                .file(URL(fileURLWithPath: "/tmp/invoice.pdf")),
                .file(URL(fileURLWithPath: "/tmp/receipt.pdf")),
            ]),
            .text("Thanks"),
        ])

        let recorder = Recorder()
        let posted = await recorder.paster().run(groups)
        XCTAssertEqual(posted, 3)
        XCTAssertEqual(recorder.events, [
            "write text \"Invoice:\"", "cmd-v", "waited read",
            "write 2 attachments", "cmd-v", "waited gap",
            "write text \"Thanks\"", "cmd-v", "waited read",
            "restore",
        ])
        XCTAssertEqual(recorder.received, ["text \"Invoice:\"", "2 attachments", "text \"Thanks\""])
    }

    func testFailedPasteStopsTheRestSoNothingLandsOutOfOrder() async {
        let recorder = Recorder()
        recorder.pasteResults = [true, false, true]
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: [
            textCard(1, "a"), fileCard(2, "/tmp/b"), textCard(3, "c"),
        ]))
        XCTAssertEqual(posted, 1)
        XCTAssertFalse(recorder.events.contains("write text \"c\""))
    }

    func testFailedPasteGivesTheClipboardBackWithoutWaiting() async {
        let recorder = Recorder()
        recorder.pasteResults = [true, false]
        await recorder.paster().run(HistoryPastePlan.groups(for: [textCard(1, "a"), imageCard(2), imageCard(3)]))
        XCTAssertEqual(recorder.events, [
            "write text \"a\"", "cmd-v", "waited read",
            "write image 2", "cmd-v", "restore",
        ], "The unposted image is not waited for; the user's clipboard comes back at once")
        XCTAssertEqual(recorder.content, "original")
    }

    // MARK: - Every marked item arrives (2026-11-28: the last image was lost)

    /// The maintainer's report: text, image, image marked 1, 2, 3, Enter;
    /// the target got the text and one image. The two images were one
    /// pasteboard with two image items, and the target read only the first.
    func testTextThenTwoImagesPastesAllThreeInBadgeOrder() async {
        let text = textCard(1, "Dictation, meeting notes and more for your Mac")
        let second = imageCard(2), third = imageCard(3)
        let selection = HistoryPasteSelection()
        [text, second, third].forEach(selection.toggle)
        guard case .paste(let cards) = HistoryKeyDecision.action(
            keyCode: 36, hovered: nil, selection: selection.cards
        ) else { return XCTFail("Enter must paste the marked rows") }

        let groups = HistoryPastePlan.groups(for: cards)
        XCTAssertEqual(groups.count, 3, "One Cmd+V per image")
        let recorder = Recorder()
        let posted = await recorder.paster().run(groups)

        XCTAssertEqual(posted, 3)
        XCTAssertEqual(recorder.received, [
            "text \"Dictation, meeting notes and more for your Mac\"", "image 2", "image 3",
        ])
        XCTAssertEqual(recorder.events.last, "restore")
        XCTAssertEqual(recorder.receivedAtRestore, 3, "The clipboard comes back only after the last image was read")
        XCTAssertEqual(recorder.content, "original")
    }

    func testImagesThenTextEndingWithTextPastesEverything() async {
        let recorder = Recorder()
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: [
            imageCard(1), imageCard(2), textCard(3, "caption"),
        ]))
        XCTAssertEqual(posted, 3)
        XCTAssertEqual(recorder.received, ["image 1", "image 2", "text \"caption\""])
        XCTAssertEqual(recorder.receivedAtRestore, 3)
    }

    func testTenMarkedItemsArriveInOrder() async {
        // Alternating kinds: no neighbours merge, ten pastes.
        let cards: [HistoryStripCard] = (1...10).map { id in
            id.isMultiple(of: 2) ? imageCard(Int64(id)) : textCard(Int64(id), "line \(id)")
        }
        let recorder = Recorder()
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: cards))
        XCTAssertEqual(posted, 10)
        XCTAssertEqual(recorder.received, (1...10).map { id in
            id.isMultiple(of: 2) ? "image \(id)" : "text \"line \(id)\""
        })
        XCTAssertEqual(recorder.receivedAtRestore, 10)
    }

    func testTenMarkedImagesAreTenPastes() async {
        let recorder = Recorder()
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: (1...10).map { imageCard(Int64($0)) }))
        XCTAssertEqual(posted, 10)
        XCTAssertEqual(recorder.received, (1...10).map { "image \($0)" })
    }

    func testSlowTargetGetsEveryItemAndTheClipboardWaitsForIt() async {
        // A busy Electron renderer reads 900 ms after Cmd+V, far later than
        // the former fixed 400 ms gap.
        let recorder = Recorder()
        recorder.readDelayMs = 900
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: [
            textCard(1, "a"), imageCard(2), imageCard(3),
        ]))
        XCTAssertEqual(posted, 3)
        XCTAssertEqual(recorder.received, ["text \"a\"", "image 2", "image 3"])
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("waited") }, Array(repeating: "waited read", count: 3))
        XCTAssertEqual(recorder.receivedAtRestore, 3)
        XCTAssertEqual(recorder.content, "original")
    }

    func testTargetThatNeverReadsStillGetsTheClipboardBackAfterTheFallback() async {
        let recorder = Recorder()
        recorder.readDelayMs = nil
        await recorder.paster().run(HistoryPastePlan.groups(for: [imageCard(1), imageCard(2)]))
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("waited") }, ["waited timeout", "waited timeout"])
        XCTAssertGreaterThanOrEqual(recorder.now, 2 * HistoryPasteReadWaiter.Timing.standard.fallbackMs)
        XCTAssertEqual(recorder.events.last, "restore")
        XCTAssertEqual(recorder.content, "original")
    }

    func testUserCopyDuringTheSeriesStaysAndStopsTheRest() async {
        let recorder = Recorder()
        recorder.readDelayMs = 300
        recorder.userCopyAtMs = 100   // before the target read the first image
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: [
            imageCard(1), imageCard(2), imageCard(3),
        ]))
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(recorder.events, ["write image 1", "cmd-v", "waited replaced"])
        XCTAssertEqual(recorder.content, "user copy", "The user's newer copy is never overwritten")
    }

    func testRefusedWriteGivesTheClipboardBackAtOnce() async {
        let recorder = Recorder()
        recorder.failingWrites = [1]
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: [
            textCard(1, "a"), imageCard(2), imageCard(3),
        ]))
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(recorder.events, ["write text \"a\"", "cmd-v", "waited read", "write image 2", "restore"])
        XCTAssertEqual(recorder.content, "original")
    }

    /// The accepted behaviour: three marked rows paste all three, the
    /// previous clipboard comes back, and only the series' own generations
    /// (three writes and the restore) are kept out of clipboard history.
    func testThreeMarkedRowsPasteAllThreeAndOnlyTheSeriesOwnWritesAreSuppressed() async {
        let recorder = Recorder()
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: [
            textCard(1, "a"), imageCard(2), imageCard(3),
        ]))
        XCTAssertEqual(posted, 3)
        XCTAssertEqual(recorder.received, ["text \"a\"", "image 2", "image 3"])
        XCTAssertEqual(recorder.content, "original")
        XCTAssertEqual(recorder.suppressed, [1, 2, 3, 4], "three writes, then the restore")
    }

    /// A copy the user makes during the series is never suppressed: no
    /// generation at or above it is handed to `suppressOwn`, so clipboard
    /// history records it, and it is not overwritten by the restore.
    func testUserCopyDuringTheSeriesIsRecordedAndNotOverwritten() async {
        let recorder = Recorder()
        recorder.readDelayMs = 50
        recorder.userCopyAtMs = 20
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: [
            textCard(1, "a"), imageCard(2), imageCard(3),
        ]))
        XCTAssertEqual(posted, 1)
        XCTAssertFalse(recorder.events.contains("restore"))
        XCTAssertEqual(recorder.content, "user copy")
        XCTAssertEqual(recorder.suppressed, [1])
        XCTAssertTrue(recorder.suppressed.allSatisfy { $0 < recorder.changeCount },
                      "the user's generation stays visible to clipboard history")
    }

    /// A refused write during which another copy landed: the pasteboard no
    /// longer holds the series' own generation, so nothing is restored over
    /// the fresh copy and that copy is not suppressed.
    func testRefusedWriteNeverRestoresOverACopyThatLandedDuringIt() async {
        let recorder = Recorder()
        recorder.failingWrites = [1]
        recorder.copyLandsDuringRefusedWrite = true
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: [
            textCard(1, "a"), imageCard(2), imageCard(3),
        ]))
        XCTAssertEqual(posted, 1)
        XCTAssertFalse(recorder.events.contains("restore"))
        XCTAssertEqual(recorder.content, "other copy")
        XCTAssertEqual(recorder.suppressed, [1, 2], "the first write and the refused write's own clear")
    }

    func testImageWithNothingPastableIsSkippedAndTheRestContinues() async {
        let recorder = Recorder()
        recorder.emptyWrites = [1]
        let posted = await recorder.paster().run(HistoryPastePlan.groups(for: [
            textCard(1, "a"), imageCard(2), imageCard(3),
        ]))
        XCTAssertEqual(posted, 2)
        XCTAssertEqual(recorder.received, ["text \"a\"", "image 3"])
    }

    func testReadBurstEndsTheWaitOnlyAfterItsLastRead() async {
        // A reader that takes PNG and then TIFF reads twice: the wait ends
        // only `afterReadMs` after the newest read of the burst.
        var reads = 0
        var now: UInt64 = 0
        let waiter = HistoryPasteReadWaiter(
            readCount: { reads },
            changeCount: { 7 },
            nowMs: { now },
            sleepMs: { ms in
                now += ms
                if now == 50 || now == 120 { reads += 1 }   // PNG, then TIFF
            }
        )
        let outcome = await waiter.wait(for: .init(changeCount: 7, readsBefore: 0))
        XCTAssertEqual(outcome, .read)
        XCTAssertEqual(now, 120 + HistoryPasteReadWaiter.Timing.standard.afterReadMs,
                       "Quiet time counts from the last read of the burst")
    }

    // MARK: - Real pasteboard

    private func makeImageAssets(sizes: [Int64: Int]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryMultiPasteTests.\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (id, side) in sizes {
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let payload = ClipboardImagePayload(uuid: Self.imageUUID(id), fileExtension: "png", thumbnailData: Data())
            try png.write(to: payload.sidecarURL(in: dir))
        }
        return dir
    }

    /// How Chromium/Electron take an image from a paste: one image, from the
    /// pasteboard's first item that has one.
    private func chromiumStyleRead(_ pasteboard: NSPasteboard) -> String? {
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data) {
            return "image \(rep.pixelsWide)px"
        }
        return pasteboard.string(forType: .string).map { "text \($0.debugDescription)" }
    }

    func testOneMultiImagePasteboardGivesAChromiumStyleReaderOnlyTheFirstImage() throws {
        // The former single paste of both images: why the third row was lost.
        let assets = try makeImageAssets(sizes: [2: 20, 3: 30])
        let pasteboard = scratchPasteboard()
        HistoryPasteboardWriter.write(.attachments([
            .image(.init(uuid: Self.imageUUID(2), fileExtension: "png", thumbnailData: Data())),
            .image(.init(uuid: Self.imageUUID(3), fileExtension: "png", thumbnailData: Data())),
        ]), to: pasteboard, assetsDirectory: assets)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(chromiumStyleRead(pasteboard), "image 20px", "Only the first image is read")
    }

    func testPasteWriteOfAnImageIsOneItemWithPNGAndTIFFAndCountsTheRead() throws {
        let assets = try makeImageAssets(sizes: [2: 20])
        let pasteboard = scratchPasteboard()
        let reads = PasteboardReadMonitor()
        let result = HistoryPasteboardWriter.writeForPaste(
            .attachments([.image(.init(uuid: Self.imageUUID(2), fileExtension: "png", thumbnailData: Data()))]),
            to: pasteboard, assetsDirectory: assets, reads: reads
        )
        guard case .written(let receipt) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(receipt.changeCount, pasteboard.changeCount)
        XCTAssertEqual(receipt.readsBefore, 0)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        let types = pasteboard.pasteboardItems?.first?.types ?? []
        XCTAssertTrue(types.contains(.png) && types.contains(.tiff))
        XCTAssertEqual(reads.readCount, 0, "Nothing is read before the target asks")
        XCTAssertEqual(chromiumStyleRead(pasteboard), "image 20px")
        XCTAssertEqual(reads.readCount, 1)
    }

    func testPasteWriteOfFilesGivesNoReadSignal() {
        let pasteboard = scratchPasteboard()
        let result = HistoryPasteboardWriter.writeForPaste(
            .attachments([.file(URL(fileURLWithPath: "/tmp/a.pdf")), .file(URL(fileURLWithPath: "/tmp/b.pdf"))]),
            to: pasteboard, assetsDirectory: FileManager.default.temporaryDirectory, reads: PasteboardReadMonitor()
        )
        XCTAssertEqual(result, .written(.init(changeCount: pasteboard.changeCount, readsBefore: nil)))
        XCTAssertEqual((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path),
                       ["/tmp/a.pdf", "/tmp/b.pdf"])
    }

    func testImageWithoutSidecarOrThumbnailHasNothingToPaste() {
        let pasteboard = scratchPasteboard()
        pasteboard.setString("keep", forType: .string)
        let result = HistoryPasteboardWriter.writeForPaste(
            .attachments([.image(.init(uuid: UUID(), fileExtension: "png", thumbnailData: Data()))]),
            to: pasteboard, assetsDirectory: FileManager.default.temporaryDirectory, reads: PasteboardReadMonitor()
        )
        XCTAssertEqual(result, .nothing)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    /// End to end on a named pasteboard with real waits: a Chromium-style
    /// target that reads each paste 450 ms after Cmd+V (later than the
    /// former fixed gap) gets the text and both images in badge order, and
    /// the user's clipboard comes back after the last read.
    func testRealPasteboardSlowTargetReceivesTextAndBothImagesThenTheClipboardReturns() async throws {
        let assets = try makeImageAssets(sizes: [2: 20, 3: 30])
        let pasteboard = scratchPasteboard()
        pasteboard.setString("user's clipboard", forType: .string)
        let original = Pasteboard.snapshot(of: pasteboard)
        let reads = PasteboardReadMonitor()
        var timing = HistoryPasteReadWaiter.Timing.standard
        timing.afterReadMs = 60
        let waiter = HistoryPasteReadWaiter(
            readCount: { reads.readCount },
            changeCount: { pasteboard.changeCount },
            nowMs: { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
            sleepMs: { ms in try? await Task.sleep(nanoseconds: ms * 1_000_000) },
            timing: timing
        )
        var received: [String] = []
        var readers: [Task<Void, Never>] = []
        var receivedAtRestore: Int?
        let paster = HistoryMultiPaster(
            targetIsCurrent: { _ in true },
            write: { HistoryPasteboardWriter.writeForPaste($0, to: pasteboard, assetsDirectory: assets, reads: reads) },
            paste: { _, _ in
                readers.append(Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    received.append(self.chromiumStyleRead(pasteboard) ?? "nothing")
                })
                return true
            },
            awaitConsumed: { _ = await waiter.wait(for: $0) },
            changeCount: { pasteboard.changeCount },
            restore: {
                receivedAtRestore = received.count
                Pasteboard.restore(original, into: pasteboard)
            }
        )

        let posted = await paster.run(HistoryPastePlan.groups(for: [textCard(1, "caption"), imageCard(2), imageCard(3)]))
        for reader in readers { await reader.value }

        XCTAssertEqual(posted, 3)
        XCTAssertEqual(received, ["text \"caption\"", "image 20px", "image 30px"])
        XCTAssertEqual(receivedAtRestore, 3)
        XCTAssertEqual(pasteboard.string(forType: .string), "user's clipboard")
    }

    // MARK: - Empty selection

    func testNothingMarkedAndNothingHoveredLeavesEnterAlone() {
        XCTAssertEqual(HistoryKeyDecision.action(keyCode: 36, hovered: nil, selection: []), .pass)
        XCTAssertEqual(HistoryPastePlan.groups(for: []), [])
    }

    func testEmptyPlanPostsNothing() async {
        let recorder = Recorder()
        let posted = await recorder.paster().run([])
        XCTAssertEqual(posted, 0)
        XCTAssertEqual(recorder.events, [])
    }

    func testSecondCommandClickUnmarksAndRenumbers() {
        let a = textCard(1, "a"), b = textCard(2, "b"), c = textCard(3, "c")
        let selection = HistoryPasteSelection()
        [a, b, c].forEach(selection.toggle)
        selection.toggle(a)
        XCTAssertNil(selection.position(of: a))
        XCTAssertEqual(selection.position(of: b), 1)
        XCTAssertEqual(selection.position(of: c), 2)
        selection.toggle(b)
        selection.toggle(c)
        XCTAssertTrue(selection.isEmpty)
    }

    // MARK: - Escape

    func testEscapeClearsMarksWithoutPasting() {
        let a = textCard(1, "a")
        let selection = HistoryPasteSelection()
        selection.toggle(a)
        XCTAssertEqual(HistoryKeyDecision.action(keyCode: 53, hovered: a, selection: selection.cards),
                       .clearSelection)
        selection.clear()
        XCTAssertEqual(HistoryKeyDecision.action(keyCode: 53, hovered: a, selection: selection.cards),
                       .pass, "Without marks Escape keeps its usual meaning")
    }

    func testOtherKeysAreNotHistorys() {
        let a = textCard(1, "a")
        XCTAssertEqual(HistoryKeyDecision.action(keyCode: 0, hovered: a, selection: [a]), .pass)
    }

    // MARK: - Hint and availability

    func testHintTeachesCommandClickAndCountsMarks() {
        func blocks(_ hints: [HistoryHint]) -> [String] { hints.map(\.fullText) }
        XCTAssertEqual(
            blocks(HistoryHoverView.hints(targetAppName: "Telegram")),
            ["Click to copy", "⌘-click for several", "Enter to paste to Telegram"]
        )
        XCTAssertEqual(
            blocks(HistoryHoverView.hints(targetAppName: "Telegram", selectedCount: 3)),
            ["Click to copy 3", "Enter to paste 3 to Telegram", "Esc to clear"]
        )
        XCTAssertEqual(
            blocks(HistoryHoverView.hints(targetAppName: nil, selectedCount: 2)),
            ["Click to copy 2", "Esc to clear"],
            "Without a target the marks are for copying"
        )
        XCTAssertEqual(
            blocks(HistoryHoverView.hints(targetAppName: nil, selectedCount: 2, escapeClears: false)),
            ["Click to copy 2", "⌘-click to unmark"],
            "Toolbox has no key monitor: ⌘-click unmarks there"
        )
        XCTAssertEqual(
            blocks(HistoryHoverView.hints(targetAppName: nil)),
            ["Click to copy", "⌘-click for several"]
        )
        XCTAssertEqual(
            blocks(HistoryHoverView.hints(targetAppName: "", selectedCount: 1)),
            ["Click to copy 1", "Esc to clear"],
            "An empty app name is no target"
        )
    }

    func testHintKeepsTheAppNameApartSoOnlyItShortens() {
        let hints = HistoryHoverView.hints(targetAppName: "Microsoft Remote Desktop Beta", selectedCount: 2)
        XCTAssertEqual(hints.compactMap(\.target), ["Microsoft Remote Desktop Beta"])
        XCTAssertEqual(hints[1].text, "Enter to paste 2 to")
        XCTAssertTrue(hints.allSatisfy { !$0.text.contains("Microsoft") })
    }

    func testFooterIsPlainTextWithoutKeycapsOrIcons() throws {
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/SidekeyTests/History/HistoryMultiPasteTests.swift",
                                  with: "Sources/Sidekey/History/HistoryHoverView.swift"), encoding: .utf8)
        let bar = try XCTUnwrap(source.range(of: "private struct HistoryHintBar"))
        let barSource = String(source[bar.lowerBound...].prefix(1500))
        XCTAssertFalse(barSource.contains("HotkeyHintView"), "No keycap plates in the History footer")
        XCTAssertFalse(barSource.contains("Image("), "No icons in the History footer")
        XCTAssertFalse(source.contains("cursorarrow.click"))
    }

    func testEnterPastesOnlyWhereThereIsATarget() {
        XCTAssertTrue(HistoryHoverView.canPaste(allowsKeyboardPaste: true, targetAppName: "Notes"))
        XCTAssertFalse(HistoryHoverView.canPaste(allowsKeyboardPaste: true, targetAppName: nil))
        XCTAssertFalse(HistoryHoverView.canPaste(allowsKeyboardPaste: true, targetAppName: ""))
        XCTAssertFalse(HistoryHoverView.canPaste(allowsKeyboardPaste: false, targetAppName: "Notes"))
    }

    func testEnterWithoutATargetKeepsTheMarksForACopy() {
        let a = textCard(1, "a"), b = textCard(2, "b")
        XCTAssertEqual(
            HistoryKeyDecision.action(keyCode: 36, hovered: a, selection: [a, b], canPaste: false),
            .pass,
            "Enter must not close History and drop the marks when it cannot paste"
        )
        XCTAssertEqual(
            HistoryKeyDecision.action(keyCode: 53, hovered: a, selection: [a, b], canPaste: false),
            .clearSelection
        )
    }

    // MARK: - Click with marks copies them all

    func testPlainClickWithMarksCopiesEveryMarkedRowInMarkOrder() {
        let a = fileCard(1, "/tmp/a.pdf"), b = fileCard(2, "/tmp/b.png"), c = textCard(3, "c")
        let selection = HistoryPasteSelection()
        selection.toggle(b)
        selection.toggle(a)
        XCTAssertEqual(HistoryHoverView.cardsToCopy(clicked: b, marked: selection.cards), [b, a],
                       "Clicking a marked row copies all marks, not just that row")
        XCTAssertEqual(HistoryHoverView.cardsToCopy(clicked: c, marked: selection.cards), [b, a],
                       "Clicking an unmarked row with marks also copies the marks")
        XCTAssertEqual(HistoryHoverView.cardsToCopy(clicked: c, marked: []), [c],
                       "No marks: the click copies its own row as before")
    }

    private func scratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HistoryMultiCopy.\(UUID())"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    func testThreeMarkedFilesCopyAsOneMultiItemPasteboard() {
        let pasteboard = scratchPasteboard()
        HistoryPasteboardWriter.writeAll(
            HistoryPastePlan.groups(for: [fileCard(3, "/tmp/c.zip"), fileCard(1, "/tmp/a.pdf"), fileCard(2, "/tmp/b.png")]),
            to: pasteboard, assetsDirectory: FileManager.default.temporaryDirectory
        )
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(urls?.map(\.path), ["/tmp/c.zip", "/tmp/a.pdf", "/tmp/b.png"])
    }

    func testMarkedTextsCopyAsOneStringALineEach() {
        let pasteboard = scratchPasteboard()
        HistoryPasteboardWriter.writeAll(
            HistoryPastePlan.groups(for: [textCard(1, "first"), dropCard(2, "second")]),
            to: pasteboard, assetsDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "first\nsecond")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testMixedMarksCopyAsOnePasteboardWithItemsInMarkOrder() {
        let pasteboard = scratchPasteboard()
        HistoryPasteboardWriter.writeAll(
            HistoryPastePlan.groups(for: [
                textCard(1, "Invoice:"), fileCard(2, "/tmp/invoice.pdf"), textCard(3, "Thanks"),
            ]),
            to: pasteboard, assetsDirectory: FileManager.default.temporaryDirectory
        )
        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].string(forType: .string), "Invoice:")
        XCTAssertEqual(items[1].string(forType: .fileURL).flatMap { URL(string: $0)?.path }, "/tmp/invoice.pdf")
        XCTAssertEqual(items[2].string(forType: .string), "Thanks")
        XCTAssertEqual(pasteboard.string(forType: .string), "Invoice:\nThanks",
                       "A plain text read joins every text item with line breaks (AppKit)")
    }

    func testCopyingOneRowIsUnchanged() {
        let pasteboard = scratchPasteboard()
        HistoryPasteboardWriter.writeAll(
            HistoryPastePlan.groups(for: [textCard(1, "only")]),
            to: pasteboard, assetsDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "only")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testCopyingAnEmptyFileEntryKeepsTheExistingPasteboard() {
        let pasteboard = scratchPasteboard()
        pasteboard.setString("existing copy", forType: .string)
        HistoryPasteboardWriter.writeAll(
            HistoryPastePlan.groups(for: [fileCard(1)]),
            to: pasteboard,
            assetsDirectory: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "existing copy")
    }

    func testPlainClickCopiesThenClearsAndCommandClickOnlyMarks() throws {
        // The row's click closure: ⌘ toggles a mark; a plain click copies
        // (all marks or the row) and then clears the marks, everywhere —
        // island with or without a target, and Toolbox.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/History/HistoryHoverView.swift"),
            encoding: .utf8
        )
        let click = try XCTUnwrap(source.range(of: "if NSEvent.modifierFlags.contains(.command) {"))
        let tail = String(source[click.lowerBound...].prefix(500))
        XCTAssertTrue(tail.contains("selection.toggle(card)"))
        let copy = try XCTUnwrap(tail.range(of: "onCopy(Self.cardsToCopy(clicked: card, marked: selection.cards))"))
        let clear = try XCTUnwrap(tail.range(of: "selection.clear()"))
        XCTAssertLessThan(copy.lowerBound, clear.lowerBound, "Copy first, then drop the marks")
        XCTAssertFalse(source.contains("multiSelectEnabled"), "Marks are no longer limited to a paste target")
    }
}

/// The island opens History and captures the paste target in the same
/// `panelMode` change, so the target can reach the panel after it appeared.
/// Enter with marked rows must still paste then instead of passing the key
/// on (AppKit beeps for an unhandled Return).
@MainActor
final class HistoryHoverTargetArrivalTests: XCTestCase {
    private struct Host: View {
        @State var target: String?
        let next: String?
        let probe: (HistoryHoverKeyMonitor) -> Void
        let changed: () -> Void

        var body: some View {
            HistoryHoverView(
                mode: .constant(.clipboard),
                cards: [],
                targetAppName: target,
                onSelectMode: { _ in }, onCopy: { _ in }, onPreviewAnchorChange: { _, _ in },
                onPaste: { _ in },
                onKeyMonitorReady: probe
            )
            .task {
                target = next
                changed()
            }
        }
    }

    private func monitorAfterTargetChange(from first: String?, to next: String?) throws -> HistoryHoverKeyMonitor {
        var monitor: HistoryHoverKeyMonitor?
        var didChange = false
        let host = NSHostingView(rootView: Host(target: first, next: next,
                                                probe: { monitor = $0 }, changed: { didChange = true }))
        host.frame = NSRect(x: 0, y: 0, width: 312, height: 260)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 312, height: 260),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { monitor?.stop(); window.contentView = nil; window.close() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while !didChange && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(didChange)
        return try XCTUnwrap(monitor)
    }

    func testTargetArrivingAfterThePanelAppearedLetsEnterPasteMarks() throws {
        let monitor = try monitorAfterTargetChange(from: nil, to: "Telegram")
        XCTAssertTrue(monitor.canPaste, "Enter with marks would pass on and beep")
    }

    func testTargetGoingAwayStopsEnterTakingMarks() throws {
        let monitor = try monitorAfterTargetChange(from: "Telegram", to: nil)
        XCTAssertFalse(monitor.canPaste)
    }
}
