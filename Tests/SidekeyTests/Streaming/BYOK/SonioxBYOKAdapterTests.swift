import XCTest
@testable import Sidekey

@MainActor
final class SonioxBYOKAdapterTests: XCTestCase {
    private func configFromFirstFrame(_ stub: StubWebSocketTransport) throws -> [String: Any] {
        guard case .text(let json)? = stub.sent.first else { throw XCTSkip("no config frame") }
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testOpenSendsConfigWithUserKeyModelFormatAndContext() async throws {
        let stub = StubWebSocketTransport()
        let adapter = SonioxBYOKAdapter(apiKey: "user-soniox-key", model: "stt-rt-v5") { stub }
        _ = try await adapter.open(language: "ru", terms: ["Whytap"])
        let cfg = try configFromFirstFrame(stub)
        XCTAssertEqual(cfg["api_key"] as? String, "user-soniox-key")
        XCTAssertEqual(cfg["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(cfg["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(cfg["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(cfg["num_channels"] as? Int, 1)
        XCTAssertEqual(cfg["enable_endpoint_detection"] as? Bool, false)
        XCTAssertEqual(cfg["language_hints"] as? [String], ["ru", "en"])
        let context = cfg["context"] as? [String: Any]
        XCTAssertEqual(context?["terms"] as? [String], ["Whytap"])
    }

    /// Direct Soniox BYOK emits one `.final` per Soniox token — the same
    /// per-token semantics as the hub — so its session must also declare
    /// `.verbatim` composition (tokens carry their own leading spaces).
    func testSonioxSessionDeclaresVerbatimFinalsJoin() async throws {
        let stub = StubWebSocketTransport()
        let adapter = SonioxBYOKAdapter(apiKey: "k", model: "stt-rt-v5") { stub }
        let session = try await adapter.open(language: nil, terms: [])
        XCTAssertEqual(session.finalsJoin, .verbatim)
        await session.close()
    }

    func testSendAudioIsRawBinaryAndEndInputIsEmptyString() async throws {
        let stub = StubWebSocketTransport()
        let adapter = SonioxBYOKAdapter(apiKey: "k", model: "stt-rt-v5") { stub }
        let session = try await adapter.open(language: nil, terms: [])
        await session.sendAudio(Data([0xAA, 0xBB]))
        await session.endInput()
        XCTAssertTrue(stub.sent.contains(.data(Data([0xAA, 0xBB]))))
        XCTAssertTrue(stub.sent.contains(.text("")))  // empty-string EOF marker
        await session.close()
    }

    func testEventsAccumulateFinalsAndDoneOnFinished() async throws {
        let stub = StubWebSocketTransport()
        let adapter = SonioxBYOKAdapter(apiKey: "k", model: "stt-rt-v5") { stub }
        let session = try await adapter.open(language: nil, terms: [])
        stub.deliverText(#"{"tokens":[{"text":"Privet","is_final":true},{"text":" mir","is_final":false}]}"#)
        stub.deliverText(#"{"tokens":[{"text":" mir","is_final":true}],"finished":true}"#)
        var got: [BYOKStreamEvent] = []
        for await ev in session.events { got.append(ev); if case .done = ev { break } }
        XCTAssertTrue(got.contains(.partial(" mir")))
        XCTAssertTrue(got.contains(.final("Privet")))
        XCTAssertEqual(got.last, .done("Privet mir"))  // finals joined with "" (tokens carry spacing)
    }
    func testManualFinalizationCoversDrainedAudioAndFinCompletesWithoutSocketEOF() async throws {
        let stub = StubWebSocketTransport()
        let session = try await SonioxBYOKAdapter(apiKey: "k", model: "stt-rt-v5") { stub }.open(language: nil, terms: [])
        await session.sendAudio(Data([1, 2]))
        await session.endInput()
        let tail = Array(stub.sent.suffix(4))
        XCTAssertEqual(tail, [.data(Data([1, 2])), .data(Data(repeating: 0, count: 6400)), .text(#"{"type":"finalize"}"#), .text("")])
        stub.deliverText(#"{"tokens":[{"text":"last word","is_final":true},{"text":"<fin>","is_final":true}]}"#)
        var events: [BYOKStreamEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events.last, .done("last word"))
        XCTAssertFalse(events.contains(.final("<fin>")))
        XCTAssertTrue(stub.cancelled)
    }

    func testProviderErrorEndsStreamImmediatelyWithoutLeakingMessage() async throws {
        let stub = StubWebSocketTransport()
        let session = try await SonioxBYOKAdapter(apiKey: "k", model: "stt-rt-v5") { stub }.open(language: nil, terms: [])
        stub.deliverText(#"{"error_code":429,"error_message":"private provider details"}"#)
        var events: [BYOKStreamEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events, [.error("provider")])
        XCTAssertTrue(stub.cancelled)
    }

    func testAudioSendFailureIsNotSilentlyTreatedAsDelivered() async throws {
        let stub = StubWebSocketTransport()
        let session = try await SonioxBYOKAdapter(apiKey: "k", model: "stt-rt-v5") { stub }.open(language: nil, terms: [])
        stub.sendError = URLError(.networkConnectionLost)
        await session.sendAudio(Data([1, 2]))
        var events: [BYOKStreamEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events, [.error("transport")])
    }

    func testBinaryJSONAndEmptyPartialFlushFinalOnlyFrame() async throws {
        let stub = StubWebSocketTransport()
        let session = try await SonioxBYOKAdapter(apiKey: "k", model: "stt-rt-v5") { stub }.open(language: nil, terms: [])
        stub.deliverText(#"{"tokens":[]}"#) // heartbeat is not transcription progress
        stub.deliver(.success(.data(Data(#"{"tokens":[{"text":"done","is_final":true}],"finished":true}"#.utf8))))
        var events: [BYOKStreamEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events, [.final("done"), .partial(""), .done("done")])
    }

    func testEndInputIsIdempotentAndCancelCannotDeliverLateFinal() async throws {
        let stub = StubWebSocketTransport()
        let session = try await SonioxBYOKAdapter(apiKey: "k", model: "stt-rt-v5") { stub }.open(language: nil, terms: [])
        await session.endInput()
        let count = stub.sent.count
        await session.endInput()
        XCTAssertEqual(stub.sent.count, count)
        await session.close()
        stub.deliverText(#"{"tokens":[{"text":"late","is_final":true}],"finished":true}"#)
        var events: [BYOKStreamEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertTrue(events.isEmpty)
    }

}
