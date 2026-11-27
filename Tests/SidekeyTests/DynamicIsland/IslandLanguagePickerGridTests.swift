import XCTest
@testable import Sidekey

/// The language pickers never draw outside their drawer: the drawer fits the
/// curated four-row grid, and longer results scroll inside a clipped viewport.
/// WHY: .project-docs/decisions/2026-11-28-language-picker-scrolls-inside-panel.md
final class IslandLanguagePickerGridTests: XCTestCase {
    private typealias Layout = IslandLanguagePickerLayout

    /// Island widths around the notch-derived drawer width.
    private let widths: [CGFloat] = [300, 312, 328, 344]
    private let queries = ["", "e", "a", "span", "zzzz"]

    private func drawer(width: CGFloat) -> CGSize {
        CGSize(width: width, height: Layout.drawerHeight)
    }

    // MARK: Band and drawer height

    func test_languagePickerBandHoldsTheDrawerTheGridWasDesignedFor() {
        XCTAssertEqual(Layout.drawerHeight, 145, accuracy: 0.001)
        for mode in [IslandHoverPanelMode.languagePicker, .outputLanguagePicker] {
            for musicActive in [false, true] {
                let band = IslandView.hoverPanelHeight(for: mode, musicActive: musicActive)
                let music = musicActive
                    ? IslandDropModeControl.musicStripHeight + IslandDropModeControl.musicStripBottomGap
                    : 0
                // The rendered drawer is the band minus the gap (and the strip).
                XCTAssertEqual(
                    band - IslandDropModeControl.detachedPanelGap - music,
                    Layout.drawerHeight,
                    accuracy: 0.001,
                    "\(mode) music=\(musicActive)"
                )
            }
        }
    }

    // MARK: Curated grid

    func test_curatedGridsFitTheDrawerWithoutScrolling() {
        for width in widths {
            for leading in [IslandLanguageControl.autoOption(), IslandLanguageControl.offOption()] {
                let count = IslandLanguageControl.pickerOptions(leading: leading).count
                let grid = Layout.grid(panelSize: drawer(width: width), count: count, content: .fullGrid)

                XCTAssertFalse(grid.requiresScrolling, "width \(width)")
                XCTAssertEqual(grid.rowCount, 4, "width \(width)")
                XCTAssertEqual(grid.pinnedFrames.count, 1)
                XCTAssertEqual(grid.allFrames.count, count)
                assertInsidePanel(grid, panel: drawer(width: width))
            }
        }
    }

    func test_curatedGridWithManyLanguagesScrollsInsteadOfOverflowing() {
        let panel = drawer(width: 328)
        let grid = Layout.grid(panelSize: panel, count: AppLanguage.all.count + 1, content: .fullGrid)

        XCTAssertGreaterThan(grid.rowCount, 4)
        XCTAssertTrue(grid.requiresScrolling)
        assertScrollContent(grid, panel: panel)
    }

    // MARK: Search results

    func test_searchResultsRowCountsAndScrollingForSeveralQueries() {
        for width in widths {
            let panel = drawer(width: width)
            let perRow = filteredRowCapacity(panel: panel)
            XCTAssertGreaterThan(perRow, 0)

            for query in queries {
                let options = IslandLanguageControl.filteredOptions(
                    query: query,
                    leading: IslandLanguageControl.offOption()
                )
                let grid = Layout.grid(panelSize: panel, count: options.count, content: .filtered)
                let expectedRows = (options.count + perRow - 1) / perRow

                XCTAssertEqual(grid.rowCount, expectedRows, "query \(query) width \(width)")
                XCTAssertEqual(grid.flagFrames.count, options.count)
                XCTAssertTrue(grid.pinnedFrames.isEmpty)
                XCTAssertEqual(grid.requiresScrolling, expectedRows > 3, "query \(query) width \(width)")
                assertScrollContent(grid, panel: panel)
            }
        }
    }

    /// The owner's case: "e" in the output picker has five rows at the
    /// island width; only three fit, the rest scroll inside the drawer.
    func test_outputPickerQueryEScrollsFiveRowsInsideTheDrawer() {
        let panel = drawer(width: 328)
        let options = IslandLanguageControl.filteredOptions(
            query: "e",
            leading: IslandLanguageControl.offOption()
        )
        let grid = Layout.grid(panelSize: panel, count: options.count, content: .filtered)

        XCTAssertEqual(options.count, 33)
        XCTAssertEqual(grid.rowCount, 5)
        XCTAssertTrue(grid.requiresScrolling)
        let lastMaxY = try! XCTUnwrap(grid.flagFrames.map(\.maxY).max())
        XCTAssertGreaterThan(lastMaxY, panel.height, "would have drawn below the drawer")
        XCTAssertEqual(grid.contentHeight, lastMaxY + Layout.edgeInset - grid.viewport.minY, accuracy: 0.001)
    }

    func test_noMatchesHasNoFlagsAndNoScrolling() {
        let panel = drawer(width: 328)
        let count = IslandLanguageControl.filteredOptions(query: "zzzz").count
        let grid = Layout.grid(panelSize: panel, count: count, content: .filtered)

        XCTAssertEqual(count, 0)
        XCTAssertTrue(grid.flagFrames.isEmpty)
        XCTAssertFalse(grid.requiresScrolling)
        XCTAssertEqual(grid.contentHeight, grid.viewport.height, accuracy: 0.001)
    }

