import AppKit
import XCTest
@testable import Sidekey

/// Value-level contract for `NowPlayingSnapshot`: the radio/live-stream
/// detection (`isLive`) and the `withIsPlaying` copy. Pure, no I/O.
final class NowPlayingSnapshotTests: XCTestCase {

    private func makeSnapshot(duration: TimeInterval) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            app: .spotify,
            title: "Track",
            artist: "Artist",
            album: "Album",
            artwork: nil,
            elapsed: 0,
            duration: duration,
            isPlaying: true,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - isLive (radio / live stream detection)

    func test_isLive_trueWhenDurationIsZero() {
        XCTAssertTrue(makeSnapshot(duration: 0).isLive)
    }

    func test_isLive_trueWhenDurationIsNegative() {
        // Defensive: a malformed negative duration is no more seekable than 0.
        XCTAssertTrue(makeSnapshot(duration: -1).isLive)
    }

    func test_isLive_falseWhenDurationIsPositive() {
        XCTAssertFalse(makeSnapshot(duration: 200).isLive)
    }

    // MARK: - withIsPlaying copies every other field intact

    func test_withIsPlaying_flipsOnlyPlayState() {
        let original = makeSnapshot(duration: 200)
        let flipped = original.withIsPlaying(false)
        XCTAssertEqual(flipped.isPlaying, false)
        XCTAssertEqual(flipped.title, original.title)
        XCTAssertEqual(flipped.duration, original.duration)
        XCTAssertEqual(flipped.capturedAt, original.capturedAt)
    }

    // MARK: - progressFraction(at:) — extrapolation between event-driven snapshots

    /// The MediaRemote source publishes a snapshot only when the player emits an
    /// event; between events the position must be extrapolated from `capturedAt`
    /// so the wing's bar advances in real time instead of freezing until the
    /// next event (the "only updates on Pause" bug).
    private let capturedReference = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSnapshot(
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        capturedAt: Date
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            app: .spotify,
            title: "Track",
            artist: "Artist",
            album: "Album",
            artwork: nil,
            elapsed: elapsed,
            duration: duration,
            isPlaying: isPlaying,
            capturedAt: capturedAt
        )
    }

    func test_progressFractionAt_extrapolatesForwardWhilePlaying() {
        // elapsed 10 captured at T; 5 s later a playing track sits at 15/100.
        let snap = makeSnapshot(elapsed: 10, duration: 100, isPlaying: true, capturedAt: capturedReference)
        XCTAssertEqual(
            snap.progressFraction(at: capturedReference.addingTimeInterval(5)),
            0.15,
            accuracy: 0.0001
        )
    }

    func test_progressFractionAt_frozenWhilePaused() {
        // Paused: the bar must NOT creep forward as wall-clock time passes.
        let snap = makeSnapshot(elapsed: 10, duration: 100, isPlaying: false, capturedAt: capturedReference)
        XCTAssertEqual(
            snap.progressFraction(at: capturedReference.addingTimeInterval(5)),
            0.10,
            accuracy: 0.0001
        )
    }

    func test_progressFractionAt_clampsToOne() {
        // Extrapolation past the end clamps; the capsule never overshoots.
        let snap = makeSnapshot(elapsed: 95, duration: 100, isPlaying: true, capturedAt: capturedReference)
        XCTAssertEqual(
            snap.progressFraction(at: capturedReference.addingTimeInterval(20)),
            1,
            accuracy: 0.0001
        )
    }

    func test_progressFractionAt_zeroDurationIsZero() {
        // Radio / live stream: no finite length → no progress regardless of now.
        let snap = makeSnapshot(elapsed: 10, duration: 0, isPlaying: true, capturedAt: capturedReference)
        XCTAssertEqual(
            snap.progressFraction(at: capturedReference.addingTimeInterval(5)),
            0,
            accuracy: 0.0001
        )
    }

    func test_progressFractionAt_doesNotRunBackwardOnClockSkew() {
        // `now` earlier than `capturedAt` (clock skew) must not push the bar back.
        let snap = makeSnapshot(elapsed: 10, duration: 100, isPlaying: true, capturedAt: capturedReference)
        XCTAssertEqual(
            snap.progressFraction(at: capturedReference.addingTimeInterval(-5)),
            0.10,
            accuracy: 0.0001
        )
    }
}
