import XCTest
@testable import Sidekey

/// Coverage for the unified Drop delivery ladder (`AppDelegate.resolveDelivery`).
/// Pure state-machine driven by injected closures (no AppKit). Ladder:
/// full realtime → batch → raw partial → deliveryFailed → idle.
@MainActor
final class DropDeliveryResolverTests: XCTestCase {

    private final class Recorder {
        var phases: [AppPhase] = []
        var delivered: [String] = []      // full, via /api/process
        var pastedRaw: [String] = []      // raw partial, direct
        var failureReasons: [String] = []
        var retainedAudio: Data?
        var clearedPending = false
        /// Whether the simulated raw-partial paste lands. False models a
        /// pasteboard-write / modifier-timeout failure (AutoPasteEngine.paste → false).
        var pasteRawSucceeds = true

        func sink() -> AppDelegate.DropBatchRecoverySink {
            AppDelegate.DropBatchRecoverySink(
                setPhase: { [weak self] in self?.phases.append($0) },
                deliver: { [weak self] t in self?.delivered.append(t); self?.phases.append(.idle) },
                retainForRetry: { [weak self] pcm in self?.retainedAudio = pcm },
                clearPendingRetry: { [weak self] in self?.clearedPending = true },
                failTelemetry: { [weak self] r in self?.failureReasons.append(r) },
                pasteRaw: { [weak self] t in
                    guard let self else { return false }
                    self.pastedRaw.append(t)
                    // Mirror production: only a successful paste parks `.idle`.
                    if self.pasteRawSucceeds { self.phases.append(.idle); return true }
                    return false
                }
            )
        }
    }
    private let pcm = Data([0x01, 0x02, 0x03, 0x04])