    func test_scrollBoundaryIsThreeFullSearchRows() {
        for width in widths {
            let panel = drawer(width: width)
            let perRow = filteredRowCapacity(panel: panel)
            let fits = Layout.grid(panelSize: panel, count: 3 * perRow, content: .filtered)
            let overflows = Layout.grid(panelSize: panel, count: 3 * perRow + 1, content: .filtered)

            XCTAssertFalse(fits.requiresScrolling, "width \(width)")
            XCTAssertEqual(fits.rowCount, 3)
            assertInsidePanel(fits, panel: panel)
            XCTAssertTrue(overflows.requiresScrolling, "width \(width)")
            XCTAssertEqual(overflows.rowCount, 4)
        }
    }

    func test_variantsFitInOneRowInsideTheViewport() {
        let panel = drawer(width: 328)
        let grid = Layout.grid(panelSize: panel, count: 7, content: .variants)

        XCTAssertEqual(grid.rowCount, 1)
        XCTAssertFalse(grid.requiresScrolling)
        assertInsidePanel(grid, panel: panel)
    }

    /// A short pane (e.g. a cramped Settings preview) scrolls the curated grid too.
    func test_shortPanelScrollsTheCuratedGrid() {
        let panel = CGSize(width: 328, height: 100)
        let grid = Layout.grid(
            panelSize: panel,
            count: IslandLanguageControl.pickerOptions().count,
            content: .fullGrid
        )

        XCTAssertTrue(grid.requiresScrolling)
        assertScrollContent(grid, panel: panel)
    }

    // MARK: Results contain each language once

    func test_resultsListEachLanguageOnce() {
        let allCodes = AppLanguage.all.map(\.code)
        XCTAssertEqual(Set(allCodes).count, allCodes.count, "duplicate language codes in the catalog")

        for leading in [IslandLanguageControl.autoOption(), IslandLanguageControl.offOption()] {
            let curated = IslandLanguageControl.pickerOptions(leading: leading).map(\.id)
            XCTAssertEqual(Set(curated).count, curated.count)

            for query in queries {
                let ids = IslandLanguageControl.filteredOptions(query: query, leading: leading).map(\.id)
                XCTAssertEqual(Set(ids).count, ids.count, "query \(query)")
            }
        }
    }

    /// The lone Spain flag under the "e" results is Galician, a different
    /// language that shares Spain's flag; it is not a duplicate entry.
    func test_queryEIncludesGalicianWithSpainsFlagAsItsOwnLanguage() {
        let options = IslandLanguageControl.filteredOptions(
            query: "e",
            leading: IslandLanguageControl.offOption()
        )
        let spainFlag = IslandLanguageControl.flag(forCountryCode: "ES")
        let sharingSpain = options.filter { $0.flag == spainFlag }.compactMap { $0.language?.code }

        XCTAssertEqual(sharingSpain, ["es", "gl"])
        XCTAssertEqual(options.last?.language?.code, "gl")
    }

    // MARK: Helpers

    private func filteredRowCapacity(panel: CGSize) -> Int {
        let grid = Layout.grid(panelSize: panel, count: 200, content: .filtered)
        let firstY = grid.flagFrames.first?.minY ?? 0
        return grid.flagFrames.filter { abs($0.minY - firstY) < 0.5 }.count
    }

    /// Everything is drawn within the panel; nothing needs scrolling.
    private func assertInsidePanel(
        _ grid: Layout.Grid,
        panel: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bounds = CGRect(origin: .zero, size: panel)
        for frame in grid.allFrames {
            XCTAssertTrue(bounds.contains(frame), "\(frame) outside \(bounds)", file: file, line: line)
        }
        for frame in grid.flagFrames {
            XCTAssertTrue(grid.viewport.contains(frame), "\(frame) outside viewport", file: file, line: line)
        }
    }

    /// Scrolling chips start inside the viewport, stay within the panel's
    /// width and within the scroll content, which ends one inset below them.
    private func assertScrollContent(
        _ grid: Layout.Grid,
        panel: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(grid.viewport.minY, grid.input.maxY, file: file, line: line)
        XCTAssertEqual(grid.viewport.maxY, panel.height, accuracy: 0.001, file: file, line: line)
        let content = CGRect(x: 0, y: 0, width: grid.viewport.width, height: grid.contentHeight)
        for frame in grid.flagFrames {
            XCTAssertGreaterThanOrEqual(frame.minY, grid.viewport.minY, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, panel.width, file: file, line: line)
            XCTAssertTrue(content.contains(grid.contentFrame(frame)), "\(frame) outside content", file: file, line: line)
        }
        if let lastMaxY = grid.flagFrames.map(\.maxY).max() {
            XCTAssertEqual(
                grid.requiresScrolling,
                lastMaxY + Layout.edgeInset > panel.height + 0.5,
                file: file,
                line: line
            )
        }
        for frame in grid.pinnedFrames {
            XCTAssertLessThanOrEqual(frame.maxY, grid.viewport.minY + 0.001, file: file, line: line)
        }
    }
}
