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
