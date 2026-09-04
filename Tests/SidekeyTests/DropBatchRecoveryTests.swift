import XCTest
@testable import Sidekey

/// Behavioral coverage for the degraded-Drop batch-recovery state machine
/// (`AppDelegate.runBatchRecovery`). `AppDelegate` itself is AppKit-bound and
/// never instantiated by tests, so the transcribe→decide→deliver tail is
/// factored into a static function whose every side effect arrives as an
/// injected closure (`DropBatchRecoverySink`). Here we drive it with a stub
/// transcriber + spies and assert the four contractual arms:
///
///  - success → paste exactly once, phase ends idle, no pending retry;
///  - batch throws → phase `.deliveryFailed`, audio retained for retry, NO paste;
///  - empty transcript → idle, no paste, no pending retry (nothing to recover);
///  - no audio / no batch transcriber → idle, no paste, no pending retry.
@MainActor
final class DropBatchRecoveryTests: XCTestCase {

    /// Records every effect the sink fired so a test can assert on the
    /// resulting phase sequence, paste calls, and retained-audio state.
    private final class Recorder {
        var phases: [AppPhase] = []
        var delivered: [String] = []
        var failureReasons: [String] = []
        var retainedAudio: Data?
        var clearedPending = false

        func sink() -> AppDelegate.DropBatchRecoverySink {
            AppDelegate.DropBatchRecoverySink(
                setPhase: { [weak self] in self?.phases.append($0) },
                // The production paste tail (`runPostProcessAndPaste` →
                // `finishDropDelivery`) ends the turn at `.idle`; mirror that
                // here so a successful recovery's phase sequence is realistic.
                deliver: { [weak self] text in
                    self?.delivered.append(text)
                    self?.phases.append(.idle)
                },
                retainForRetry: { [weak self] pcm in self?.retainedAudio = pcm },
                clearPendingRetry: { [weak self] in self?.clearedPending = true },
                failTelemetry: { [weak self] reason in self?.failureReasons.append(reason) }
            )
        }
    }

    private let samplePCM = Data([0x01, 0x02, 0x03, 0x04])

    // MARK: - success

    func test_success_delivers_once_and_returns_to_idle_with_no_pending() async {
        let rec = Recorder()
        await AppDelegate.runBatchRecovery(
            pcm: samplePCM,
            hasBatchTranscriber: true,
            transcribe: { _ in "hello world" },
            sink: rec.sink()
        )

        XCTAssertEqual(rec.delivered, ["hello world"], "Success must paste exactly once.")
        XCTAssertEqual(rec.phases.first, .finishing, "Recovery must show the calm .finishing state first.")
        XCTAssertNil(rec.retainedAudio, "Success must not retain audio for retry.")
        XCTAssertTrue(rec.clearedPending, "Success must clear any prior pending retry.")
        XCTAssertTrue(rec.failureReasons.isEmpty, "Success must not emit failure telemetry.")
        // .deliveryFailed must never be reached on the happy path.
        XCTAssertFalse(rec.phases.contains(.deliveryFailed))
    }

    // MARK: - batch throws → keep audio + .deliveryFailed

    func test_batch_throws_sets_deliveryFailed_retains_audio_and_does_not_paste() async {
        let rec = Recorder()
        struct Boom: Error {}
        await AppDelegate.runBatchRecovery(
            pcm: samplePCM,
            hasBatchTranscriber: true,
            transcribe: { _ in throw Boom() },
            sink: rec.sink()
        )

        XCTAssertTrue(rec.delivered.isEmpty, "A failed batch must NEVER paste (no empty paste).")
        XCTAssertEqual(rec.phases.last, .deliveryFailed, "Total-offline must end in .deliveryFailed.")
        XCTAssertEqual(rec.retainedAudio, samplePCM, "Total-offline must retain the audio for manual retry.")
        XCTAssertFalse(rec.clearedPending, "A failed batch must not clear pending retry.")
        XCTAssertEqual(rec.failureReasons, ["degraded_batch_failed"])
    }

    // MARK: - empty transcript → idle, no paste, no retry

