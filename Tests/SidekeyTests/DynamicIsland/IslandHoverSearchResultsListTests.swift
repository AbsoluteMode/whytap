import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The drawn row highlight must follow the selection the footer and Return
/// use, across query changes and arrow/hover moves (owner bug: "tra" kept the
/// highlight on the first row of the "t" results while the footer moved).
@MainActor
final class IslandHoverSearchResultsListTests: XCTestCase {
    @MainActor
    private final class State: ObservableObject {
        @Published var query: String
        @Published var selected = 0
        init(query: String) { self.query = query }
    }

    private struct Fixture: View {
        @ObservedObject var state: State
        let bridge: IslandHoverHitBridge

        var body: some View {
            ZStack(alignment: .top) {
                Color.black
                IslandHoverSearchResultsList(
                    query: state.query,
                    matches: IslandHoverToolSearch.results(for: state.query),
                    selectedIndex: state.selected,
                    bridge: bridge,
                    hitContext: state.query,
                    unreadNotifications: 0,
                    onActivate: { _ in },
                    onHover: { _, _, _ in }
                )
            }
        }
    }

    func testSelectionHelpersShareOneTool() {
        let matches = IslandHoverToolSearch.results(for: "tra")
        XCTAssertEqual(IslandHoverToolSearch.selectedTool(in: matches, at: 0), matches.first)
        XCTAssertNil(IslandHoverToolSearch.selectedTool(in: matches, at: matches.count))
        XCTAssertNil(IslandHoverToolSearch.selectedTool(in: [], at: 0))
        XCTAssertEqual(IslandHoverToolSearch.rowHighlight(isSelected: true, isPressed: false, isComingSoon: false), 0.13)
        XCTAssertEqual(IslandHoverToolSearch.rowHighlight(isSelected: false, isPressed: true, isComingSoon: false), 0.24)
        XCTAssertEqual(IslandHoverToolSearch.rowHighlight(isSelected: false, isPressed: false, isComingSoon: false), 0)
        XCTAssertEqual(IslandHoverToolSearch.rowHighlight(isSelected: true, isPressed: true, isComingSoon: true), 0)
    }

    func testDrawnHighlightFollowsQueryChangesAndSelectionMoves() throws {
        // No app runtime, store or user data; the window is never ordered or made key.
        _ = NSApplication.shared
        let size = CGSize(width: 300, height: 5 * (IslandHoverSearchResultsList.rowHeight + 2))
        let state = State(query: "t")
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: Fixture(state: state, bridge: IslandHoverHitBridge()))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        /// Index of the visible row whose left edge is drawn brighter than the others.
        func highlightedRow() throws -> Int? {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let brightness = (0..<4).map { row -> CGFloat in
                let y = (CGFloat(row) * (IslandHoverSearchResultsList.rowHeight + 2) + 4) * scale
                let color = bitmap.colorAt(x: Int(12 * scale), y: Int(y))?.usingColorSpace(.deviceRGB)
                return color?.brightnessComponent ?? 0
            }
            let lit = brightness.indices.filter { brightness[$0] > 0.05 }
            return lit.count == 1 ? lit[0] : nil
        }
        func settle(until expected: Int) throws -> Int? {
            let deadline = Date(timeIntervalSinceNow: 5)
            var row = try highlightedRow()
            while row != expected, Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                row = try highlightedRow()
            }
            return row
        }

        XCTAssertEqual(try settle(until: 0), 0, "Initial selection draws on the first row")
        // Typing narrows "t" to "tra"; the query change resets the selection (as IslandView does).
        state.query = "tr"
        state.query = "tra"
        XCTAssertEqual(try settle(until: 0), 0)
        // Arrow Down twice lands on Output Lang, the tool the footer shows.
        state.selected = 2
        XCTAssertEqual(IslandHoverToolSearch.results(for: "tra")[2], .outputLang)
        XCTAssertEqual(try settle(until: 2), 2, "The highlight must move with the selection")
        state.selected = 1
        XCTAssertEqual(try settle(until: 1), 1)
        XCTAssertFalse(window.isVisible)
    }
}
