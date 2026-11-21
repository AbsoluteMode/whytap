import XCTest
@testable import Sidekey

/// A finished meeting on ElevenLabs or Deepgram goes to the provider's
/// pre-recorded API in one request, with speaker labels.
// WHY: .project-docs/decisions/2026-11-21-recorded-meeting-models.md
final class RecordedMeetingTranscriberTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private func chunk(_ name: String = "chunk-000.wav", samples: [UInt8] = [1, 2, 3, 4]) throws -> URL {
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(samples.count + 36)); data.append(Data("WAVEfmt ".utf8)); append(16)
        data.append(contentsOf: [1, 0, 1, 0]); append(16000); append(32000)
        data.append(contentsOf: [2, 0, 16, 0]); data.append(Data("data".utf8)); append(UInt32(samples.count))
        data.append(contentsOf: samples)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    // MARK: ElevenLabs

    func test_elevenlabs_meeting_is_one_diarized_request_with_the_recorded_model() async throws {
        let first = try chunk(), second = try chunk("chunk-001.wav", samples: [5, 6])
        StubURLProtocol.handler = { _ in
            (200, ["request-id": "req-1"], try Self.json([
                "text": "We ship Friday. Agreed.",
                "words": [
                    ["text": "We", "type": "word", "start": 0.1, "end": 0.3, "speaker_id": "speaker_0"],
                    ["text": " ", "type": "spacing", "start": 0.3, "end": 0.4, "speaker_id": "speaker_0"],
                    ["text": "ship", "type": "word", "start": 0.4, "end": 0.6, "speaker_id": "speaker_0"],
                    ["text": " ", "type": "spacing", "start": 0.6, "end": 0.7, "speaker_id": "speaker_0"],
                    ["text": "(laughs)", "type": "audio_event", "start": 0.7, "end": 0.9, "speaker_id": "speaker_0"],
                    ["text": "Friday.", "type": "word", "start": 0.9, "end": 1.2, "speaker_id": "speaker_0"],
                    ["text": " ", "type": "spacing", "start": 1.2, "end": 1.3, "speaker_id": "speaker_1"],
                    ["text": "Agreed.", "type": "word", "start": 1.4, "end": 1.8, "speaker_id": "speaker_1"],
                ],
            ]))
        }
        var usage: [AIUsageEvent] = []
        let transcriber = RecordedMeetingTranscriber(
            route: .elevenLabs(apiKey: "el-key", model: "scribe_v3"), session: session, usageSink: { usage.append($0) })

        let result = try await transcriber.transcribe(
            chunkURLs: [first, second], language: "en", terms: ["Whytap", "Soniox"])

        XCTAssertEqual(result.segments, [
            TranscriptSegment(speaker: "Speaker 1", start: 0.1, end: 1.2, text: "We ship Friday."),
            TranscriptSegment(speaker: "Speaker 2", start: 1.4, end: 1.8, text: "Agreed."),
        ])
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1, "one request, no streaming")
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "el-key")
        let body = try XCTUnwrap(StubURLProtocol.capturedBodies.first)
        let text = String(decoding: body, as: UTF8.self)
        for field in [("model_id", "scribe_v3"), ("diarize", "true"), ("language_code", "en"),
                      ("keyterms", "Whytap"), ("keyterms", "Soniox"), ("tag_audio_events", "false")] {
            XCTAssertTrue(text.contains("name=\"\(field.0)\"\r\n\r\n\(field.1)\r\n"), "\(field) in \(text.prefix(800))")
        }
        let riff = try XCTUnwrap(body.range(of: Data("RIFF".utf8))).lowerBound
        XCTAssertEqual(Array(body[(riff + 40)..<(riff + 50)]), [6, 0, 0, 0, 1, 2, 3, 4, 5, 6], "one WAV, chunks in order")
        XCTAssertNil(body.range(of: Data("RIFF".utf8), in: (riff + 4)..<body.count))

        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.id, "elevenlabs:req-1")
        XCTAssertEqual(usage.first?.context, AIUsageContext(feature: .meetings, account: .elevenLabs, model: "scribe_v3"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "the upload file is removed")
    }

    func test_elevenlabs_without_language_or_terms_sends_neither() async throws {
        let url = try chunk()
        StubURLProtocol.handler = { _ in (200, [:], try Self.json(["text": "", "words": []])) }
        let transcriber = RecordedMeetingTranscriber(
            route: .elevenLabs(apiKey: "k", model: "scribe_v3"), session: session, usageSink: { _ in })
        let result = try await transcriber.transcribe(chunkURLs: [url], language: "", terms: [])
        XCTAssertEqual(result, SonioxMeetingTranscriber.Result(text: "", segments: []), "silence, not a failure")
        let text = String(decoding: try XCTUnwrap(StubURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertFalse(text.contains("language_code"))
        XCTAssertFalse(text.contains("keyterms"))
    }

    func test_refusals_use_fixed_copy_and_never_quote_the_provider() async throws {
        let url = try chunk()
        let cases: [(Int, Any, String)] = [
            (401, ["detail": ["status": "quota_exceeded", "message": "secret body"]], "ElevenLabs is out of credit."),
            (401, ["detail": ["status": "missing_permissions", "message": "secret body"]], "no Speech to Text access"),
            (401, ["detail": ["status": "invalid_api_key", "message": "secret body"]], "ElevenLabs refused the key."),
            (429, ["detail": "secret body"], "ElevenLabs is busy"),
            (503, ["detail": "secret body"], "ElevenLabs is not responding (503)."),
            (422, ["detail": "secret body"], "ElevenLabs refused the recording (HTTP 422)."),
        ]
        for (status, body, expected) in cases {
            StubURLProtocol.handler = { _ in (status, [:], try Self.json(body)) }
            var usage: [AIUsageEvent] = []
            let transcriber = RecordedMeetingTranscriber(
                route: .elevenLabs(apiKey: "k", model: "scribe_v3"), session: session, usageSink: { usage.append($0) })
            do {
                _ = try await transcriber.transcribe(chunkURLs: [url], language: nil, terms: [])
                XCTFail("expected a failure for \(status)")
            } catch let error as MeetingBYOKProcessingError {
                let text = error.description
                XCTAssertTrue(text.contains(expected), text)
                XCTAssertTrue(text.contains("The recording is saved for retry."), text)
                XCTAssertFalse(text.contains("secret body"))
            }
            XCTAssertEqual(usage, [], "a refused request is not a cost")
        }
    }

    func test_elevenlabs_words_split_on_a_long_pause_and_unlabelled_speech_stays_unknown() throws {
        let data = try Self.json([
            "text": "One. Two. Three.",
            "words": [
                ["text": "One.", "type": "word", "start": 0.0, "end": 0.5, "speaker_id": "speaker_0"],
                ["text": " ", "type": "spacing"],
                ["text": "Two.", "type": "word", "start": 5.0, "end": 5.5, "speaker_id": "speaker_0"],
                ["text": " ", "type": "spacing"],
                ["text": "Three.", "type": "word", "start": 5.6, "end": 6.0],
            ],
        ])
        let result = try RecordedMeetingTranscriber.decodeElevenLabs(data)
        XCTAssertEqual(result.segments.map(\.text), ["One.", "Two.", "Three."])
        XCTAssertEqual(result.segments.map(\.speaker), ["Speaker 1", "Speaker 1", nil])
    }

    func test_speech_without_words_is_kept_unlabelled() throws {
        let result = try RecordedMeetingTranscriber.decodeElevenLabs(try Self.json(["text": "Hello team"]))
        XCTAssertEqual(result.segments, [TranscriptSegment(speaker: nil, start: 0, end: 0, text: "Hello team")])
    }

    func test_malformed_answer_is_an_error_not_silence() {
        XCTAssertThrowsError(try RecordedMeetingTranscriber.decodeElevenLabs(Data("{}".utf8)))
        XCTAssertThrowsError(try RecordedMeetingTranscriber.decodeDeepgram(Data("{\"results\":{}}".utf8)))
    }

    func test_speaker_labels_follow_soniox_numbering() {
        XCTAssertEqual(RecordedMeetingTranscriber.speakerLabel("speaker_0"), "Speaker 1")
        XCTAssertEqual(RecordedMeetingTranscriber.speakerLabel("speaker_11"), "Speaker 12")
        XCTAssertEqual(RecordedMeetingTranscriber.speakerLabel("agent"), "Speaker agent")
        XCTAssertNil(RecordedMeetingTranscriber.speakerLabel(" "))
        XCTAssertNil(RecordedMeetingTranscriber.speakerLabel(nil))
    }

    // MARK: Deepgram

    func test_deepgram_meeting_is_one_diarized_prerecorded_request() async throws {
        let url = try chunk()
        StubURLProtocol.handler = { _ in
            (200, [:], try Self.json([
                "results": [
                    "channels": [["alternatives": [["transcript": "Hello. How are you? Fine."]]]],
                    "utterances": [
                        ["start": 0.0, "end": 0.8, "transcript": "Hello.", "speaker": 0],
                        ["start": 1.0, "end": 2.0, "transcript": "How are you?", "speaker": 0],
                        ["start": 2.2, "end": 2.8, "transcript": "Fine.", "speaker": 1],
                    ],
                ],
            ]))
        }
        var usage: [AIUsageEvent] = []
        let transcriber = RecordedMeetingTranscriber(
            route: .deepgram(apiKey: "dg-key", model: "nova-3"), session: session, usageSink: { usage.append($0) })

        let result = try await transcriber.transcribe(chunkURLs: [url], language: nil, terms: ["Whytap"])

        XCTAssertEqual(result.segments, [
            TranscriptSegment(speaker: "Speaker 1", start: 0, end: 2, text: "Hello. How are you?"),
            TranscriptSegment(speaker: "Speaker 2", start: 2.2, end: 2.8, text: "Fine."),
        ])
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token dg-key")
        let query = Dictionary(
            (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { $1 })
        XCTAssertEqual(request.url?.path, "/v1/listen")
        XCTAssertEqual(query["model"], "nova-3")
        XCTAssertEqual(query["diarize"], "true")
        XCTAssertEqual(query["utterances"], "true")
        XCTAssertEqual(query["language"], "multi", "Auto keeps the realtime request's language policy")
        XCTAssertEqual(query["keyterm"], "Whytap")
        let body = try XCTUnwrap(StubURLProtocol.capturedBodies.first)
        XCTAssertEqual(body.prefix(4), Data("RIFF".utf8), "a bare WAV body")
        XCTAssertEqual(usage.first?.context, AIUsageContext(feature: .meetings, account: .deepgram, model: "nova-3"))
    }

    func test_deepgram_silence_is_a_final_empty_result() throws {
        let data = try Self.json(["results": ["channels": [["alternatives": [["transcript": ""]]]], "utterances": []]])
        XCTAssertEqual(try RecordedMeetingTranscriber.decodeDeepgram(data), .init(text: "", segments: []))
    }

    func test_deepgram_language_policy_is_checked_before_any_request() async throws {
        let url = try chunk()
        let transcriber = RecordedMeetingTranscriber(
            route: .deepgram(apiKey: "k", model: "nova-3-medical"), session: session, usageSink: { _ in })
        do {
            _ = try await transcriber.transcribe(chunkURLs: [url], language: "ru", terms: [])
            XCTFail("expected the language policy error")
        } catch {
            XCTAssertEqual(error as? DeepgramLanguageConfigurationError, .unsupportedLanguage)
        }
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0)
    }

    // MARK: Route

    func test_route_uses_the_feature_key_and_never_the_streaming_model() throws {
        func resolved(_ account: ProviderAccount, _ model: String, key: String?) -> ResolvedRoute {
            ResolvedRoute(feature: .meetings, account: account, model: model, apiKey: key, server: nil)
        }
        XCTAssertEqual(try RecordedMeetingRoute.make(for: resolved(.elevenLabs, "scribe_v3_live", key: "k")),
                       .elevenLabs(apiKey: "k", model: "scribe_v3"))
        XCTAssertEqual(try RecordedMeetingRoute.make(for: resolved(.deepgram, "nova-3", key: "k")),
                       .deepgram(apiKey: "k", model: "nova-3"))
        XCTAssertNil(try RecordedMeetingRoute.make(for: resolved(.soniox, "stt-async-v6", key: "k")))
        XCTAssertThrowsError(try RecordedMeetingRoute.make(for: resolved(.elevenLabs, "scribe_v3", key: ""))) {
            XCTAssertEqual($0 as? MeetingBYOKProcessingError, .missingTranscriptionKey)
        }
    }
}
