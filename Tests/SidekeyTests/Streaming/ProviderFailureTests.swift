import XCTest
@testable import Sidekey

/// A provider's refusal becomes a reason the user can act on, from the status
/// code alone, and reaches the Drop failure path so the island stops calling
/// every refusal "offline".
@MainActor
final class ProviderFailureTests: XCTestCase {
    func test_status_codes_become_reasons() {
        let cases: [(Error, ProviderFailure?)] = [
            (ProviderBatchTranscriptionError.httpStatus(401), .keyRefused),
            (ProviderBatchTranscriptionError.httpStatus(403), .refused),
            (ProviderBatchTranscriptionError.elevenLabs(status: 401, refusal: .missingPermissions), .missingPermission),
            (ProviderBatchTranscriptionError.elevenLabs(status: 401, refusal: .quotaExceeded), .outOfCredit),
            (ProviderBatchTranscriptionError.elevenLabs(status: 401, refusal: .invalidKey), .keyRefused),
            (ProviderBatchTranscriptionError.httpStatus(402), .outOfCredit),
            (ProviderBatchTranscriptionError.httpStatus(429), .busy),
            (ProviderBatchTranscriptionError.httpStatus(503), .notResponding),
            (ProviderBatchTranscriptionError.timedOut, .notResponding),
            (ProviderBatchTranscriptionError.jobFailed, .notResponding),
            (URLError(.notConnectedToInternet), .noConnection),
            (URLError(.cannotFindHost), .noConnection),
            // The far end's trouble, not the user's network.
            (URLError(.timedOut), .notResponding),
            (URLError(.secureConnectionFailed), .notResponding),
            (URLError(.badServerResponse), .notResponding),
            // Nothing a user can act on: the caller keeps its own wording.
            (ProviderBatchTranscriptionError.httpStatus(400), nil),
            (ProviderBatchTranscriptionError.malformedResponse, nil),
            (URLError(.cancelled), nil),
            (CancellationError(), nil),
            (BatchTranscriptionUnavailable(), nil),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(ProviderFailure(error), expected, "\(error)")
        }
    }

    func test_island_wording_names_the_provider_and_the_cause() {
        XCTAssertEqual(ProviderFailure.keyRefused.dropMessage(provider: "ElevenLabs"), "ElevenLabs refused the key")
        XCTAssertEqual(ProviderFailure.missingPermission.dropMessage(provider: "ElevenLabs"),
                       "ElevenLabs key: no Speech to Text access")
        XCTAssertEqual(ProviderFailure.refused.dropMessage(provider: "Deepgram"), "Deepgram refused the request")
        XCTAssertEqual(ProviderFailure.outOfCredit.dropMessage(provider: "Soniox"), "Soniox: out of credit")
        XCTAssertEqual(ProviderFailure.busy.dropMessage(provider: "Deepgram"), "Deepgram is busy, try again")
        XCTAssertEqual(ProviderFailure.notResponding.dropMessage(provider: "Soniox"), "Soniox is not responding")
        XCTAssertEqual(ProviderFailure.noConnection.dropMessage(provider: "Soniox"), "No connection")
    }

    func test_only_key_and_credit_failures_mark_the_key_and_need_settings() {
        XCTAssertEqual(ProviderFailure.keyRefused.keyStatus, .rejected(.invalidKey))
        XCTAssertEqual(ProviderFailure.outOfCredit.keyStatus, .rejected(.outOfCredit))
        XCTAssertEqual(ProviderFailure.missingPermission.keyStatus, .rejected(.missingSpeechPermission))
        // A 403 can come from a plan, a region or a proxy: shown, not pinned on the key.
        for transient in [ProviderFailure.refused, .busy, .notResponding, .noConnection] {
            XCTAssertNil(transient.keyStatus, "\(transient) says nothing lasting about the key")
            XCTAssertFalse(transient.needsSettings, "Retry can still help")
        }
        XCTAssertTrue(ProviderFailure.keyRefused.needsSettings)
        XCTAssertTrue(ProviderFailure.outOfCredit.needsSettings)
    }

