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
                targetIsCurrent: { _ in true },
                write: { [unowned self] group in
                    switch group {
                    case .text(let t): events.append("write text \(t.debugDescription)")
                    case .attachments(let items): events.append("write \(items.count) attachments")
                    }
                },
                paste: { [unowned self] _ in
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
        func spoken(_ hints: [HistoryHint]) -> [String] { hints.map(\.spokenText) }
        XCTAssertEqual(
            spoken(HistoryHoverView.hints(targetAppName: "Telegram")),
            ["Click: Copy", "Command key Click: Select", "Return key: Paste to Telegram"]
        )
        XCTAssertEqual(
            spoken(HistoryHoverView.hints(targetAppName: "Telegram", selectedCount: 3)),
            ["Click: Copy 3", "Return key: Paste 3 to Telegram", "Escape key: Clear"]
        )
        XCTAssertEqual(
            spoken(HistoryHoverView.hints(targetAppName: nil, selectedCount: 2)),
            ["Click: Copy 2", "Escape key: Clear"],
            "Without a target the marks are for copying"
        )
        XCTAssertEqual(
            spoken(HistoryHoverView.hints(targetAppName: nil, selectedCount: 2, escapeClears: false)),
            ["Click: Copy 2", "Command key Click: Unmark"],
            "Toolbox has no key monitor: ⌘-click unmarks there"
        )
        XCTAssertEqual(
            spoken(HistoryHoverView.hints(targetAppName: nil)),
            ["Click: Copy", "Command key Click: Select"]
        )
        XCTAssertEqual(
            spoken(HistoryHoverView.hints(targetAppName: "", selectedCount: 1)),
            ["Click: Copy 1", "Escape key: Clear"],
            "An empty app name is no target"
        )
    }

    func testHintKeepsTheAppNameApartSoOnlyItShortens() {
        let hints = HistoryHoverView.hints(targetAppName: "Microsoft Remote Desktop Beta", selectedCount: 2)
        XCTAssertEqual(hints.compactMap(\.target), ["Microsoft Remote Desktop Beta"])
        XCTAssertEqual(hints[1].action, "Paste 2 to")
        XCTAssertEqual(hints[1].keys, [.returnKey])
        XCTAssertTrue(hints.allSatisfy { !$0.action.contains("Microsoft") })
    }

    func testHintKeysAreKeycapsNotWords() {
        let hints = HistoryHoverView.hints(targetAppName: "Telegram")
        XCTAssertEqual(hints.map(\.keys), [[.click], [.command, .click], [.returnKey]])
        XCTAssertEqual(HistoryHint.Key.command.keycap, .text(HotkeyGlyph.command))
        XCTAssertEqual(HistoryHint.Key.click.keycap, .symbol("cursorarrow.click", accessibilityLabel: "Click"))
        XCTAssertEqual(HistoryHint.Key.returnKey.keycap, .symbol("return", accessibilityLabel: "Return key"))
        XCTAssertEqual(HistoryHint.Key.escape.keycap, .text("esc"))
        for key in [HistoryHint.Key.click, .returnKey] {
            if case .symbol(let name, _) = key.keycap {
                XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
            }
        }
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
