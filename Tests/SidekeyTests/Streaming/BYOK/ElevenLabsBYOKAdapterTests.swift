import XCTest
@testable import Sidekey

@MainActor
final class ElevenLabsBYOKAdapterTests: XCTestCase {
    func testURLCarriesModelFormatCommitStrategyNoVerbatimLanguageAndKeyterms() {
        let url = ElevenLabsRealtimeURL.make(model: "scribe_v2_realtime", language: "ru", terms: ["Whytap", "Sidekey"])
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = comps.queryItems ?? []
        func val(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func vals(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap { $0.value } }
        XCTAssertEqual(comps.scheme, "wss")
        XCTAssertEqual(comps.host, "api.elevenlabs.io")
        XCTAssertEqual(comps.path, "/v1/speech-to-text/realtime")
        XCTAssertEqual(val("model_id"), "scribe_v2_realtime")
        XCTAssertEqual(val("audio_format"), "pcm_16000")
        XCTAssertEqual(val("commit_strategy"), "manual")
        XCTAssertEqual(val("no_verbatim"), "true")
        XCTAssertEqual(val("language_code"), "ru")
        XCTAssertEqual(vals("keyterms"), ["Whytap", "Sidekey"])  // repeated param per term
    }

    func testURLOmitsLanguageAndKeytermsWhenEmpty() {
        let url = ElevenLabsRealtimeURL.make(model: "scribe_v2_realtime", language: nil, terms: [])
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { $0.name }
        XCTAssertFalse(names.contains("language_code"))
        XCTAssertFalse(names.contains("keyterms"))
    }

    func testSendAudioBase64ChunkAndEndInputCommits() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v2_realtime") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        await session.sendAudio(Data([0x01, 0x02]))
        await session.endInput()
        let texts = stub.sent.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        XCTAssertTrue(texts.contains {
            $0.contains("\"message_type\":\"input_audio_chunk\"") && $0.contains("\"audio_base_64\"") && $0.contains("\"commit\":false")
        })
        XCTAssertTrue(texts.contains { $0.contains("\"commit\":true") })  // EOF commit
        await session.close()
    }

