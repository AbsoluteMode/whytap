import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class IslandAgentComposerPanelTests: XCTestCase {
    /// A text query longer than the composer width must keep its TAIL (the
    /// caret) visible, not pin the first characters. The single-line text view
    /// lives in a horizontally-scrolling `NSScrollView`; once the caret moves
    /// to the end of an overflowing string the clip view scrolls so the tail is
    /// revealed. Regression for the composer clipping the end of long input.
    func testLongQueryScrollsTailIntoView() {
        let panel = IslandAgentComposerPanel()
        panel.layoutForTesting(width: 160, height: 30)

        let textView = panel.composerTextViewForTesting
        guard let scrollView = textView.enclosingScrollView else {
            return XCTFail(
                "composer text view must live in an NSScrollView for caret-following horizontal scroll"
            )
        }

        // Config that lets the line extend past the visible width and scroll.
        XCTAssertEqual(textView.textContainer?.widthTracksTextView, false)
        XCTAssertTrue(textView.isHorizontallyResizable)
        XCTAssertEqual(textView.textContainer?.maximumNumberOfLines, 1)

        textView.string = String(repeating: "abcdefghij ", count: 30)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        scrollView.layoutSubtreeIfNeeded()
        textView.scrollRangeToVisible(textView.selectedRange())

        XCTAssertGreaterThan(
            scrollView.documentVisibleRect.origin.x, 0,
            "tail of an overflowing query should be scrolled into view, not clipped at the start"
        )
    }
}