    func test_full_realtime_transcript_delivers_via_process() async {
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .transcript("hello world"), capturedPCM: pcm, lastPartial: "hel",
            hasBatchTranscriber: true, transcribe: { _ in "SHOULD NOT RUN" }, sink: rec.sink())
        XCTAssertEqual(rec.delivered, ["hello world"])
        XCTAssertTrue(rec.pastedRaw.isEmpty)
    }

    func test_full_realtime_success_clears_stale_pending_retry() async {
        // Rung 1 (realtime) success must clear any retry armed by a PRIOR failed
        // take — parity with the batch rung (which clears on success). Otherwise
        // stale PCM lingers across turns (matters once a Close keeps audio armed).
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .transcript("hello"), capturedPCM: pcm, lastPartial: "",
            hasBatchTranscriber: true, transcribe: { _ in "SHOULD NOT RUN" }, sink: rec.sink())
        XCTAssertEqual(rec.delivered, ["hello"])
        XCTAssertTrue(
            rec.clearedPending,
            "rung 1 realtime success must clear stale pending retry"
        )
    }

    func test_cancelled_never_delivers() async {
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .cancelled, capturedPCM: pcm, lastPartial: "abc",
            hasBatchTranscriber: true, transcribe: { _ in "x" }, sink: rec.sink())
        XCTAssertTrue(rec.delivered.isEmpty)
        XCTAssertTrue(rec.pastedRaw.isEmpty)
        XCTAssertEqual(rec.phases.last, .idle)
    }

    func test_degraded_batch_success_delivers_full() async {
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "partial text",
            hasBatchTranscriber: true, transcribe: { _ in "full clean text" }, sink: rec.sink())
        XCTAssertEqual(rec.delivered, ["full clean text"])
        XCTAssertTrue(rec.pastedRaw.isEmpty, "Full batch wins; raw partial must not fire.")
        XCTAssertEqual(rec.phases.first, .finishing)
        XCTAssertTrue(rec.clearedPending)
    }

    func test_degraded_batch_throws_salvages_raw_partial() async {
        let rec = Recorder()
        struct Offline: Error {}
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "salvage me",
            hasBatchTranscriber: true, transcribe: { _ in throw Offline() }, sink: rec.sink())
        XCTAssertEqual(rec.pastedRaw, ["salvage me"], "Offline batch → raw partial salvage.")
        XCTAssertTrue(rec.delivered.isEmpty)
        XCTAssertFalse(rec.phases.contains(.deliveryFailed), "Salvage avoids the paralysis state.")
    }

    func test_salvage_paste_failure_falls_to_deliveryFailed() async {
        // Offline batch + non-empty partial, but the raw-partial PASTE fails
        // (pasteboard write / modifier timeout → AutoPasteEngine.paste == false):
        // must NOT silently idle — retain the audio + flip to .deliveryFailed so
        // the user can retry. Never silently lose the dictation.
        let rec = Recorder()
        rec.pasteRawSucceeds = false
        struct Offline: Error {}
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "salvage me",
            hasBatchTranscriber: true, transcribe: { _ in throw Offline() }, sink: rec.sink())
        XCTAssertEqual(rec.pastedRaw, ["salvage me"], "paste was attempted")
        XCTAssertEqual(rec.retainedAudio, pcm, "failed salvage paste must retain audio for retry")
        XCTAssertEqual(rec.phases.last, .deliveryFailed, "failed salvage paste must not silently idle")
    }

    func test_degraded_batch_throws_no_partial_goes_deliveryFailed() async {
        let rec = Recorder()
        struct Offline: Error {}
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "",
            hasBatchTranscriber: true, transcribe: { _ in throw Offline() }, sink: rec.sink())
        XCTAssertTrue(rec.pastedRaw.isEmpty)
        XCTAssertEqual(rec.retainedAudio, pcm, "No partial → retain audio for manual Retry.")
        XCTAssertEqual(rec.phases.last, .deliveryFailed)
    }

    // MARK: - Empty batch transcript (provider heard no speech) ≠ offline

    func test_degraded_batch_empty_transcript_idles_without_arming_retry() async {
        // The batch POST SUCCEEDED and came back with an EMPTY transcript: the
        // audio reached the provider and it heard no speech. That is silence,
        // not a delivery failure — arming Retry re-uploads the same silent PCM
        // and returns empty again, so the "Couldn't deliver — offline" pill can
        // only mislead. Idle quietly like rung 1's silence guard, and report the
        // distinct `degraded_empty` reason so prod can tell silence from
        // transport failures (they were both logged as degraded_batch_failed).
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "",
            hasBatchTranscriber: true, transcribe: { _ in "" }, sink: rec.sink())
        XCTAssertNil(rec.retainedAudio, "empty batch must not arm a Retry that can only fail again")
        XCTAssertEqual(rec.phases.last, .idle, "silence must not park the terminal .deliveryFailed pill")
        XCTAssertEqual(rec.failureReasons, ["degraded_empty"])
        XCTAssertTrue(rec.delivered.isEmpty)
        XCTAssertTrue(rec.pastedRaw.isEmpty)
    }

    func test_empty_batch_with_failed_partial_paste_idles_without_arming_retry() async {
        // Empty batch + a partial whose paste failed: the dictation is lost
        // either way, but a Retry would re-run the SAME batch that just returned
        // empty. Idle instead of parking .deliveryFailed — the reason still
        // distinguishes the failed paste.
        let rec = Recorder()
        rec.pasteRawSucceeds = false
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "partial",
            hasBatchTranscriber: true, transcribe: { _ in "" }, sink: rec.sink())
        XCTAssertEqual(rec.pastedRaw, ["partial"], "paste was attempted")
        XCTAssertNil(rec.retainedAudio, "an empty batch makes Retry pointless — do not arm it")
        XCTAssertEqual(rec.phases.last, .idle)
        XCTAssertEqual(rec.failureReasons, ["salvaged_partial_paste_failed"])
    }

    func test_empty_batch_still_salvages_a_live_partial() async {
        // No-regression guard: an empty batch with a salvageable partial must
        // still paste it (rung 3). Only the no-partial tail changes.
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "salvage me",
            hasBatchTranscriber: true, transcribe: { _ in "" }, sink: rec.sink())
        XCTAssertEqual(rec.pastedRaw, ["salvage me"])
        XCTAssertEqual(rec.failureReasons, ["salvaged_partial"])
        XCTAssertEqual(rec.phases.last, .idle)
    }

    func test_failed_with_partial_but_no_audio_salvages_partial() async {
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .failed(.watchdogTimeout), capturedPCM: Data(), lastPartial: "only partial",
            hasBatchTranscriber: true, transcribe: { _ in "x" }, sink: rec.sink())
        XCTAssertEqual(rec.pastedRaw, ["only partial"])
    }

    func test_empty_realtime_transcript_is_silence_idle() async {
        // A `.transcript` that resolved on a USER STOP (the default) with empty
        // text is a genuine tap-misfire / silence — silence-guard to idle. (The
        // abnormal no-stop empty close is covered separately below.)
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .transcript("   "), capturedPCM: pcm, lastPartial: "x",
            hasBatchTranscriber: true, transcribe: { _ in "y" }, sink: rec.sink())
        XCTAssertTrue(rec.delivered.isEmpty)
        XCTAssertTrue(rec.pastedRaw.isEmpty)
        XCTAssertEqual(rec.phases.last, .idle)
    }

    func test_transcript_without_stop_batch_recovers_full_audio() async {
        // The long-hold bug: an upstream/provider close mid-hold (the user is
        // STILL holding, so stopRequested == false) resolves `.transcript` with a
        // TRUNCATED realtime fragment — e.g. ElevenLabs' keepalive cutting a long
        // dictation at ~40 s. The full utterance lives in the captured PCM, so
        // recover it via batch instead of pasting the fragment.
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .transcript("twelve token fragment"), stopRequested: false,
            capturedPCM: pcm, lastPartial: "twelve token fragment",
            hasBatchTranscriber: true,
            transcribe: { _ in "the full fifty second dictation" }, sink: rec.sink())
        XCTAssertEqual(
            rec.delivered, ["the full fifty second dictation"],
            "abnormal .transcript (no user stop) must batch-recover full audio, not paste the fragment")
        XCTAssertEqual(rec.phases.first, .finishing, "batch recovery surfaces .finishing")
    }

    func test_transcript_without_stop_empty_still_batch_recovers() async {
        // Same abnormal close, but the realtime fragment is EMPTY. Must NOT
        // silence-guard the dictation away — the captured audio is real, so
        // batch-recover it.
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .transcript(""), stopRequested: false,
            capturedPCM: pcm, lastPartial: "",
            hasBatchTranscriber: true,
            transcribe: { _ in "recovered from audio" }, sink: rec.sink())
        XCTAssertEqual(rec.delivered, ["recovered from audio"])
        XCTAssertFalse(
            rec.failureReasons.contains("silence_guard"),
            "an abnormal empty close with real audio must not be silence-guarded")
    }

    func test_transcript_with_stop_delivers_realtime_not_batch() async {
        // No-regression guard: the user released (stopRequested == true), so the
        // realtime final transcript is trusted and delivered as-is — never batched.
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .transcript("clean final"), stopRequested: true,
            capturedPCM: pcm, lastPartial: "clean fin",
            hasBatchTranscriber: true, transcribe: { _ in "SHOULD NOT RUN" }, sink: rec.sink())
        XCTAssertEqual(rec.delivered, ["clean final"])
        XCTAssertFalse(rec.phases.contains(.finishing), "realtime delivery, no batch .finishing")
    }

    func test_endpointDetected_without_stop_still_delivers_realtime() async {
        // `.endpointDetected` is a provider VAD end-of-speech — a LEGIT auto-finish
        // even though the user has not released — so its realtime text is trusted,
        // unlike an abnormal `.transcript` close.
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .endpointDetected("vad final"), stopRequested: false,
            capturedPCM: pcm, lastPartial: "vad",
            hasBatchTranscriber: true, transcribe: { _ in "SHOULD NOT RUN" }, sink: rec.sink())
        XCTAssertEqual(
            rec.delivered, ["vad final"],
            "endpoint detection is a legit auto-finish; deliver realtime, never batch")
    }

    // MARK: - Batch-recovery deadline (Task: bound the 60-93s VPN-blackhole hang)

    /// Instantly-expiring deadline: the sleep returns immediately, so the
    /// timeout arm wins the race against a transcribe that only ends when
    /// the deadline cancels it.
    private static let instantDeadline = AppDelegate.BatchRecoveryDeadline(
        seconds: 0.01, sleep: { _ in }
    )

    /// Deadline whose sleep outlives every test operation (cancelled by the
    /// race when the operation wins).
    private static let patientDeadline = AppDelegate.BatchRecoveryDeadline(
        seconds: 999, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
    )

    /// A transcribe stand-in for a blackholed upload: suspends until the
    /// deadline cancels it (cancel-aware — the test must not hang).
    private static func hangingTranscribe(_: Data) async throws -> String {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return "TOO LATE"
    }

    func test_helper_times_out_hanging_operation_with_typed_error() async {
        do {
            _ = try await AppDelegate.withBatchRecoveryDeadline(Self.instantDeadline) {
                try await Self.hangingTranscribe(Data())
            }
            XCTFail("expected BatchRecoveryTimeout")
        } catch is AppDelegate.BatchRecoveryTimeout {
            // expected
        } catch {
            XCTFail("expected BatchRecoveryTimeout, got \(error)")
        }
    }

    func test_helper_returns_result_when_operation_beats_deadline() async throws {
        let out = try await AppDelegate.withBatchRecoveryDeadline(Self.patientDeadline) {
            "fast result"
        }
        XCTAssertEqual(out, "fast result")
    }

    func test_helper_rethrows_operation_error_not_timeout() async {
        struct Boom: Error {}
        do {
            _ = try await AppDelegate.withBatchRecoveryDeadline(Self.patientDeadline) {
                throw Boom()
            }
            XCTFail("expected Boom")
        } catch is Boom {
            // expected — the operation's own failure must surface untouched
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }

    func test_degraded_batch_timeout_with_partial_salvages_raw() async {
        // Blackholed batch + a live partial on hand → the deadline must cut the
        // hang and fall to rung 3 (raw-partial paste), not wedge in .finishing.
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "Фичи по факту",
            hasBatchTranscriber: true,
            deadline: Self.instantDeadline,
            transcribe: Self.hangingTranscribe, sink: rec.sink())
        XCTAssertEqual(rec.pastedRaw, ["Фичи по факту"])
        XCTAssertEqual(rec.failureReasons, ["salvaged_partial"])
        XCTAssertEqual(rec.phases.last, .idle)
    }

    func test_degraded_batch_timeout_without_partial_retains_with_timeout_reason() async {
        // No partial to salvage → rung 4, but telemetry must say TIMEOUT (not
        // the generic degraded_batch_failed) so prod can tell hangs from errors.
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "",
            hasBatchTranscriber: true,
            deadline: Self.instantDeadline,
            transcribe: Self.hangingTranscribe, sink: rec.sink())
        XCTAssertEqual(rec.retainedAudio, pcm)
        XCTAssertEqual(rec.failureReasons, ["degraded_batch_timeout"])
        XCTAssertEqual(rec.phases.last, .deliveryFailed)
    }

    func test_degraded_batch_beats_deadline_and_delivers() async {
        // A batch that completes under the deadline must deliver normally —
        // the deadline arm must not race-kill a legitimate recovery.
        let rec = Recorder()
        await AppDelegate.resolveDelivery(
            result: .degraded, capturedPCM: pcm, lastPartial: "part",
            hasBatchTranscriber: true,
            deadline: Self.patientDeadline,
            transcribe: { _ in "recovered full text" }, sink: rec.sink())
        XCTAssertEqual(rec.delivered, ["recovered full text"])
        XCTAssertTrue(rec.pastedRaw.isEmpty)
    }
}
