import XCTest
@testable import Sidekey

/// Proves the shared byte-level download-progress aggregator surfaces REAL
/// downloaded-bytes/total-bytes — monotonic and proportional to bytes — instead
/// of the coarse file-count weighting that made the bar jump (e.g. 2%→57%) when
/// a HuggingFace snapshot mixes tiny JSON/config files with one multi-GB weights
/// shard. See `ModelDownloadByteProgress`.
final class ModelDownloadByteProgressTests: XCTestCase {

    /// A snapshot with five tiny files (1 KB each) and one huge 2 GB shard.
    /// File-count weighting would report 5/6 ≈ 83% before a single weights byte
    /// lands. Byte weighting must keep the fraction near zero until the shard
    /// actually downloads, then advance proportionally to bytes written.
    func testFractionTracksBytesNotFileCount() {
        let tiny: Int64 = 1_024
        let huge: Int64 = 2_000_000_000
        let total = tiny * 5 + huge

        var aggregator = ModelDownloadByteProgress(totalBytes: total)

        // All five tiny files complete first. Byte fraction must stay tiny
        // (the opposite of file-count weighting reporting ~83%).
        let afterTinyFiles = aggregator.update(downloadedBytes: tiny * 5)
        XCTAssertLessThan(
            afterTinyFiles, 0.001,
            "Five 1 KB files out of a 2 GB snapshot must read as ~0%, not 83%"
        )

        // The big shard streams in. Each step must advance proportionally to the
        // bytes actually written — no 2%→57% leap.
        let quarter = aggregator.update(downloadedBytes: tiny * 5 + huge / 4)
        let half = aggregator.update(downloadedBytes: tiny * 5 + huge / 2)
        let threeQuarter = aggregator.update(downloadedBytes: tiny * 5 + huge * 3 / 4)

        XCTAssertEqual(quarter, 0.25, accuracy: 0.001)
        XCTAssertEqual(half, 0.5, accuracy: 0.001)
        XCTAssertEqual(threeQuarter, 0.75, accuracy: 0.001)

        // No single step leaps more than its byte share warrants.
        XCTAssertEqual(half - quarter, 0.25, accuracy: 0.001)
        XCTAssertEqual(threeQuarter - half, 0.25, accuracy: 0.001)
    }

    /// Disk-size samples can momentarily dip (a temp file is moved/replaced) or
    /// the library may re-report a lower running total. The user-facing bar must
    /// never move backwards.
    func testFractionIsMonotonic() {
        var aggregator = ModelDownloadByteProgress(totalBytes: 1_000)

        let high = aggregator.update(downloadedBytes: 600)
        let dip = aggregator.update(downloadedBytes: 400)
        let recover = aggregator.update(downloadedBytes: 500)

        XCTAssertEqual(high, 0.6, accuracy: 0.0001)
        XCTAssertEqual(dip, 0.6, accuracy: 0.0001, "fraction must not regress on a dip")
        XCTAssertEqual(recover, 0.6, accuracy: 0.0001, "still capped at the prior peak")
    }

    /// The fraction is clamped to [0, 1) so an over-count (disk size briefly
    /// exceeding the listed remote total, e.g. metadata files) never reports a
    /// premature 100% that would let the UI flip to "ready" before load.
    func testFractionClampsBelowOne() {
        var aggregator = ModelDownloadByteProgress(totalBytes: 1_000)

        let over = aggregator.update(downloadedBytes: 5_000)

        XCTAssertGreaterThan(over, 0.98)
        XCTAssertLessThanOrEqual(over, 0.99)
    }

    /// A zero/unknown total must degrade gracefully to 0 rather than divide by
    /// zero or report NaN — the caller falls back to the library fraction.
    func testZeroTotalReportsZero() {
        var aggregator = ModelDownloadByteProgress(totalBytes: 0)

        XCTAssertEqual(aggregator.update(downloadedBytes: 123), 0, accuracy: 0.0001)
    }

    /// Updates are coalesced: a change smaller than the throttle step returns the
    /// same value (and signals "no emit") so the UI isn't spammed, while the
    /// underlying source stays real bytes.
    func testSubStepUpdatesAreCoalesced() {
        var aggregator = ModelDownloadByteProgress(totalBytes: 100_000, minimumStep: 0.01)

        let first = aggregator.updateIfChanged(downloadedBytes: 5_000)   // 5%
        let withinStep = aggregator.updateIfChanged(downloadedBytes: 5_500) // 5.5% (<1% step)
        let pastStep = aggregator.updateIfChanged(downloadedBytes: 6_200)  // 6.2% (>1% step)

        XCTAssertEqual(first ?? -1, 0.05, accuracy: 0.0001)
        XCTAssertNil(withinStep, "a sub-step change must not emit")
        XCTAssertEqual(pastStep ?? -1, 0.062, accuracy: 0.0001)
    }
}
