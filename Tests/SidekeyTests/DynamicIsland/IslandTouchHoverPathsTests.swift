import AppKit
import XCTest
@testable import Sidekey

/// Hover-only paths and small targets on a touch display (macOS 27). Every
/// rule here applies only during an island touch session; the pointer keeps
/// exactly what it had.
@MainActor
final class IslandTouchHoverPathsTests: XCTestCase {

    // MARK: - First tap reveals, second acts (History, To-do)

    func test_withoutATouchSessionEveryTapActsAtOnce() {
        let reveal = IslandTouchReveal()
        XCTAssertFalse(reveal.revealsOnTap("history:1", touchSessionActive: false))
        XCTAssertFalse(reveal.revealsOnTap("history:1", touchSessionActive: false))
        XCTAssertNil(reveal.revealedID)
        XCTAssertFalse(reveal.isRevealed("history:1", touchSessionActive: false))
    }

    func test_firstTapRevealsTheRowAndTheSecondActs() {
        let reveal = IslandTouchReveal()
        XCTAssertTrue(reveal.revealsOnTap("todo:a", touchSessionActive: true))
        XCTAssertTrue(reveal.isRevealed("todo:a", touchSessionActive: true))
        XCTAssertFalse(reveal.revealsOnTap("todo:a", touchSessionActive: true), "second tap completes")
    }

    func test_tappingAnotherRowMovesTheRevealThere() {
        let reveal = IslandTouchReveal()
        _ = reveal.revealsOnTap("history:1", touchSessionActive: true)
        XCTAssertTrue(reveal.revealsOnTap("history:2", touchSessionActive: true))
        XCTAssertFalse(reveal.isRevealed("history:1", touchSessionActive: true))
        XCTAssertTrue(reveal.isRevealed("history:2", touchSessionActive: true))
    }

    func test_endingTheSessionForgetsTheReveal() {
        let reveal = IslandTouchReveal()
        _ = reveal.revealsOnTap("todo:a", touchSessionActive: true)
        XCTAssertFalse(reveal.isRevealed("todo:a", touchSessionActive: false),
                       "a pointer after the session never sees a touch reveal")
        reveal.clear()
        XCTAssertNil(reveal.revealedID)
        XCTAssertTrue(reveal.revealsOnTap("todo:a", touchSessionActive: true),
                      "the next session starts with a reveal again")
    }

    // MARK: - 36 pt hit areas

    func test_smallControlGrowsTo36PointsAroundItsCenter() {
        let region = CGRect(x: 0, y: 0, width: 400, height: 300)
        let back = CGRect(x: 100, y: 100, width: 24, height: 20)
        let grown = IslandTouchHitGeometry.grown(back, minimumSide: 36, within: region)
        XCTAssertEqual(grown.width, 36, accuracy: 0.001)
        XCTAssertEqual(grown.height, 36, accuracy: 0.001)
        XCTAssertEqual(grown.midX, back.midX, accuracy: 0.001)
        XCTAssertEqual(grown.midY, back.midY, accuracy: 0.001)
    }

    func test_largeControlKeepsItsFrame() {
        let region = CGRect(x: 0, y: 0, width: 400, height: 300)
        let tile = CGRect(x: 12, y: 8, width: 90, height: 68)
        XCTAssertEqual(IslandTouchHitGeometry.grown(tile, minimumSide: 36, within: region), tile)
    }

    func test_grownAreaNeverLeavesItsVisibleRegion() {
        let region = CGRect(x: 0, y: 0, width: 300, height: 200)
        let corner = CGRect(x: 2, y: 2, width: 20, height: 20)
        let grown = IslandTouchHitGeometry.grown(corner, minimumSide: 36, within: region)
        XCTAssertTrue(region.contains(grown))
        XCTAssertTrue(grown.contains(corner))
    }

    func test_zeroMinimumIsThePointerAndChangesNothing() {
        let region = CGRect(x: 0, y: 0, width: 300, height: 200)
        let small = CGRect(x: 50, y: 50, width: 10, height: 10)
        XCTAssertEqual(IslandTouchHitGeometry.grown(small, minimumSide: 0, within: region), small)
    }

    func test_aTouchOnTheDrawnControlAlwaysPicksIt() {
        let a = CGRect(x: 0, y: 0, width: 20, height: 20)
        let b = CGRect(x: 22, y: 0, width: 20, height: 20)
        let region = CGRect(x: -100, y: -100, width: 300, height: 300)
        let grown = [a, b].map { IslandTouchHitGeometry.grown($0, minimumSide: 36, within: region) }
        // 19,10 is inside a; b's grown area covers it too.
        XCTAssertTrue(grown[1].contains(CGPoint(x: 19, y: 10)))
        XCTAssertEqual(IslandTouchHitGeometry.target(at: CGPoint(x: 19, y: 10), exact: [a, b], grown: grown), 0)
    }

