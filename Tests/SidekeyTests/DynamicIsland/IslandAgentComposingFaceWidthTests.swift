import XCTest
@testable import Sidekey

@MainActor
final class IslandAgentComposingFaceWidthTests: XCTestCase {
    /// The composing capsule hugs the placeholder when empty (and for any text
    /// narrower than it), so the field never looks cramped on open.
    func testFloorsAtPlaceholderForShortText() {
        let empty = IslandAgentWingView.composingFaceWidth(text: "")
        let short = IslandAgentWingView.composingFaceWidth(text: "hi")
        XCTAssertEqual(empty, short, accuracy: 0.5, "short text stays at the placeholder floor")
        XCTAssertLessThan(empty, IslandFrameLayout.agentWingComposingWidth)
    }

    /// As the typed text outgrows the placeholder the capsule grows with it —
    /// the recording-face pattern, now applied to composing.
    func testGrowsWithTypedText() {
        let floor = IslandAgentWingView.composingFaceWidth(text: "")
        let grown = IslandAgentWingView.composingFaceWidth(
            text: "tell me about the weather today"
        )
        XCTAssertGreaterThan(grown, floor, "capsule grows past the floor with longer text")
        XCTAssertLessThanOrEqual(grown, IslandFrameLayout.agentWingComposingWidth)
    }

    /// Past the cap the capsule stops growing; the field then scrolls to the
    /// caret (the tail-visibility fix) instead of widening forever.
    func testCapsAtComposingWidth() {
        let huge = IslandAgentWingView.composingFaceWidth(
            text: String(repeating: "x", count: 500)
        )
        XCTAssertEqual(huge, IslandFrameLayout.agentWingComposingWidth)
    }
}