    func test_empty_transcript_returns_to_idle_without_paste_or_retry() async {
        let rec = Recorder()
        await AppDelegate.runBatchRecovery(
            pcm: samplePCM,
            hasBatchTranscriber: true,
            transcribe: { _ in "   \n  " },
            sink: rec.sink()
        )

        XCTAssertTrue(rec.delivered.isEmpty, "Empty transcript must not paste.")
        XCTAssertEqual(rec.phases.last, .idle, "Empty transcript fails to idle (nothing to recover).")
        XCTAssertNil(rec.retainedAudio, "Empty transcript must NOT arm retry — there is nothing to recover.")
        XCTAssertEqual(rec.failureReasons, ["degraded_empty"])
    }

    // MARK: - no audio / no batch transcriber → idle, no paste, no retry

    func test_no_audio_returns_to_idle_without_paste_or_retry() async {
        let rec = Recorder()
        await AppDelegate.runBatchRecovery(
            pcm: Data(),
            hasBatchTranscriber: true,
            transcribe: { _ in XCTFail("transcribe must not run without audio"); return "" },
            sink: rec.sink()
        )

        XCTAssertTrue(rec.delivered.isEmpty)
        XCTAssertEqual(rec.phases.last, .idle)
        XCTAssertNil(rec.retainedAudio, "No audio means nothing to retry.")
        XCTAssertEqual(rec.failureReasons, ["degraded_no_audio"])
    }

    func test_no_batch_transcriber_returns_to_idle_without_paste_or_retry() async {
        let rec = Recorder()
        await AppDelegate.runBatchRecovery(
            pcm: samplePCM,
            hasBatchTranscriber: false,
            transcribe: { _ in XCTFail("transcribe must not run without a batch transcriber"); return "" },
            sink: rec.sink()
        )

        XCTAssertTrue(rec.delivered.isEmpty)
        XCTAssertEqual(rec.phases.last, .idle)
        XCTAssertNil(rec.retainedAudio)
        XCTAssertEqual(rec.failureReasons, ["degraded_no_audio"])
    }

    // MARK: - retry re-invokes the batch path and clears pending on success

    func test_retry_reinvokes_batch_and_clears_pending_on_success() async {
        // First attempt fails → arms retry.
        let first = Recorder()
        struct Boom: Error {}
        await AppDelegate.runBatchRecovery(
            pcm: samplePCM,
            hasBatchTranscriber: true,
            transcribe: { _ in throw Boom() },
            sink: first.sink()
        )
        XCTAssertEqual(first.retainedAudio, samplePCM)

        // Retry re-runs the SAME state machine with the retained audio; this
        // time the network is back, so it delivers once and clears pending.
        let retry = Recorder()
        await AppDelegate.runBatchRecovery(
            pcm: first.retainedAudio ?? Data(),
            hasBatchTranscriber: true,
            transcribe: { _ in "recovered text" },
            sink: retry.sink()
        )
        XCTAssertEqual(retry.delivered, ["recovered text"])
        XCTAssertEqual(retry.phases.last, .idle)
        XCTAssertTrue(retry.clearedPending)
        XCTAssertNil(retry.retainedAudio)
    }

    // MARK: - deadline: a blackholed manual Retry must not wedge .finishing

    func test_batch_timeout_retains_audio_with_timeout_reason() async {
        // The manual Retry path re-enters this state machine; on a VPN that
        // blackholes the upload the transcribe used to hang 60-93s with the
        // island stuck on "finishing…". The deadline bounds it and re-arms
        // .deliveryFailed with a TIMEOUT-specific telemetry reason.
        let rec = Recorder()
        await AppDelegate.runBatchRecovery(
            pcm: samplePCM,
            hasBatchTranscriber: true,
            deadline: AppDelegate.BatchRecoveryDeadline(seconds: 0.01, sleep: { _ in }),
            transcribe: { _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "TOO LATE"
            },
            sink: rec.sink()
        )
        XCTAssertEqual(rec.retainedAudio, samplePCM)
        XCTAssertEqual(rec.failureReasons, ["degraded_batch_timeout"])
        XCTAssertEqual(rec.phases.last, .deliveryFailed)
        XCTAssertTrue(rec.delivered.isEmpty)
    }
}