    func test_aTouchBetweenControlsPicksTheNearest() {
        let a = CGRect(x: 0, y: 0, width: 20, height: 20)
        let b = CGRect(x: 30, y: 0, width: 20, height: 20)
        let region = CGRect(x: -100, y: -100, width: 300, height: 300)
        let grown = [a, b].map { IslandTouchHitGeometry.grown($0, minimumSide: 36, within: region) }
        XCTAssertEqual(IslandTouchHitGeometry.target(at: CGPoint(x: 23, y: 10), exact: [a, b], grown: grown), 0)
        XCTAssertEqual(IslandTouchHitGeometry.target(at: CGPoint(x: 28, y: 10), exact: [a, b], grown: grown), 1)
        XCTAssertNil(IslandTouchHitGeometry.target(at: CGPoint(x: 200, y: 10), exact: [a, b], grown: grown))
    }

    // MARK: - Measured down/up dispatch

    private func snapshot(_ frame: CGRect, drawn: CGRect? = nil, tool: HoverTool) -> IslandHoverHitSnapshot {
        IslandHoverHitSnapshot(owner: UUID(), id: IslandHoverHitTargetID(surface: .tile, tool: tool),
                               context: "", frame: frame, drawnFrame: drawn)
    }

    func test_pointerTrackingIsUnchangedWithoutTouchFrames() {
        let tool = HoverTool.allCases[0]
        var tracking = IslandHoverPointerTracking()
        let target = snapshot(CGRect(x: 0, y: 0, width: 20, height: 20), tool: tool)
        XCTAssertFalse(tracking.begin(at: CGPoint(x: 25, y: 10), targets: [target], enabled: true),
                       "a pointer just outside a small control misses it, as before")
        XCTAssertTrue(tracking.begin(at: CGPoint(x: 10, y: 10), targets: [target], enabled: true))
        XCTAssertEqual(tracking.captured, target)
    }

    func test_touchTrackingTakesTheGrownAreaAndPrefersTheDrawnControl() {
        let tools = Array(HoverTool.allCases.prefix(2))
        let a = CGRect(x: 0, y: 0, width: 20, height: 20)
        let b = CGRect(x: 22, y: 0, width: 20, height: 20)
        let region = CGRect(x: -100, y: -100, width: 300, height: 300)
        let targets = [
            snapshot(IslandTouchHitGeometry.grown(a, minimumSide: 36, within: region), drawn: a, tool: tools[0]),
            snapshot(IslandTouchHitGeometry.grown(b, minimumSide: 36, within: region), drawn: b, tool: tools[1]),
        ]
        var tracking = IslandHoverPointerTracking()
        XCTAssertTrue(tracking.begin(at: CGPoint(x: 10, y: 26), targets: targets, enabled: true),
                      "6 pt above a 20 pt control is still that control")
        XCTAssertEqual(tracking.captured?.id.tool, tools[0])
        XCTAssertTrue(tracking.begin(at: CGPoint(x: 19, y: 10), targets: targets, enabled: true))
        XCTAssertEqual(tracking.captured?.id.tool, tools[0])
        XCTAssertFalse(tracking.begin(at: CGPoint(x: 10, y: 10), targets: targets, enabled: false))
    }

    // MARK: - Drawer width independent of the cutout

    private func screen(cutout: CGFloat, touch: Bool) -> IslandScreenDescriptor {
        let width: CGFloat = 1512
        let left = (width - cutout) / 2
        return IslandScreenDescriptor(
            uuid: "s", frame: NSRect(x: 0, y: 0, width: width, height: 993),
            visibleFrame: NSRect(x: 0, y: 70, width: width, height: 891),
            safeAreaTopInset: 32,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 961, width: left, height: 32),
            auxiliaryTopRightArea: NSRect(x: left + cutout, y: 961, width: left, height: 32),
            isBuiltIn: true, isTouchCapable: touch)
    }

    func test_narrowCutoutOnATouchDisplayKeepsTheFullDrawerCentered() {
        for cutout: CGFloat in [90, 125, 150] {
            let island = IslandFrameLayout.islandFrame(on: screen(cutout: cutout, touch: true))
            XCTAssertEqual(island.width, 310, accuracy: 0.001, "cutout \(cutout)")
            XCTAssertEqual(island.midX, 756, accuracy: 0.001, "still centered on the camera")
            XCTAssertEqual(IslandFrameLayout.capsuleGapWidth(on: screen(cutout: cutout, touch: true)),
                           IslandFrameLayout.syntheticNotchWidth, accuracy: 0.001)
        }
    }

    func test_wideCutoutOnATouchDisplayIsWrappedAsBefore() {
        let island = IslandFrameLayout.islandFrame(on: screen(cutout: 200, touch: true))
        XCTAssertEqual(island.width, 70 + 200 + 70, accuracy: 0.001)
    }

    func test_screenWithoutTouchKeepsItsCutoutWidth() {
        let island = IslandFrameLayout.islandFrame(on: screen(cutout: 90, touch: false))
        XCTAssertEqual(island.width, 70 + 90 + 70, accuracy: 0.001)
        XCTAssertEqual(island.midX, 756, accuracy: 0.001)
        XCTAssertEqual(IslandFrameLayout.capsuleGapWidth(on: screen(cutout: 90, touch: false)), 90, accuracy: 0.001)
    }
}
