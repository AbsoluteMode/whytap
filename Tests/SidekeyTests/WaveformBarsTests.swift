import XCTest
import SwiftUI
@testable import Sidekey

final class WaveformBarsTests: XCTestCase {
    private let maxBarHeight: CGFloat = 16
    private let barCount = 22

    func testProcessingCenterBarHasNonZeroHeight() {
        // Even with empty levels, processing mode should produce visible decorative bars.
        let center = barCount / 2
        let h = WaveformBars.barHeight(
            index: center,
            barCount: barCount,
            time: 1.0,
            mode: .processing,
            levels: [],
            maxBarHeight: maxBarHeight
        )
        XCTAssertGreaterThan(h, 0)
    }

    func testGaussianTaperEdgeLessThanCenter() {
        // Average over a few time points to remove instantaneous wave noise.
        let times: [Double] = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
        var centerSum: CGFloat = 0
        var edgeSum: CGFloat = 0
        let center = barCount / 2
        let edge = 0
        for t in times {
            centerSum += WaveformBars.barHeight(
                index: center,
                barCount: barCount,
                time: t,
                mode: .processing,
                levels: [],
                maxBarHeight: maxBarHeight
            )
            edgeSum += WaveformBars.barHeight(
                index: edge,
                barCount: barCount,
                time: t,
                mode: .processing,
                levels: [],
                maxBarHeight: maxBarHeight
            )
        }
        XCTAssertGreaterThan(centerSum, edgeSum)
    }

    func testRecordingEmptyLevelsStillProducesFloor() {
        // With empty levels, recording mode falls back to a small floor so bars stay visible.
        let center = barCount / 2
        let h = WaveformBars.barHeight(
            index: center,
            barCount: barCount,
            time: 0.0,
            mode: .recording,
            levels: [],
            maxBarHeight: maxBarHeight
        )
        XCTAssertGreaterThanOrEqual(h, 0.05 * maxBarHeight - 0.001)
    }

    func testBarOpacityLowest() {
        XCTAssertEqual(WaveformBars.barOpacity(index: 0, barCount: 22, normalizedHeight: 0), 0.4, accuracy: 1e-6)
    }

    func testBarOpacityHighest() {
        XCTAssertEqual(WaveformBars.barOpacity(index: 0, barCount: 22, normalizedHeight: 1), 1.0, accuracy: 1e-6)
    }

    func testBarOpacityMidpoint() {
        XCTAssertEqual(WaveformBars.barOpacity(index: 0, barCount: 22, normalizedHeight: 0.5), 0.7, accuracy: 1e-6)
    }

    func testBarOpacityClampsAboveOne() {
        XCTAssertEqual(WaveformBars.barOpacity(index: 0, barCount: 22, normalizedHeight: 1.5), 1.0, accuracy: 1e-6)
    }

    func testBarOpacityClampsBelowZero() {
        XCTAssertEqual(WaveformBars.barOpacity(index: 0, barCount: 22, normalizedHeight: -0.5), 0.4, accuracy: 1e-6)
    }
}
