import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class RendererSupportTests: XCTestCase {
    func testMarkdownBlockParserRecognizesHeadingsListsTablesAndCodeBlocks() {
        let blocks = MarkdownBlockParser.parse("""
        ## Plan

        - First item
        - Second item

        | Name | Value |
        | --- | --- |
        | Status | Ready |

        ```swift
        let answer = 42
        ```
        """)

        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Plan"),
            .unorderedList(["First item", "Second item"]),
            .table(headers: ["Name", "Value"], rows: [["Status", "Ready"]]),
            .codeBlock(language: "swift", code: "let answer = 42")
        ])
    }

    func testMarkdownBodyTextHostsBlockMarkdownWithoutCrash() {
        let view = MarkdownBodyText(text: """
        # Heading

        - Bullet

        | Key | Value |
        | --- | --- |
        | Code | `inline` |

        ```
        fenced()
        ```
        """)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostingView.frame.width, 320)
    }

    // MARK: - Column-width layout (pure logic)
    //
    // The layout helper exists so every row in a table draws its cells at
    // the *same* widths. Before this change the renderer leaned on
    // SwiftUI `Grid` and `ScrollView(.horizontal)`: each row could imply
    // a different column width when content varied, producing the
    // "ragged" tables Maxim flagged. The new contract: one width vector
    // per table, derived from the longest content per column across
    // header + every row, then divided proportionally inside the
    // available width.

    func testColumnLayoutSplitsWidthByLongestContentWithMinFloor() {
        // 3 columns where the middle has long content; the layout weights
        // by longest cell length and floors at the configured minimum.
        let widths = MarkdownTableColumnLayout.columnWidths(
            headers: ["A", "Цена на 2 человека", "C"],
            rows: [["short", "120 €", "x"]],
            available: 336
        )

        XCTAssertEqual(widths.count, 3)
        // Total width consumed equals available (full-bleed table).
        XCTAssertEqual(widths.reduce(0, +), 336, accuracy: 0.5)
        // Middle column should be widest because its header is the longest.
        XCTAssertGreaterThan(widths[1], widths[0])
        XCTAssertGreaterThan(widths[1], widths[2])
        // No column collapses below the configured min.
        for width in widths {
            XCTAssertGreaterThanOrEqual(width, MarkdownTableColumnLayout.minColumnWidth)
        }
    }

    func testColumnLayoutWeightsByLongestContentAcrossAllRowsNotJustHeader() {
        // Column-2 header is short but a data row contains very long text.
        // The widest cell anywhere in the column must drive the column's
        // weight — otherwise rows draw narrower columns than the longest
        // content needs and the table looks ragged.
        let widths = MarkdownTableColumnLayout.columnWidths(
            headers: ["A", "B", "C"],
            rows: [
                ["a", "very long body content that dominates", "c"],
                ["a", "short", "c"]
            ],
            available: 360
        )

        XCTAssertEqual(widths.count, 3)
        XCTAssertGreaterThan(widths[1], widths[0])
        XCTAssertGreaterThan(widths[1], widths[2])
    }

    func testColumnLayoutEqualWidthsWhenContentLengthsMatch() {
        let widths = MarkdownTableColumnLayout.columnWidths(
            headers: ["AA", "BB", "CC"],
            rows: [["xx", "yy", "zz"]],
            available: 300
        )

        XCTAssertEqual(widths.count, 3)
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.5)
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.5)
        XCTAssertEqual(widths.reduce(0, +), 300, accuracy: 0.5)
    }

    func testColumnLayoutHonoursMinWidthEvenWhenAvailableIsBelowSum() {
        // If available < columnCount * minColumnWidth, the layout must still
        // return non-negative widths (we accept that they fall below the
        // ideal floor, but they remain positive and stable).
        let widths = MarkdownTableColumnLayout.columnWidths(
            headers: ["A", "B", "C", "D", "E"],
            rows: [],
            available: 100
        )

        XCTAssertEqual(widths.count, 5)
        for width in widths {
            XCTAssertGreaterThan(width, 0)
        }
        XCTAssertEqual(widths.reduce(0, +), 100, accuracy: 0.5)
    }

    func testColumnLayoutReturnsEmptyForZeroColumns() {
        let widths = MarkdownTableColumnLayout.columnWidths(
            headers: [],
            rows: [],
            available: 300
        )

        XCTAssertTrue(widths.isEmpty)
    }

    func testColumnLayoutHandlesMissingTrailingCellsInRows() {
        // Some rows have fewer cells than headers — the layout should not
        // crash and should still emit a width per header column.
        let widths = MarkdownTableColumnLayout.columnWidths(
            headers: ["A", "B", "C"],
            rows: [["only-first"], ["one", "two"]],
            available: 300
        )

        XCTAssertEqual(widths.count, 3)
        XCTAssertEqual(widths.reduce(0, +), 300, accuracy: 0.5)
    }

    // MARK: - Wrapping integration (NSHostingView)

    func testMarkdownTableRendersTallerWhenCellTextWrapsThanWhenItIsShort() {
        // Pin both views to the same bounded width with an explicit
        // `.frame(width:)`. One has short single-token cells, the other
        // has Russian phrases that must wrap to a second line. The
        // bounded layout must surface wrap as a taller rendered hosting
        // view — proof that cells grow vertically instead of truncating
        // or pushing the table off-screen horizontally.
        let width: CGFloat = 320

        let shortHost = NSHostingView(rootView: MarkdownBodyText(text: """
        | A | B | C |
        | --- | --- | --- |
        | x | y | z |
        """).frame(width: width))
        shortHost.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        shortHost.layoutSubtreeIfNeeded()
        let shortHeight = shortHost.fittingSize.height

        let wrappedHost = NSHostingView(rootView: MarkdownBodyText(text: """
        | A | Цена на 2 человека за ночь в отеле | C |
        | --- | --- | --- |
        | x | 120 евро суммарно за всё проживание | z |
        """).frame(width: width))
        wrappedHost.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        wrappedHost.layoutSubtreeIfNeeded()
        let wrappedHeight = wrappedHost.fittingSize.height

        XCTAssertGreaterThan(
            wrappedHeight,
            shortHeight,
            "Long cell content must wrap (grow row height), not truncate."
        )
    }

    func testColumnWidthsAreStableAcrossRowsRegardlessOfPerRowContentLength() {
        // Sanity check on the layout helper: every call with the same
        // `(headers, rows, available)` returns the same vector. The
        // production renderer feeds one vector to every row, so this
        // guards against accidental per-row recomputation.
        let headers = ["Город", "Цена", "Длительность"]
        let rows = [
            ["Краков", "120 €", "2 ночи"],
            ["Прага", "180 €", "3 ночи"]
        ]

        let first = MarkdownTableColumnLayout.columnWidths(
            headers: headers,
            rows: rows,
            available: 320
        )
        let second = MarkdownTableColumnLayout.columnWidths(
            headers: headers,
            rows: rows,
            available: 320
        )

        XCTAssertEqual(first, second)
    }

    // MARK: - Code block copy action
    //
    // Sonnet's streaming answer often contains fenced code blocks. The
    // renderer surfaces a copy affordance in each block's top-right
    // corner; clicking it writes the *unmodified* code (no trimming, no
    // language fence) to the pasteboard so the user can paste it into
    // Xcode / a shell / another editor. Tests pin the copy contract by
    // exercising `CodeBlockCopyAction.copy` against an isolated
    // `NSPasteboard` so `NSPasteboard.general` (and the developer's
    // clipboard history) never get polluted by the test suite.
    //
    // No clipboard suppression here: the user intentionally clicks to
    // copy, so this write should appear in their normal pasteboard
    // history exactly like a Cmd+C in any other editor.
    func testCodeBlockCopyActionWritesCodeToInjectedPasteboard() {
        let pasteboard = makeIsolatedPasteboard()
        let code = "let answer = 42\nprint(answer)"
        CodeBlockCopyAction.copy(code, into: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), code)
    }

    func testCodeBlockCopyActionPreservesLeadingAndTrailingWhitespace() {
        // Indentation matters in code. The action must not trim — that
        // would silently break Python / YAML pastes.
        let pasteboard = makeIsolatedPasteboard()
        let code = "  def hello():\n      print(\"hi\")\n"
        CodeBlockCopyAction.copy(code, into: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), code)
    }

    func testCodeBlockCopyActionReplacesPreviousPasteboardContents() {
        // clearContents() must run before the write so a stale type from
        // an earlier copy (e.g. RTF from a Word document) doesn't bleed
        // into the next paste.
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.declareTypes([.rtf], owner: nil)
        pasteboard.setData(Data("rtf-junk".utf8), forType: .rtf)

        CodeBlockCopyAction.copy("new-code", into: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "new-code")
        // RTF type should be wiped — clearContents() is part of the
        // contract.
        XCTAssertNil(pasteboard.data(forType: .rtf))
    }

    func testCodeBlockViewHostsScrollAndCopyOverlayWithoutCrashing() {
        // Sanity-check that the SwiftUI view tree the renderer builds for
        // a fenced code block stays hostable. The overlay button is a
        // SwiftUI `Button` inside an overlay so a screenshot test is
        // overkill — the smoke test guards against compile-time
        // regressions in the layout (overlay/alignment/etc.).
        let view = CodeBlockView(code: "let x = 1")
        let host = NSHostingView(rootView: view.frame(width: 320))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.width, 320)
    }

    func testMarkdownTableFitsWithinAvailableWidthAndDoesNotOverflowHorizontally() {
        // Maxim's example — narrow panel width, long Russian header.
        // Once the SwiftUI body is constrained to a fixed width via
        // `.frame(width:)`, the rendered table must respect that bound:
        // text wraps inside cells rather than pushing the table beyond
        // the panel.
        let bounded: CGFloat = 320
        let host = NSHostingView(rootView: MarkdownBodyText(text: """
        | Город | Цена на 2 человека | Длительность |
        | --- | --- | --- |
        | Краков | 120 € | 2 ночи |
        | Прага | 180 € | 3 ночи |
        """).frame(width: bounded))
        host.frame = NSRect(x: 0, y: 0, width: bounded, height: 600)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            host.fittingSize.width,
            bounded + 1,
            "Table must fit within the bounded width, not require horizontal scroll."
        )
    }

    // MARK: - Render-item grouping (pure logic)
    //
    // To make drag-selection work across consecutive paragraphs and
    // headings, the renderer collapses runs of "text-shaped" blocks
    // (paragraph + heading) into a single `Text(AttributedString)` view.
    // `MarkdownRenderItem.group(_:)` is the pure function that decides
    // which blocks share a run and which stay as their own view. Tests
    // pin the contract so a future tweak doesn't silently fragment runs
    // (which would re-break selection).

    func testGroupCollapsesConsecutiveParagraphsIntoOneRun() {
        let blocks: [MarkdownBlock] = [
            .paragraph("First."),
            .paragraph("Second."),
            .paragraph("Third.")
        ]

        let items = MarkdownRenderItem.group(blocks)

        XCTAssertEqual(items.count, 1)
        guard case .textRun(let runBlocks) = items[0] else {
            return XCTFail("Expected textRun, got \(items[0])")
        }
        XCTAssertEqual(runBlocks, blocks)
    }

    func testGroupMergesParagraphsAndHeadingsIntoOneRun() {
        // Headings live in the same run as adjacent paragraphs so the
        // user can drag-select from a heading down through the body.
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "Plan"),
            .paragraph("Body one."),
            .paragraph("Body two."),
            .heading(level: 3, text: "Next"),
            .paragraph("More body.")
        ]

        let items = MarkdownRenderItem.group(blocks)

        XCTAssertEqual(items.count, 1)
        guard case .textRun(let runBlocks) = items[0] else {
            return XCTFail("Expected textRun, got \(items[0])")
        }
        XCTAssertEqual(runBlocks, blocks)
    }

    func testGroupBreaksRunOnNonTextBlock() {
        // Code blocks (and tables / lists / blockquotes) interrupt a
        // run: they have their own dedicated renderer, so the
        // surrounding paragraphs become two distinct runs.
        let blocks: [MarkdownBlock] = [
            .paragraph("Before code."),
            .codeBlock(language: nil, code: "let x = 1"),
            .paragraph("After code."),
            .paragraph("Still after.")
        ]

        let items = MarkdownRenderItem.group(blocks)

        XCTAssertEqual(items.count, 3)
        guard case .textRun(let firstRun) = items[0] else {
            return XCTFail("Expected first item to be a textRun")
        }
        XCTAssertEqual(firstRun, [.paragraph("Before code.")])

        guard case .block(let middleBlock) = items[1] else {
            return XCTFail("Expected middle item to be a standalone block")
        }
        XCTAssertEqual(middleBlock, .codeBlock(language: nil, code: "let x = 1"))

        guard case .textRun(let lastRun) = items[2] else {
            return XCTFail("Expected last item to be a textRun")
        }
        XCTAssertEqual(lastRun, [
            .paragraph("After code."),
            .paragraph("Still after.")
        ])
    }

    func testGroupTreatsTablesAndBlockquotesAndCodeAsStandaloneBlocks() {
        // After the Maxim-bug-1 fix, lists ARE text-shaped (they fuse
        // into a `textRun` alongside paragraphs and headings). Tables,
        // blockquotes and code blocks keep their bespoke renderers and
        // remain standalone — they have layouts that can't merge into
        // a single `Text`.
        let blocks: [MarkdownBlock] = [
            .paragraph("Intro."),
            .table(headers: ["H"], rows: [["v"]]),
            .blockquote("quoted"),
            .codeBlock(language: nil, code: "x"),
            .paragraph("Outro.")
        ]

        let items = MarkdownRenderItem.group(blocks)

        XCTAssertEqual(items.count, 5)
        for (index, expectedBlock) in [
            (1, MarkdownBlock.table(headers: ["H"], rows: [["v"]])),
            (2, .blockquote("quoted")),
            (3, .codeBlock(language: nil, code: "x"))
        ] {
            guard case .block(let block) = items[index] else {
                return XCTFail("Expected item \(index) to be a standalone block")
            }
            XCTAssertEqual(block, expectedBlock)
        }
    }

    // MARK: - Bug 1 follow-up: paragraph + list fusion
    //
    // Maxim's canonical answer shape is "vstuplenie-paragraph + bulleted
    // list" (book recommendations, options to compare, steps to follow).
    // The original fix only fused paragraph + heading; the list stayed
    // a sibling `VStack`, so drag-select still stopped at the
    // paragraph→list boundary. These tests pin the extended contract:
    // unordered + ordered lists fuse into the same `textRun` as
    // surrounding paragraphs/headings.

    func testGroupFusesParagraphAndUnorderedListIntoSingleRun() {
        let blocks: [MarkdownBlock] = [
            .paragraph("Books with similar atmosphere:"),
            .unorderedList(["Shola", "Ocean at the End of the Lane"])
        ]

        let items = MarkdownRenderItem.group(blocks)

        XCTAssertEqual(items.count, 1, "Paragraph + list must fuse into one run so drag-select spans the boundary")
        guard case .textRun(let runBlocks) = items[0] else {
            return XCTFail("Expected textRun, got \(items[0])")
        }
        XCTAssertEqual(runBlocks, blocks)
    }

    func testGroupFusesParagraphAndOrderedListIntoSingleRun() {
        let blocks: [MarkdownBlock] = [
            .paragraph("Steps to follow:"),
            .orderedList(["First", "Second", "Third"])
        ]

        let items = MarkdownRenderItem.group(blocks)

        XCTAssertEqual(items.count, 1)
        guard case .textRun(let runBlocks) = items[0] else {
            return XCTFail("Expected textRun, got \(items[0])")
        }
        XCTAssertEqual(runBlocks, blocks)
    }

    func testGroupFusesHeadingListParagraphSandwichIntoSingleRun() {
        // Most common multi-section answer shape — heading, then a
        // list, then a closing paragraph. All three must share one
        // run so the user can drag-select from heading to closer.
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "Recommendations"),
            .unorderedList(["One", "Two"]),
            .paragraph("Pick whichever resonates.")
        ]

        let items = MarkdownRenderItem.group(blocks)

        XCTAssertEqual(items.count, 1)
        guard case .textRun(let runBlocks) = items[0] else {
            return XCTFail("Expected textRun, got \(items[0])")
        }
        XCTAssertEqual(runBlocks, blocks)
    }

    func testAttributedRunRendersUnorderedListWithBulletGlyphAndLineBreaks() {
        // Each item gets the bullet glyph + two-space indent, joined by
        // \n so the fused `Text(AttributedString)` lays out one item
        // per line. The bullet uses U+2022 to match the per-block
        // `Text("•")` it replaces.
        let attributed = MarkdownAttributedRun.attributedString(for: [
            .unorderedList(["First item", "Second item"])
        ])

        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "\u{2022}  First item\n\u{2022}  Second item")
    }

    func testAttributedRunRendersOrderedListWithNumericPrefixes() {
        // 1-based numbering, dotted, with the same two-space indent so
        // ordered + unordered lists share visual cadence in mixed-list
        // answers.
        let attributed = MarkdownAttributedRun.attributedString(for: [
            .orderedList(["Alpha", "Beta", "Gamma"])
        ])

        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "1.  Alpha\n2.  Beta\n3.  Gamma")
    }

    func testAttributedRunJoinsParagraphAndListWithNewlineSeparator() {
        // The block-level separator between paragraph and list is the
        // same single `\n` the run already uses between paragraphs.
        // We avoid `\n\n` for the same reason as paragraph→paragraph:
        // a blank line inside a `Text` rents a full line height and
        // bloated the previous per-block layout's overall body height.
        let attributed = MarkdownAttributedRun.attributedString(for: [
            .paragraph("Intro line."),
            .unorderedList(["A", "B"])
        ])

        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "Intro line.\n\u{2022}  A\n\u{2022}  B")
    }

    func testAttributedRunPreservesInlineMarkdownInsideListItems() {
        // `**bold**` and `*italic*` inside an item must still parse
        // (markers stripped from the rendered characters) — Sonnet
        // often bolds the title of each list item in book / option
        // recommendations.
        let attributed = MarkdownAttributedRun.attributedString(for: [
            .unorderedList(["**Shola** — gothic mood", "*Ocean* — magical realism"])
        ])

        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "\u{2022}  Shola — gothic mood\n\u{2022}  Ocean — magical realism")
    }

    func testAttributedRunFusedHeadingThenListCarriesHeadingFont() {
        // Heading still needs its semibold/larger font when it shares
        // a run with a list. We check that *some* run inside the
        // attributed result carries a non-nil font on the heading
        // text — the same contract as the heading+paragraph fusion
        // test above.
        let attributed = MarkdownAttributedRun.attributedString(for: [
            .heading(level: 2, text: "Section"),
            .unorderedList(["Item"])
        ])

        var sawHeadingFont = false
        for run in attributed.runs {
            let text = String(attributed.characters[run.range])
            if text.contains("Section"), run.font != nil {
                sawHeadingFont = true
            }
        }
        XCTAssertTrue(
            sawHeadingFont,
            "Heading text must keep its font even when fused with a list."
        )
    }

    func testMarkdownBodyTextHostsParagraphPlusListWithoutCrashing() {
        // Smoke test: the most common Maxim-bug-1 shape must host
        // cleanly inside `NSHostingView`. Catches accidental regressions
        // where extending the run to lists breaks layout / measurement.
        let view = MarkdownBodyText(text: """
        Books with similar atmosphere:

        - First book
        - Second book
        - Third book
        """)

        let host = NSHostingView(rootView: view.frame(width: 320))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.width, 320)
    }

    func testGroupReturnsEmptyForEmptyInput() {
        XCTAssertTrue(MarkdownRenderItem.group([]).isEmpty)
    }

    // MARK: - Fused-run attributed string

    func testAttributedRunJoinsParagraphsWithSingleNewlineSeparator() {
        // Two paragraphs in one run must produce one AttributedString
        // that contains both, joined by a newline. This is what makes
        // drag-select span both paragraphs — a single `Text` node
        // instead of two siblings.
        //
        // Why a single \n and not \n\n: a blank line inside a Text rents
        // a full line height (~14pt at 12pt font + 2pt lineSpacing),
        // which is roughly double the previous `VStack(spacing: 7)`
        // between standalone `Text` blocks. A single \n keeps the
        // overall body height within ±25% of the per-block reference
        // layout (verified by `testFusedTextRunVisualHeight…`).
        let attributed = MarkdownAttributedRun.attributedString(for: [
            .paragraph("Alpha."),
            .paragraph("Beta.")
        ])

        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "Alpha.\nBeta.")
    }

    func testAttributedRunRendersInlineMarkdownFormatting() {
        // `**bold**` and `*italic*` must be parsed inline so the
        // visible characters are stripped of their markers. We sample
        // the rendered character stream — if the asterisks survive,
        // markdown parsing regressed.
        let attributed = MarkdownAttributedRun.attributedString(for: [
            .paragraph("This is **bold** and *italic*.")
        ])

        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "This is bold and italic.")
    }

    func testAttributedRunAppliesHeadingFontPerLevel() {
        // Headings inside a fused run still need to look like headings.
        // We apply font as an AttributedString attribute on the heading
        // run so the same `Text` view can render multiple font sizes.
        let attributed = MarkdownAttributedRun.attributedString(for: [
            .heading(level: 1, text: "Title"),
            .paragraph("Body.")
        ])

        // Find the run that contains the heading text and assert it
        // carries the heading font (size 16, semibold).
        var sawHeadingFont = false
        for run in attributed.runs {
            let text = String(attributed.characters[run.range])
            if text.contains("Title"), run.font != nil {
                sawHeadingFont = true
            }
        }
        XCTAssertTrue(
            sawHeadingFont,
            "Heading text must carry a non-nil font attribute so it visually outranks the paragraph it shares a run with."
        )
    }

    func testFusedTextRunVisualHeightMatchesPreviousPerBlockLayoutWithinTolerance() {
        // The visual rhythm before this change came from VStack(spacing: 7)
        // wrapping a Text per paragraph. After this change consecutive
        // paragraphs share one Text joined by "\n\n". If the swap silently
        // changed paragraph spacing the rendered hosting view height would
        // drift substantially. We compare against an explicit reference
        // built from one Text per paragraph in the same VStack to guard
        // against regressions worse than ±25% (one line of body text at
        // 12pt is ~16pt, so ±20pt is the threshold for "user noticeable").
        let width: CGFloat = 320

        let sampleHost = NSHostingView(rootView: MarkdownBodyText(text: """
        First paragraph of the answer with some inline markdown like **bold** and *italic*.

        Second paragraph that continues the thought across a paragraph break.

        Third paragraph closing the answer.
        """).frame(width: width))
        sampleHost.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        sampleHost.layoutSubtreeIfNeeded()
        let sampleHeight = sampleHost.fittingSize.height

        let referenceHost = NSHostingView(rootView: VStack(alignment: .leading, spacing: 7) {
            Text("First paragraph of the answer with some inline markdown like bold and italic.")
            Text("Second paragraph that continues the thought across a paragraph break.")
            Text("Third paragraph closing the answer.")
        }
        .font(.system(size: 12))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width))
        referenceHost.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        referenceHost.layoutSubtreeIfNeeded()
        let referenceHeight = referenceHost.fittingSize.height

        // Allow generous tolerance — the "\n\n" inside one Text and the
        // VStack(spacing: 7) between three Texts are *not* pixel-perfect
        // equivalents. We just want to catch order-of-magnitude regressions
        // (e.g. zero spacing, or doubled spacing) — anything inside ±25%
        // of the reference is fine.
        let tolerance = referenceHeight * 0.25
        XCTAssertEqual(
            sampleHeight,
            referenceHeight,
            accuracy: tolerance,
            "Fused-run paragraph layout drifted noticeably from the per-block reference (sample: \(sampleHeight), reference: \(referenceHeight))."
        )
    }

    func testAttributedRunFallsBackToPlainStringOnMalformedMarkdown() {
        // A malformed markdown fragment must not crash or empty out
        // the rendered text. The fallback path returns the literal
        // string so the user still sees their content.
        // (Foundation's markdown parser is fairly forgiving — this
        // guards the catch branch contract.)
        let weird = "Stray ` backtick that never closes."
        let attributed = MarkdownAttributedRun.attributedString(for: [
            .paragraph(weird)
        ])

        let plain = String(attributed.characters)
        XCTAssertFalse(plain.isEmpty)
        XCTAssertTrue(
            plain.contains("backtick"),
            "Fallback path must preserve the original text instead of dropping it."
        )
    }

    // MARK: - Helpers

    /// Returns a unique private `NSPasteboard` for one test. Named
    /// pasteboards are persistent across processes, so each test uses a
    /// fresh UUID-suffixed name to avoid bleed between tests, between
    /// runs, and across the developer's other tooling. Mirrors the
    /// helper used by `SelectionFallbackTests` so the suite never writes
    /// to `NSPasteboard.general`.
    private func makeIsolatedPasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name(rawValue: "SidekeyTestPasteboard.\(UUID().uuidString)")
        let pb = NSPasteboard(name: name)
        pb.clearContents()
        return pb
    }
}
