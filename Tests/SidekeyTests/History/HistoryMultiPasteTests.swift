import AppKit
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
            payload: .image(.init(uuid: UUID(), fileExtension: "png", thumbnailData: Data()))
        ))
    }

    /// Records what the paster did, in order.
    private final class Recorder {
        var events: [String] = []
        var pasteResults: [Bool] = []

        func paster() -> HistoryMultiPaster {
            HistoryMultiPaster(
                write: { [unowned self] group in
                    switch group {
                    case .text(let t): events.append("write text \(t.debugDescription)")
                    case .attachments(let items): events.append("write \(items.count) attachments")
                    }
                },
                paste: { [unowned self] in
                    events.append("cmd-v")
                    return pasteResults.isEmpty ? true : pasteResults.removeFirst()
                },
                sleep: { [unowned self] ns in events.append("wait \(ns / 1_000_000)ms") }
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
        XCTAssertEqual(recorder.events, ["write 1 attachments", "cmd-v"])
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
        XCTAssertEqual(recorder.events, ["write 3 attachments", "cmd-v"])

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

    func testImagesJoinFilesAsAttachments() {
        let groups = HistoryPastePlan.groups(for: [fileCard(1, "/tmp/a"), imageCard(2)])
        guard case .attachments(let items) = groups.first else { return XCTFail() }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(items.count, 2)
    }

    // MARK: - Text rows

    func testMarkedTextsArriveAsOnePasteOneLineEach() async {
        let groups = HistoryPastePlan.groups(for: [textCard(1, "first"), dropCard(2, "second")])
        XCTAssertEqual(groups, [.text("first\nsecond")])
        let recorder = Recorder()
        await recorder.paster().run(groups)
        XCTAssertEqual(recorder.events, ["write text \"first\\nsecond\"", "cmd-v"])
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
        let gap = "wait \(HistoryMultiPaster.gapBetweenPastesNs / 1_000_000)ms"
        XCTAssertEqual(recorder.events, [
            "write text \"Invoice:\"", "cmd-v",
            gap, "write 2 attachments", "cmd-v",
            gap, "write text \"Thanks\"", "cmd-v",
        ])
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
        XCTAssertEqual(
            HistoryHoverView.hintText(targetAppName: "Telegram"),
            "Click for copy   ⌘-click for several   Enter to paste to Telegram"
        )
        XCTAssertEqual(
            HistoryHoverView.hintText(targetAppName: "Telegram", selectedCount: 3),
            "Enter to paste 3 to Telegram   Esc to clear"
        )
        XCTAssertEqual(HistoryHoverView.hintText(targetAppName: nil, selectedCount: 2), "Click for copy")
    }

    func testMarkingNeedsSomewhereToPaste() {
        XCTAssertTrue(HistoryHoverView.allowsMultiSelect(allowsKeyboardPaste: true, targetAppName: "Notes"))
        XCTAssertFalse(HistoryHoverView.allowsMultiSelect(allowsKeyboardPaste: true, targetAppName: nil))
        XCTAssertFalse(HistoryHoverView.allowsMultiSelect(allowsKeyboardPaste: true, targetAppName: ""))
        XCTAssertFalse(HistoryHoverView.allowsMultiSelect(allowsKeyboardPaste: false, targetAppName: "Notes"),
                       "Toolbox History has no paste target: ⌘-click copies as before")
    }
}