    func test_elevenlabs_refusal_reads_only_the_three_known_codes() {
        func refusal(_ body: String) -> ElevenLabsRefusal? { ElevenLabsRefusal(body: Data(body.utf8)) }
        XCTAssertEqual(refusal(#"{"detail":{"status":"missing_permissions","message":"x"}}"#), .missingPermissions)
        XCTAssertEqual(refusal(#"{"detail":{"status":"quota_exceeded","message":"x"}}"#), .quotaExceeded)
        XCTAssertEqual(refusal(#"{"detail":{"status":"invalid_api_key"}}"#), .invalidKey)
        XCTAssertNil(refusal(#"{"detail":{"status":"something_else","message":"We ship on Friday"}}"#))
        XCTAssertNil(refusal("missing_permissions"), "only the parsed field counts")
        XCTAssertNil(refusal(#"{"detail":"missing_permissions"}"#))
    }

    // MARK: - Drop delivery

    private final class Recorder {
        var phases: [AppPhase] = []
        var noted: [Error] = []
        var retained: Data?
        var delivered: [String] = []
        var order: [String] = []

        func sink() -> AppDelegate.DropBatchRecoverySink {
            AppDelegate.DropBatchRecoverySink(
                setPhase: { [weak self] in
                    self?.phases.append($0)
                    if $0 == .deliveryFailed { self?.order.append("failed") }
                },
                deliver: { [weak self] in self?.delivered.append($0); return true },
                retainForRetry: { [weak self] in self?.retained = $0 },
                clearPendingRetry: {},
                failTelemetry: { _ in },
                noteBatchFailure: { [weak self] in
                    self?.noted.append($0)
                    self?.order.append("noted")
                }
            )
        }
    }

    private let audio = Data([1, 2, 3, 4])

    /// The user's case: the stream fails, the batch attempt gets 401. The
    /// reason must be known before the island shows the failure, and the
    /// audio must stay for Retry after the key is fixed.
    func test_refused_key_reaches_the_failure_path_before_the_island_shows_it() async {
        let recorder = Recorder()

        await AppDelegate.resolveDelivery(
            result: .failed(.unknown), stopRequested: true, capturedPCM: audio, lastPartial: "",
            hasBatchTranscriber: true,
            transcribe: { _ in throw ProviderBatchTranscriptionError.httpStatus(401) },
            sink: recorder.sink()
        )

        XCTAssertEqual(recorder.noted.count, 1)
        XCTAssertEqual(ProviderFailure(recorder.noted[0]), .keyRefused)
        XCTAssertEqual(recorder.order, ["noted", "failed"])
        XCTAssertEqual(recorder.phases.last, .deliveryFailed)
        XCTAssertEqual(recorder.retained, audio, "the take survives until the key is fixed")
        XCTAssertTrue(recorder.delivered.isEmpty)
    }

    func test_retry_that_is_refused_again_reports_the_reason_again() async {
        let recorder = Recorder()

        await AppDelegate.runBatchRecovery(
            pcm: audio, hasBatchTranscriber: true,
            transcribe: { _ in throw ProviderBatchTranscriptionError.httpStatus(402) },
            sink: recorder.sink()
        )

        XCTAssertEqual(recorder.noted.map { ProviderFailure($0) }, [.outOfCredit])
        XCTAssertEqual(recorder.phases.last, .deliveryFailed)
        XCTAssertEqual(recorder.retained, audio)
    }

    /// Break caught: Settings opened and the key went red although the take's
    /// live partial was then pasted. The sink is told about the failure, but
    /// the take does not end undelivered, so nothing may be applied.
    func test_refused_batch_whose_partial_is_pasted_never_reaches_the_failed_phase() async {
        let recorder = Recorder()
        var sink = recorder.sink()
        var pasted: [String] = []
        sink.pasteRaw = { pasted.append($0); return true }

        await AppDelegate.resolveDelivery(
            result: .failed(.unknown), stopRequested: true, capturedPCM: audio, lastPartial: "hello there",
            hasBatchTranscriber: true,
            transcribe: { _ in throw ProviderBatchTranscriptionError.httpStatus(401) },
            sink: sink
        )

        XCTAssertEqual(pasted, ["hello there"])
        XCTAssertFalse(recorder.phases.contains(.deliveryFailed), "the reason is applied only on this phase")
        XCTAssertEqual(recorder.noted.count, 1)
    }

    func test_a_timed_out_retry_is_reported_so_an_older_reason_is_cleared() async {
        let recorder = Recorder()

        await AppDelegate.runBatchRecovery(
            pcm: audio, hasBatchTranscriber: true,
            deadline: AppDelegate.BatchRecoveryDeadline(seconds: 0.05) { try await Task.sleep(for: .seconds($0)) },
            transcribe: { _ in
                try await Task.sleep(for: .seconds(5))
                return "late"
            },
            sink: recorder.sink()
        )

        XCTAssertEqual(recorder.noted.count, 1)
        XCTAssertNil(ProviderFailure(recorder.noted[0]), "not a provider's refusal: the old reason must not stay")
        XCTAssertEqual(recorder.phases.last, .deliveryFailed)
    }

    func test_successful_recovery_reports_no_failure() async {
        let recorder = Recorder()

        await AppDelegate.runBatchRecovery(
            pcm: audio, hasBatchTranscriber: true,
            transcribe: { _ in "recovered" }, sink: recorder.sink()
        )

        XCTAssertTrue(recorder.noted.isEmpty)
        XCTAssertEqual(recorder.delivered, ["recovered"])
    }
}
