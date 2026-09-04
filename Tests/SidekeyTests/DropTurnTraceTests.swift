import XCTest
@testable import Sidekey

@MainActor
final class DropTurnTraceTests: XCTestCase {
    /// A normal-but-failed turn: records phase timeline + counters and emits
    /// privacy-safe metadata with millisecond offsets from the turn start.
    func test_metadata_includes_turn_id_last_phase_and_phase_offsets() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let trace = DropTurnTrace(turnId: "abc", start: t0)
        trace.mark(.recording, at: t0.addingTimeInterval(0.5))
        trace.recordToken(at: t0.addingTimeInterval(1.0))
        trace.recordToken(at: t0.addingTimeInterval(1.2))
        trace.mark(.stopRequested, at: t0.addingTimeInterval(3.0))

        let md = trace.metadata(
            outcome: "failed",
            reason: "streaming_watchdogTimeout",
            at: t0.addingTimeInterval(13.0)
        )

        XCTAssertEqual(md["turn_id"] as? String, "abc")
        XCTAssertEqual(md["mode"] as? String, "voice")
        XCTAssertEqual(md["flow"] as? String, "drop")
        XCTAssertEqual(md["outcome"] as? String, "failed")
        XCTAssertEqual(md["reason"] as? String, "streaming_watchdogTimeout")
        XCTAssertEqual(md["last_phase"] as? String, "stop_requested")
        XCTAssertEqual(md["token_count"] as? Int, 2)
        XCTAssertEqual(md["stop_requested"] as? Bool, true)
        XCTAssertEqual(md["recording_ms"] as? Int, 500)
        XCTAssertEqual(md["first_token_ms"] as? Int, 1000)
        XCTAssertEqual(md["stop_requested_ms"] as? Int, 3000)
        XCTAssertEqual(md["total_ms"] as? Int, 13000)
    }

    /// The smoking-gun case: a turn that hangs BEFORE the user's release is
    /// detected. `stop_requested` is false, `last_phase` is `recording`, and no
    /// token ever arrived — this is what the turn-watchdog reports for an
    /// otherwise event-less infinite hang.
    func test_stuck_before_stop_reports_recording_and_no_stop_no_token() {
        let t0 = Date(timeIntervalSince1970: 0)
        let trace = DropTurnTrace(turnId: "x", start: t0)
        trace.mark(.recording, at: t0.addingTimeInterval(0.4))

        let md = trace.metadata(outcome: "stuck", reason: "turn_watchdog", at: t0.addingTimeInterval(75))

        XCTAssertEqual(md["last_phase"] as? String, "recording")
        XCTAssertEqual(md["stop_requested"] as? Bool, false)
        XCTAssertEqual(md["token_count"] as? Int, 0)
        XCTAssertNil(md["first_token_ms"], "no token arrived → offset absent")
        XCTAssertNil(md["stop_requested_ms"], "stop never requested → offset absent")
    }

    /// `lastPhase` is the furthest checkpoint reached regardless of mark order,
    /// and the first stamp for a phase wins (later duplicate marks are ignored).
    func test_last_phase_is_furthest_reached_and_first_stamp_wins() {
        let t0 = Date(timeIntervalSince1970: 0)
        let trace = DropTurnTrace(turnId: "x", start: t0)
        trace.mark(.stopRequested, at: t0.addingTimeInterval(5))
        trace.mark(.recording, at: t0.addingTimeInterval(1))
        trace.mark(.recording, at: t0.addingTimeInterval(9)) // ignored: first wins

        XCTAssertEqual(trace.lastPhase, .stopRequested)
        let md = trace.metadata(outcome: "failed", at: t0.addingTimeInterval(6))
        XCTAssertEqual(md["recording_ms"] as? Int, 1000)
    }

    /// Privacy invariant (#3): the trace never carries transcript text — only
    /// counts, offsets, ids and enum labels. Regression guard for the #350 leak
    /// where `String(describing: wing)` serialized the live transcript.
    func test_metadata_never_includes_transcript_text() {
        let trace = DropTurnTrace(turnId: "x", start: Date(timeIntervalSince1970: 0))
        trace.recordToken()

        let md = trace.metadata(outcome: "completed")

        XCTAssertNil(md["transcript"])
        XCTAssertNil(md["text"])
        XCTAssertEqual(md["token_count"] as? Int, 1)
    }
}