    // Short dictation (< Scribe's ~36 s segment cap): the user releases, our
    // endInput commits, and the single committed_transcript is the terminal.
    func testShortDictationCommitsOnEndInput() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v2_realtime") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var iterator = session.events.makeAsyncIterator()
        stub.deliverText(#"{"message_type":"session_started","session_id":"s1"}"#)  // ignored
        stub.deliverText(#"{"message_type":"partial_transcript","text":"hel"}"#)
        let e0 = await iterator.next()
        XCTAssertEqual(e0, .partial("hel"))
        await session.endInput()
        stub.deliverText(#"{"message_type":"committed_transcript","text":"hello"}"#)
        let e1 = await iterator.next()
        XCTAssertEqual(e1, .final("hello"))
        let e2 = await iterator.next()
        XCTAssertEqual(e2, .done("hello"))
        await session.close()
    }

    // Scribe auto-commits a segment at its ~36 s max length WITHOUT our manual
    // commit. That committed_transcript must NOT end the turn — the socket stays
    // open and more segments follow. Terminating on the first one truncated any
    // dictation longer than ~36 s (the long-hold "death"). Proven by a second
    // segment's partial arriving after the auto-commit.
    func testMidHoldAutoCommitIsNotTerminal() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v2_realtime") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var iterator = session.events.makeAsyncIterator()
        stub.deliverText(#"{"message_type":"partial_transcript","text":"hel"}"#)
        let e0 = await iterator.next()
        XCTAssertEqual(e0, .partial("hel"))
        stub.deliverText(#"{"message_type":"committed_transcript","text":"hello"}"#)  // auto @36s
        let e1 = await iterator.next()
        XCTAssertEqual(e1, .final("hello"))
        // No endInput yet → stream stays open; the next segment's partial proves it.
        stub.deliverText(#"{"message_type":"partial_transcript","text":"wor"}"#)
        let e2 = await iterator.next()
        XCTAssertEqual(e2, .partial("wor"))
        await session.close()
    }

    // The terminal done joins every accumulated segment, so a long dictation
    // (one or more mid-hold auto-commits, then our commit on release) delivers
    // the FULL utterance, not just the last segment.
    func testCommitAfterEndInputJoinsAllSegments() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v2_realtime") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var iterator = session.events.makeAsyncIterator()
        stub.deliverText(#"{"message_type":"committed_transcript","text":"Hello world"}"#)  // auto seg1
        let e0 = await iterator.next()
        XCTAssertEqual(e0, .final("Hello world"))
        await session.endInput()  // user release → manual commit
        stub.deliverText(#"{"message_type":"committed_transcript","text":"from Whytap"}"#)  // terminal seg2
        let e1 = await iterator.next()
        XCTAssertEqual(e1, .final("from Whytap"))
        let e2 = await iterator.next()
        XCTAssertEqual(e2, .done("Hello world from Whytap"))
        await session.close()
    }

    // If the socket closes before our manual commit (EL closed the
    // segment-capped stream, or an upstream drop), recover whatever segments
    // accumulated as the terminal — a long dictation is delivered, not lost.
    func testConnectionCloseRecoversAllAccumulatedSegments() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v2_realtime") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var iterator = session.events.makeAsyncIterator()
        stub.deliverText(#"{"message_type":"committed_transcript","text":"alpha"}"#)  // auto seg1
        let e0 = await iterator.next()
        XCTAssertEqual(e0, .final("alpha"))
        stub.deliverText(#"{"message_type":"committed_transcript","text":"beta"}"#)  // auto seg2
        let e1 = await iterator.next()
        XCTAssertEqual(e1, .final("beta"))
        stub.deliver(.failure(URLError(.networkConnectionLost)))  // socket closed pre-commit
        let e2 = await iterator.next()
        XCTAssertEqual(e2, .done("alpha beta"))  // recovered both
        await session.close()
    }

    // A socket close with nothing accumulated is a genuine transport error,
    // not a recoverable transcript.
    func testConnectionCloseWithNoSegmentsSurfacesError() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v2_realtime") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var iterator = session.events.makeAsyncIterator()
        stub.deliver(.failure(URLError(.networkConnectionLost)))
        let e0 = await iterator.next()
        XCTAssertEqual(e0, .error("transport"))
        await session.close()
    }

    // Parity with the hub adapter: before the first REAL audio, send a chunk of
    // preroll silence carrying `previous_text` so Scribe's no_verbatim doesn't
    // clip the first short word as a false start. The real audio follows as a
    // separate chunk with no context.
    func testFirstAudioIsPrecededByPrerollSilenceCarryingPreviousText() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v2_realtime") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        let realAudio = Data([0x11, 0x22])
        await session.sendAudio(realAudio)
        let texts = stub.sent.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        XCTAssertEqual(texts.count, 2, "first audio should emit a preroll chunk then the real chunk")
        guard texts.count == 2 else { return }
        XCTAssertTrue(texts[0].contains(#""previous_text":".""#), "context rides the preroll chunk")
        XCTAssertFalse(texts[1].contains("previous_text"), "real audio chunk carries no context")
        let realB64 = realAudio.base64EncodedString()
        XCTAssertFalse(texts[0].contains(realB64), "preroll chunk is silence, not the real audio")
        XCTAssertTrue(texts[1].contains(realB64), "real audio is the second chunk")
        await session.close()
    }

    // The preroll + previous_text warmup happens once, on the first audio only.
    func testPrerollAndPreviousTextSentOnlyOnFirstAudio() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v2_realtime") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        await session.sendAudio(Data([0x01]))  // first → preroll + real (2 chunks)
        await session.sendAudio(Data([0x02]))  // second → real only (1 chunk)
        let texts = stub.sent.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        XCTAssertEqual(texts.count, 3)
        XCTAssertEqual(texts.filter { $0.contains("previous_text") }.count, 1, "previous_text sent exactly once")
        await session.close()
    }

    // Preroll silence is configurable off; previous_text then rides the first
    // real audio chunk (no separate silence chunk), matching the hub behaviour.
    func testPrerollDisabledStillSeedsPreviousTextOnFirstRealChunk() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v2_realtime", prerollSilenceMs: 0) { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        let realAudio = Data([0x09])
        await session.sendAudio(realAudio)
        let texts = stub.sent.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        XCTAssertEqual(texts.count, 1, "no separate silence chunk when preroll disabled")
        guard texts.count == 1 else { return }
        XCTAssertTrue(texts[0].contains(#""previous_text":".""#))
        XCTAssertTrue(texts[0].contains(realAudio.base64EncodedString()))
        await session.close()
    }
}
