import XCTest
@testable import Sidekey

/// Pure-logic contract for the synthetic equalizer's bar SHAPE. The motion
/// itself now lives on the CoreAnimation render server (see
/// `IslandMusicEqualizerView`), but the deterministic inputs — the
/// center-weighted target distribution and the normalized→scale mapping with a
/// minimum visible sliver — stay unit-pinned.
final class IslandMusicEqualizerTests: XCTestCase {

    // MARK: - centerBoost: center bars trend taller than edges

    func test_centerBoost_isFullAtCenterAndLowerAtEdges() {
        // 5 bars, indices 0...4, center = 2.
        XCTAssertEqual(IslandMusicEqualizer.centerBoost(forBar: 2, count: 5), 1.0, accuracy: 0.0001)
        // Edges are symmetric and below the center.
        let left = IslandMusicEqualizer.centerBoost(forBar: 0, count: 5)
        let right = IslandMusicEqualizer.centerBoost(forBar: 4, count: 5)
        XCTAssertEqual(left, right, accuracy: 0.0001)
        XCTAssertLessThan(left, 1.0)
        // A bar between edge and center sits between the two.
        let mid = IslandMusicEqualizer.centerBoost(forBar: 1, count: 5)
        XCTAssertGreaterThan(mid, left)
        XCTAssertLessThan(mid, 1.0)
    }

    func test_centerBoost_singleBarIsFull() {
        XCTAssertEqual(IslandMusicEqualizer.centerBoost(forBar: 0, count: 1), 1.0, accuracy: 0.0001)
    }

    // MARK: - randomTargets: count + range

    func test_randomTargets_hasRequestedCountWithinUnitRange() {
        let targets = IslandMusicEqualizer.randomTargets(count: 5)
        XCTAssertEqual(targets.count, 5)
        for t in targets {
            XCTAssertGreaterThan(t, 0.0)
            XCTAssertLessThanOrEqual(t, 1.0)
        }
    }

    func test_randomTargets_zeroCountIsEmpty() {
        XCTAssertEqual(IslandMusicEqualizer.randomTargets(count: 0), [])
    }

    // MARK: - barScaleY: normalized height → layer scale with a minimum sliver

    func test_barScaleY_mapsFullHeightToOne() {
        XCTAssertEqual(IslandMusicEqualizer.barScaleY(normalized: 1.0), 1.0, accuracy: 0.0001)
    }

    func test_barScaleY_flooredAtMinimumSliver() {
        let minScale = IslandMusicEqualizer.minBarHeight / IslandMusicEqualizer.slotHeight
        XCTAssertEqual(IslandMusicEqualizer.barScaleY(normalized: 0.0), minScale, accuracy: 0.0001)
    }

    func test_barScaleY_clampsAboveOne() {
        XCTAssertEqual(IslandMusicEqualizer.barScaleY(normalized: 1.5), 1.0, accuracy: 0.0001)
    }
}
