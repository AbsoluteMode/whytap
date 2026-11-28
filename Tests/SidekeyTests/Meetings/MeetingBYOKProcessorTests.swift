import XCTest
@testable import Sidekey

@MainActor
final class MeetingBYOKProcessorTests: XCTestCase {
    private var root: URL!
    private var session: URLSession!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        StubURLProtocol.reset()
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    func testSonioxSilenceStoresNoSpeechNoteWithoutLLMAndReleasesStagedAudio() async throws {
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [0, 0, 0, 0]).write(to: chunk)
        try Data("{}".utf8).write(to: staging.appendingPathComponent("manifest.json"))
        let fileID = UUID().uuidString, jobID = UUID().uuidString
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            let body: [String: Any]
            if path == "/v1/files" { body = ["id": fileID] }
            else if path == "/v1/transcriptions" { body = ["id": jobID] }
            else if path.hasSuffix("/transcript") { body = ["id": jobID, "text": "", "tokens": []] }
            else { body = ["status": "completed"] }
            return (200, [:], try JSONSerialization.data(withJSONObject: body))
        }

        let setup = Setup(meetings: FeatureRoute(account: .soniox, model: "stt-async-v5"))
        let llm = SpyLLMClient()
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let meetingId = UUID()
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: meetingId,
            chunkURLs: [chunk],
            totalDurationSeconds: 4,
            reason: .user
        )

        let id = try await processor.process(
            event: event,
            startedAt: Date(timeIntervalSince1970: 1_000),
            language: nil,
            meetingsStore: store
        )

        XCTAssertEqual(id, meetingId)
        XCTAssertEqual(llm.completeCalls, 0)
        let meta = try await store.list().first { $0.id == meetingId }
        XCTAssertEqual(meta?.title, "No speech detected")
        XCTAssertEqual(meta?.progressStatus, .ready)
        XCTAssertNil(meta?.failureReason)
        let markdown = try await store.markdown(id: meetingId)
        XCTAssertTrue(markdown?.contains("no speech") == true)
        let transcript = try await store.transcript(id: meetingId)
        XCTAssertEqual(transcript, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        await store.close()
    }

    func testSelfHostedUnparseableBaseURLFailsBeforeAnyTranscription() async throws {
        let setup = Setup()
        let server = setup.routing.addServer(name: "S", baseURL: "http://my host:8000")
        setup.routing.setRoute(FeatureRoute(account: .server(server.id), model: "whisper-1"), for: .meetings)
        let processor = setup.processor(openRouterClient: SpyLLMClient(), sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        // No chunks: the adapter is resolved before any audio is read, so the
        // test never opens a socket.
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(),
            chunkURLs: [],
            totalDurationSeconds: 0,
            reason: .user
        )

        do {
            _ = try await processor.process(
                event: event,
                startedAt: Date(timeIntervalSince1970: 1_000),
                language: nil,
                meetingsStore: store
            )
            XCTFail("expected missingSelfHostedBaseURL")
        } catch {
            XCTAssertEqual(error as? MeetingBYOKProcessingError, .missingSelfHostedBaseURL)
        }
        await store.close()
    }

    func test_meeting_uses_the_meetings_route_not_the_drop_route() async throws {
        let setup = Setup(
            meetings: FeatureRoute(account: .deepgram, model: "nova-3"),
            extra: [(.dropFast, FeatureRoute(account: .soniox, model: "stt-rt-v4"))]
        )
        var accounts: [ProviderAccount] = []
        let processor = setup.processor(openRouterClient: SpyLLMClient(), sonioxSession: session, recorded: { route in
            accounts.append(route.account)
            throw StopAfterAdapter()
        })
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        do {
            _ = try await processor.process(event: Self.emptyEvent(), startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected the adapter stub to stop the run")
        } catch is StopAfterAdapter {}
        XCTAssertEqual(accounts, [.deepgram])
        await store.close()
    }

    func test_soniox_meeting_sends_the_route_model() async throws {
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [0, 0, 0, 0]).write(to: chunk)
        let fileID = UUID().uuidString, jobID = UUID().uuidString
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            let body: [String: Any]
            if path == "/v1/files" { body = ["id": fileID] }
            else if path == "/v1/transcriptions" { body = ["id": jobID] }
            else if path.hasSuffix("/transcript") { body = ["id": jobID, "text": "", "tokens": []] }
            else { body = ["status": "completed"] }
            return (200, [:], try JSONSerialization.data(withJSONObject: body))
        }
        let setup = Setup(meetings: FeatureRoute(account: .soniox, model: "stt-async-v5"))
        let processor = setup.processor(openRouterClient: SpyLLMClient(), sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user
        )
        _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
        let index = try XCTUnwrap(StubURLProtocol.capturedRequests.firstIndex { $0.url?.path == "/v1/transcriptions" })
        let body = String(decoding: StubURLProtocol.capturedBodies[index], as: UTF8.self)
        XCTAssertTrue(body.contains("\"model\":\"stt-async-v5\""), body)
        await store.close()
    }

    // MARK: - Pre-recorded APIs (ElevenLabs, Deepgram)

    /// A route still naming the streaming model (synced from an older Mac)
    /// sends the recording to the speech-to-text endpoint with Scribe v3, and
    /// the speakers reach both the stored transcript and the notes model.
    func test_elevenlabs_meeting_goes_to_speech_to_text_with_speakers() async throws {
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [1, 2, 3, 4]).write(to: chunk)
        StubURLProtocol.handler = { _ in
            (200, [:], try JSONSerialization.data(withJSONObject: [
                "text": "We ship Friday. Agreed.",
                "words": [
                    ["text": "We ship Friday.", "type": "word", "start": 0.0, "end": 1.0, "speaker_id": "speaker_0"],
                    ["text": " ", "type": "spacing"],
                    ["text": "Agreed.", "type": "word", "start": 1.2, "end": 1.6, "speaker_id": "speaker_1"],
                ],
            ]))
        }
        let setup = Setup(meetings: FeatureRoute(account: .elevenLabs, model: "scribe_v3_live"))
        let llm = SwitchableLLMClient()
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session, makeAdapter: { _ in
            XCTFail("a meeting on ElevenLabs never opens the realtime socket")
            throw StopAfterAdapter()
        })
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let meetingId = UUID()
        let event = MeetingRecorder.FinalizedEvent(meetingId: meetingId, chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user)

        _ = try await processor.process(event: event, startedAt: Date(), language: "en", meetingsStore: store)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text")
        let body = String(decoding: try XCTUnwrap(StubURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\nscribe_v3\r\n"), "never the streaming model")
        XCTAssertTrue(body.contains("name=\"diarize\"\r\n\r\ntrue\r\n"))
        XCTAssertTrue(body.contains("xi-api-key") == false, "the key is a header, not a form field")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "meetings-key")
        let transcript = try await store.transcript(id: meetingId)
        XCTAssertEqual(transcript?.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertTrue(llm.transcriptsSeen.first?.contains("Speaker 2") == true, "speaker labels reach the notes model")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the staged audio is released after the note")
        await store.close()
    }

    func test_deepgram_silence_stores_no_speech_note_without_llm() async throws {
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [0, 0, 0, 0]).write(to: chunk)
        StubURLProtocol.handler = { _ in
            (200, [:], try JSONSerialization.data(withJSONObject: [
                "results": ["channels": [["alternatives": [["transcript": ""]]]], "utterances": []],
            ]))
        }
        let setup = Setup(meetings: FeatureRoute(account: .deepgram, model: "nova-3"))
        let llm = SpyLLMClient()
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let meetingId = UUID()
        let event = MeetingRecorder.FinalizedEvent(meetingId: meetingId, chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user)

        _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)

        XCTAssertEqual(StubURLProtocol.capturedRequests.first?.url?.path, "/v1/listen")
        XCTAssertEqual(llm.completeCalls, 0)
        let meta = try await store.list().first { $0.id == meetingId }
        XCTAssertEqual(meta?.title, MeetingBYOKProcessor.noSpeechTitle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        await store.close()
    }

    /// A provider refusal leaves the meeting failed with fixed copy and its
    /// audio staged for the retry.
    func test_elevenlabs_out_of_credit_keeps_the_recording() async throws {
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [1, 2, 3, 4]).write(to: chunk)
        StubURLProtocol.handler = { _ in
            (401, [:], try JSONSerialization.data(withJSONObject: ["detail": ["status": "quota_exceeded", "message": "x"]]))
        }
        let setup = Setup(meetings: FeatureRoute(account: .elevenLabs, model: "scribe_v3"))
        let llm = SpyLLMClient()
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let event = MeetingRecorder.FinalizedEvent(meetingId: UUID(), chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user)
        do {
            _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected the refusal")
        } catch let error as MeetingBYOKProcessingError {
            XCTAssertTrue(error.description.contains("ElevenLabs is out of credit."), error.description)
        }
        XCTAssertEqual(llm.completeCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path), "the audio stays for the retry")
        await store.close()
    }

    /// A user's own server has no pre-recorded meeting path here: it keeps
    /// running the recording through its realtime adapter.
    func test_server_meeting_still_uses_the_realtime_adapter() async throws {
        let setup = Setup()
        let server = setup.routing.addServer(name: "S", baseURL: "https://stt.example.test")
        setup.routing.setRoute(FeatureRoute(account: .server(server.id), model: "whisper-1"), for: .meetings)
        var adapters = 0
        let processor = setup.processor(
            openRouterClient: SpyLLMClient(), sonioxSession: session,
            recorded: { _ in XCTFail("a server has no recorded path"); throw StopAfterAdapter() },
            makeAdapter: { _ in adapters += 1; return FixedTranscriptAdapter(text: "Hello team") })
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [1, 2, 3, 4]).write(to: chunk)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let meetingId = UUID()
        _ = try await processor.process(
            event: .init(meetingId: meetingId, chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user),
            startedAt: Date(), language: nil, meetingsStore: store)
        XCTAssertEqual(adapters, 1)
        let transcript = try await store.transcript(id: meetingId)
        XCTAssertEqual(transcript?.map(\.text), ["Hello team"])
        await store.close()
    }

    func test_notes_go_to_the_notes_route() async throws {
        let setup = Setup(
            meetings: FeatureRoute(account: .deepgram, model: "nova-3"),
            notes: FeatureRoute(account: .openRouter, model: "anthropic/claude-3.5-haiku")
        )
        let llm = SpyLLMClient()
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session, recorded: { _ in
            FixedRecordedTranscriber(text: "Hello team")
        })
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [1, 2, 3, 4]).write(to: chunk)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user
        )
        _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
        XCTAssertEqual(llm.models, ["anthropic/claude-3.5-haiku"])
        XCTAssertEqual(llm.endpoints, [.openRouter(apiKey: "or-key")])
        await store.close()
    }

    // MARK: - Transcript kept when the notes fail

    /// Speech is transcribed and paid for; the notes provider is out of
    /// credit. The transcript must be on disk and readable, the failure must
    /// say what happened in fixed words, and the retry must not transcribe
    /// (pay) again.
    func test_notes_out_of_credit_keeps_the_transcript_and_a_retry_does_not_transcribe_again() async throws {
        let setup = Setup(meetings: FeatureRoute(account: .deepgram, model: "nova-3"))
        var transcriptions = 0
        let llm = SwitchableLLMClient()
        llm.failure = OpenRouterLLMError.unexpectedStatus(402, "Insufficient credits. We ship on Friday.")
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session, recorded: { _ in
            transcriptions += 1
            return FixedRecordedTranscriber(text: "We ship on Friday.")
        })
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [1, 2, 3, 4]).write(to: chunk)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let meetingId = UUID()
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: meetingId, chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user
        )

        do {
            _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected the notes failure")
        } catch let failure as MeetingNotesFailure {
            XCTAssertEqual(failure.description,
                           "The Meeting notes provider is out of credit. " + MeetingNotesFailure.transcriptKept)
            XCTAssertFalse(failure.description.contains("Friday"), "the provider's own text is never shown")
        }
        XCTAssertEqual(transcriptions, 1)
        let kept = try await store.transcriptAwaitingNote(meetingId: meetingId)
        XCTAssertEqual(kept?.map(\.text), ["We ship on Friday."], "the transcript is readable without a note")
        let noteBefore = try await store.markdown(id: meetingId)
        XCTAssertNil(noteBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path), "the audio stays for the retry")

        // The user tops up; launch recovery runs the same recording again.
        llm.failure = nil
        _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)

        XCTAssertEqual(transcriptions, 1, "the speech provider is not called or paid a second time")
        XCTAssertEqual(llm.transcriptsSeen.count, 2)
        XCTAssertTrue(llm.transcriptsSeen.last?.contains("We ship on Friday.") == true)
        let note = try await store.markdown(id: meetingId)
        XCTAssertNotNil(note)
        let stored = try await store.transcript(id: meetingId)
        XCTAssertEqual(stored?.map(\.text), ["We ship on Friday."])
        let leftover = try await store.pendingTranscript(recordingId: meetingId)
        XCTAssertNil(leftover)
        let awaiting = try await store.transcriptAwaitingNote(meetingId: meetingId)
        XCTAssertNil(awaiting)
        await store.close()
    }

    func test_notes_are_written_from_the_kept_transcript_after_the_recording_is_gone() async throws {
        let setup = Setup(meetings: FeatureRoute(account: .deepgram, model: "nova-3"))
        let llm = SwitchableLLMClient()
        var transcriptions = 0
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session, recorded: { _ in
            transcriptions += 1
            return FixedRecordedTranscriber(text: "unused")
        })
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let meetingId = UUID()
        let started = Date(timeIntervalSince1970: 1_000)
        let retry = MeetingNotesRetry(
            meetingId: meetingId, startedAt: started, endedAt: started.addingTimeInterval(60), durationSeconds: 60
        )

        let nothingKept = try await processor.writeNotesFromKeptTranscript(retry, language: nil, meetingsStore: store)
        XCTAssertFalse(nothingKept, "no transcript, nothing to write")
        XCTAssertEqual(llm.transcriptsSeen.count, 0)

        let segments = [
            TranscriptSegment(speaker: "Speaker 1", start: 0, end: 3, text: "We ship on Friday."),
            TranscriptSegment(speaker: "Speaker 2", start: 3, end: 6, text: "Agreed."),
        ]
        try await store.savePendingTranscript(recordingId: meetingId, meetingId: meetingId, segments: segments)

        // Kept, but the meeting itself was deleted meanwhile: nothing is written.
        let deleted = try await processor.writeNotesFromKeptTranscript(retry, language: "en", meetingsStore: store)
        XCTAssertFalse(deleted, "a note must not bring a deleted meeting back")
        XCTAssertEqual(llm.transcriptsSeen.count, 0, "and the notes model is not paid for it")

        try await store.upsertProgress(
            meta: MeetingMetaWithLocalState(
                id: meetingId, startedAt: started, endedAt: started.addingTimeInterval(60), durationSeconds: 60,
                title: nil, syncStatus: .new, serverVersion: 1, createdAt: started),
            status: .failed, failureReason: "out of credit")

        let wrote = try await processor.writeNotesFromKeptTranscript(retry, language: "en", meetingsStore: store)

        XCTAssertTrue(wrote)
        XCTAssertEqual(transcriptions, 0, "no recording, no speech provider")
        XCTAssertTrue(llm.transcriptsSeen.first?.contains("Speaker 2") == true, "speaker labels reach the notes model")
        let stored = try await store.transcript(id: meetingId)
        XCTAssertEqual(stored, segments)
        let meta = try await store.list().first { $0.id == meetingId }
        XCTAssertEqual(meta?.progressStatus, .ready)
        XCTAssertEqual(meta?.durationSeconds, 60)
        await store.close()
    }

    /// The notes key was removed after the transcript was kept: that is "no
    /// notes model", so the meeting is stored with its transcript only rather
    /// than failed again.
    func test_kept_transcript_with_the_notes_key_removed_is_stored_with_its_transcript_only() async throws {
        let setup = Setup(meetings: FeatureRoute(account: .deepgram, model: "nova-3"))
        var transcriptions = 0
        let llm = SwitchableLLMClient()
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session, recorded: { _ in
            transcriptions += 1
            return FixedRecordedTranscriber(text: "unused")
        })
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let meetingId = UUID()
        try await store.savePendingTranscript(
            recordingId: meetingId, meetingId: meetingId,
            segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "We ship on Friday.")])
        try setup.keys.delete(account: OpenRouterLLMKeyStore.account)
        let event = MeetingRecorder.FinalizedEvent(meetingId: meetingId, chunkURLs: [], totalDurationSeconds: 1, reason: .user)

        _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)

        XCTAssertEqual(transcriptions, 0, "the kept transcript is reused")
        XCTAssertTrue(llm.transcriptsSeen.isEmpty)
        let note = try await store.markdown(id: meetingId)
        XCTAssertEqual(note, MeetingBYOKProcessor.transcriptOnlyMarkdown)
        let stored = try await store.transcript(id: meetingId)
        XCTAssertEqual(stored?.map(\.text), ["We ship on Friday."])
        let leftover = try await store.pendingTranscript(recordingId: meetingId)
        XCTAssertNil(leftover)
        await store.close()
    }

    func test_a_continued_calls_notes_failure_does_not_point_at_a_tab_it_cannot_open() {
        let failure = MeetingNotesFailure(OpenRouterLLMError.unexpectedStatus(402, nil), isLaterPart: true)
        XCTAssertTrue(failure.description.hasSuffix(MeetingNotesFailure.partTranscriptKept))
        XCTAssertFalse(failure.description.contains("Transcript tab"))
    }

    func test_notes_failure_wording_names_the_cause_and_never_quotes_the_provider() {
        let cases: [(Error, String)] = [
            (OpenRouterLLMError.missingKey, "key of the Meeting notes provider is missing"),
            (OpenRouterLLMError.notConfigured, "Meeting notes has no model"),
            (OpenRouterLLMError.unexpectedStatus(401, "secret body"), "refused the key"),
            (OpenRouterLLMError.unexpectedStatus(402, "secret body"), "out of credit"),
            (OpenRouterLLMError.unexpectedStatus(429, "secret body"), "busy or its limit"),
            (OpenRouterLLMError.unexpectedStatus(503, "secret body"), "not responding (503)"),
            (OpenRouterLLMError.unexpectedStatus(404, "secret body"), "refused the request (404)"),
            (URLError(.notConnectedToInternet), "No connection"),
        ]
        for (error, expected) in cases {
            let text = MeetingNotesFailure(error).description
            XCTAssertTrue(text.contains(expected), "\(error): \(text)")
            XCTAssertFalse(text.contains("secret body"))
            XCTAssertTrue(text.hasSuffix(MeetingNotesFailure.transcriptKept))
        }
    }

    func test_deleting_a_meeting_removes_its_kept_transcript() async throws {
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let id = UUID()
        let started = Date(timeIntervalSince1970: 1_000)
        try await store.upsertProgress(
            meta: MeetingMetaWithLocalState(
                id: id, startedAt: started, endedAt: started, durationSeconds: 1, title: nil,
                syncStatus: .new, serverVersion: 1, createdAt: started),
            status: .failed, failureReason: "x")
        try await store.savePendingTranscript(
            recordingId: id, meetingId: id,
            segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "private words")])

        try await store.delete(id: id)

        let kept = try await store.pendingTranscript(recordingId: id)
        XCTAssertNil(kept)
        await store.close()
    }

    func test_notes_model_refusal_is_recorded_for_meeting_notes() async throws {
        let setup = Setup(
            meetings: FeatureRoute(account: .deepgram, model: "nova-3"),
            notes: FeatureRoute(account: .openRouter, model: "vendor/gone")
        )
        let defaults = UserDefaults(suiteName: "meeting.checks.\(UUID().uuidString)")!
        let checks = ModelCheckStore(defaults: defaults)
        let processor = MeetingBYOKProcessor(
            routing: setup.routing,
            keys: setup.keys,
            vocab: setup.vocab,
            notesRoute: DirectLLMRouteResolver(feature: .meetingNotes, routing: setup.routing, keys: setup.keys),
            openRouterClient: RefusingLLMClient(status: 404),
            checks: checks,
            sonioxSession: session,
            makeRecordedTranscriber: { _ in FixedRecordedTranscriber(text: "Hello team") }
        )
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [1, 2, 3, 4]).write(to: chunk)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user
        )
        do {
            _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("Expected the refusal to reach the caller")
        } catch let error as MeetingNotesFailure {
            XCTAssertEqual(error, MeetingNotesFailure(OpenRouterLLMError.unexpectedStatus(404, nil)))
        }
        XCTAssertEqual(checks.refusedModel(for: .meetingNotes), "vendor/gone")
        XCTAssertNil(checks.refusedModel(for: .meetings))
        await store.close()
    }

    func test_notes_success_clears_the_refusal_of_that_model() async throws {
        let setup = Setup(
            meetings: FeatureRoute(account: .deepgram, model: "nova-3"),
            notes: FeatureRoute(account: .openRouter, model: "vendor/back")
        )
        let defaults = UserDefaults(suiteName: "meeting.checks.\(UUID().uuidString)")!
        let checks = ModelCheckStore(defaults: defaults)
        checks.recordRefusal(feature: .meetingNotes, model: "vendor/back", at: Date())
        let processor = MeetingBYOKProcessor(
            routing: setup.routing,
            keys: setup.keys,
            vocab: setup.vocab,
            notesRoute: DirectLLMRouteResolver(feature: .meetingNotes, routing: setup.routing, keys: setup.keys),
            openRouterClient: SpyLLMClient(),
            checks: checks,
            sonioxSession: session,
            makeRecordedTranscriber: { _ in FixedRecordedTranscriber(text: "Hello team") }
        )
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [1, 2, 3, 4]).write(to: chunk)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user
        )
        _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
        XCTAssertNil(checks.refusedModel(for: .meetingNotes))
        await store.close()
    }

    func test_a_speech_model_alone_is_enough_to_process_a_meeting() {
        let both = Setup(meetings: FeatureRoute(account: .soniox, model: "stt-async-v5"))
        XCTAssertTrue(both.processor(openRouterClient: SpyLLMClient(), sonioxSession: session).shouldProcessDirectly())
        let noNotes = Setup(meetings: FeatureRoute(account: .soniox, model: "stt-async-v5"), notes: nil)
        XCTAssertTrue(noNotes.processor(openRouterClient: SpyLLMClient(), sonioxSession: session).shouldProcessDirectly(),
                      "without a notes model the meeting keeps its transcript only")
        let noMeetings = Setup(meetings: nil)
        XCTAssertFalse(noMeetings.processor(openRouterClient: SpyLLMClient(), sonioxSession: session).shouldProcessDirectly())
    }

    func test_not_configured_message_points_to_api_and_models() {
        XCTAssertEqual(
            MeetingsCoordinator.processorNotConfiguredMessage,
            "Choose models for Meetings and Meeting notes in Settings > Keys & models to process this meeting."
        )
    }

    func test_missing_meetings_key_maps_to_the_transcription_key_error() async throws {
        let setup = Setup(meetings: FeatureRoute(account: .deepgram, model: "nova-3"), saveMeetingsKey: false)
        let processor = setup.processor(openRouterClient: SpyLLMClient(), sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        do {
            _ = try await processor.process(event: Self.emptyEvent(), startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected missingTranscriptionKey")
        } catch {
            XCTAssertEqual(error as? MeetingBYOKProcessingError, .missingTranscriptionKey)
        }
        await store.close()
    }

    func testContinuationTranscribesOnlyFreshAudioAndRecoveryAppendsOnce() async throws {
        let setup = Setup(meetings: FeatureRoute(account: .deepgram, model: "nova-3"))
        let llm = SpyLLMClient()
        var adapters = 0
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session, recorded: { _ in
            adapters += 1
            return FixedRecordedTranscriber(text: adapters == 1 ? "First call" : "Second call")
        })
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let stagingRoot = root.appendingPathComponent("staging")
        let id = UUID(), recording = UUID()
        func chunk(_ id: UUID) throws -> URL {
            let dir = stagingRoot.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("chunk-000.wav")
            try Self.wav(samples: [1, 2, 3, 4]).write(to: url)
            return url
        }
        let first = try chunk(id)
        _ = try await processor.process(event: .init(meetingId: id, chunkURLs: [first],
            totalDurationSeconds: 4, reason: .autoEnd), startedAt: Date(timeIntervalSince1970: 1000),
            language: nil, meetingsStore: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        let second = try chunk(recording)
        var manifest = MeetingFinalizeManifest(recorderMeetingId: recording,
            startedAt: Date(timeIntervalSince1970: 1124), endedAt: Date(timeIntervalSince1970: 1128),
            durationSeconds: 4, language: nil, chunkFileNames: [second.lastPathComponent], isFinal: true)
        manifest.continuation = .init(meetingId: id, precedingRecordingId: id,
            startedAt: Date(timeIntervalSince1970: 1000), audioOffsetSeconds: 4, gapSeconds: 120)
        let manifests = MeetingFinalizeManifestStore()
        try manifests.write(manifest, to: second.deletingLastPathComponent())
        let defaults = UserDefaults(suiteName: "continuation.recovery.\(UUID().uuidString)")!
        let coordinator = MeetingsCoordinator(config: MeetingsConfig(defaults: defaults),
            detector: StubbedMeetingDetector(), stagingRoot: { stagingRoot },
            meetingsStore: store, directProcessor: processor, meetingsEnabled: { true })
        await coordinator.recoverFinalizeManifestsOnLaunch()
        let rows = try await store.list()
        let transcript = try await store.transcript(id: id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, id)
        XCTAssertEqual(rows.first?.durationSeconds, 8)
        XCTAssertEqual(transcript?.map(\.text), ["First call", "Reconnected after 2m 0s", "Second call"])
        XCTAssertEqual(adapters, 2)
        XCTAssertEqual(llm.completeCalls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        // A crash after the content commit but before staging cleanup must
        // clean the leftover without a third ASR/LLM call or duplicate text.
        _ = try chunk(recording)
        try manifests.write(manifest, to: second.deletingLastPathComponent())
        await coordinator.recoverFinalizeManifestsOnLaunch()
        XCTAssertEqual(adapters, 2)
        XCTAssertEqual(llm.completeCalls, 2)
        let restored = try await store.transcript(id: id)
        XCTAssertEqual(restored, transcript)
        await store.close()
    }

    func testContinuationWaitsForFailedPrecedingPartWithoutCallingProviders() async throws {
        let setup = Setup(meetings: FeatureRoute(account: .deepgram, model: "nova-3"))
        let llm = SpyLLMClient()
        var adapterCalls = 0
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session, recorded: { _ in
            adapterCalls += 1
            return FixedRecordedTranscriber(text: "Never sent")
        })
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        do {
            _ = try await processor.process(event: Self.emptyEvent(), startedAt: Date(), language: nil,
                meetingsStore: store, continuation: .init(meetingId: UUID(), precedingRecordingId: UUID(),
                    startedAt: Date(), audioOffsetSeconds: 42, gapSeconds: 60))
            XCTFail("Expected dependency deferral")
        } catch is MeetingContinuationError {}
        XCTAssertEqual(adapterCalls, 0)
        XCTAssertEqual(llm.completeCalls, 0)
        await store.close()
    }

    // MARK: - No Meeting notes model: the meeting keeps its transcript only
    // WHY: .project-docs/decisions/2026-11-28-meeting-transcript-without-notes-model.md

    /// A clean Mac with only Parakeet downloaded and no notes model, no keys:
    /// the meeting is transcribed and finishes as an ordinary meeting with its
    /// transcript. No failure, no failed event, the audio is released.
    func test_parakeet_only_without_a_notes_model_finishes_with_the_transcript_and_no_failure() async throws {
        let harness = try TranscriptOnlyHarness(test: self, root: root, session: session)
        let meetingId = UUID()

        await harness.finish(meetingId, text: "We ship on Friday.")

        XCTAssertEqual(harness.events.names, ["transcript"], "no failed event, no notes-ready event")
        let row = try await harness.row(meetingId)
        XCTAssertEqual(row?.progressStatus, .ready)
        XCTAssertNil(row?.failureReason)
        XCTAssertEqual(row?.title, MeetingBYOKProcessor.transcriptOnlyTitle)
        let transcript = try await harness.store.transcript(id: meetingId)
        XCTAssertEqual(transcript?.map(\.text), ["We ship on Friday."])
        XCTAssertEqual(harness.adapterCalls, 1)
        XCTAssertTrue(harness.llm.transcriptsSeen.isEmpty, "no notes model is asked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.dir(meetingId).path),
                       "the audio goes like after any finished meeting")

        // MCP tools and search: no note, the transcript is readable and found.
        let document = try await harness.store.document(id: meetingId)
        XCTAssertNil(document?.note, "the fixed transcript-only note is not a note")
        XCTAssertEqual(document?.transcript?.map(\.text), ["We ship on Friday."])
        let found = try await harness.store.search(MeetingSearchRequest(query: "friday", limit: 5))
        XCTAssertEqual(found.hits.map(\.meta.id), [meetingId])
        XCTAssertEqual(found.hits.first?.hasNote, false)
        let noteWords = try await harness.store.search(MeetingSearchRequest(query: "model", limit: 5))
        XCTAssertTrue(noteWords.hits.isEmpty, "the fixed explanation is not searchable as a note")

        // Relaunch: nothing is staged, nothing is retried, nothing fails.
        await harness.coordinator.recoverFinalizeManifestsOnLaunch()
        let after = try await harness.row(meetingId)
        XCTAssertEqual(after?.progressStatus, .ready)
        XCTAssertNil(after?.failureReason)
        XCTAssertEqual(harness.adapterCalls, 1)
        await harness.close()
    }

    /// The user adds a notes model later and clicks Make notes: the notes are
    /// made from the stored transcript without the speech model, and the
    /// meeting's title comes from them.
    func test_make_notes_after_a_model_is_added_uses_the_stored_transcript() async throws {
        let harness = try TranscriptOnlyHarness(test: self, root: root, session: session)
        let meetingId = UUID()
        await harness.finish(meetingId, text: "We ship on Friday.")

        // Make notes before a model exists: nothing is made, nothing fails.
        let early = await harness.coordinator.retryNotes(meetingId: meetingId)
        XCTAssertFalse(early)
        let waiting = try await harness.row(meetingId)
        XCTAssertEqual(waiting?.progressStatus, .ready, "a transcript-only meeting is never marked failed")
        XCTAssertEqual(waiting?.failureReason, "Meeting notes has no model. Choose one in Settings > Keys & models.")

        harness.addNotesModel()
        let made = await harness.coordinator.retryNotes(meetingId: meetingId)

        XCTAssertTrue(made)
        XCTAssertEqual(harness.adapterCalls, 1, "the speech model is not run again")
        XCTAssertEqual(harness.llm.transcriptsSeen.count, 1)
        XCTAssertTrue(harness.llm.transcriptsSeen.first?.contains("We ship on Friday.") == true)
        let note = try await harness.store.markdown(id: meetingId)
        XCTAssertEqual(note, "<!-- protocol:v1 -->\n# Release plan")
        let row = try await harness.row(meetingId)
        XCTAssertEqual(row?.title, "Release plan")
        XCTAssertEqual(row?.progressStatus, .ready)
        XCTAssertNil(row?.failureReason)
        XCTAssertEqual(harness.events.names.last, "notes")
        let document = try await harness.store.document(id: meetingId)
        XCTAssertNotNil(document?.note)

        // A second click finds the notes made and pays for nothing.
        let again = await harness.coordinator.retryNotes(meetingId: meetingId)
        XCTAssertFalse(again)
        XCTAssertEqual(harness.llm.transcriptsSeen.count, 1)
        await harness.close()
    }

    /// A configured notes model that fails on Make notes keeps the meeting a
    /// ready transcript-only meeting with the reason for the pane.
    func test_make_notes_with_a_failing_model_keeps_the_transcript_only_meeting_ready_with_the_reason() async throws {
        let harness = try TranscriptOnlyHarness(test: self, root: root, session: session)
        let meetingId = UUID()
        await harness.finish(meetingId, text: "We ship on Friday.")
        harness.addNotesModel()
        harness.llm.failure = OpenRouterLLMError.unexpectedStatus(402, "Insufficient credits. We ship on Friday.")

        let made = await harness.coordinator.retryNotes(meetingId: meetingId)

        XCTAssertFalse(made)
        let row = try await harness.row(meetingId)
        XCTAssertEqual(row?.progressStatus, .ready)
        XCTAssertEqual(row?.failureReason, "The Meeting notes provider is out of credit.")
        let note = try await harness.store.markdown(id: meetingId)
        XCTAssertEqual(note, MeetingBYOKProcessor.transcriptOnlyMarkdown)
        XCTAssertFalse(harness.events.names.contains("failed"))
        await harness.close()
    }

    /// A continued call without a notes model: its transcript joins the
    /// meeting's, and Make notes later covers both parts at once.
    func test_continued_call_without_a_notes_model_adds_its_transcript_and_make_notes_covers_both() async throws {
        let harness = try TranscriptOnlyHarness(test: self, root: root, session: session)
        let meetingId = UUID(), part = UUID()
        await harness.finish(meetingId, text: "First call")

        await harness.finish(part, text: "Second call", continuation: MeetingContinuation(
            meetingId: meetingId, precedingRecordingId: meetingId,
            startedAt: harness.started, audioOffsetSeconds: 4, gapSeconds: 120))

        let rows = try await harness.store.list()
        XCTAssertEqual(rows.map(\.id), [meetingId], "one meeting")
        XCTAssertEqual(rows.first?.progressStatus, .ready)
        XCTAssertNil(rows.first?.failureReason)
        let transcript = try await harness.store.transcript(id: meetingId)
        XCTAssertEqual(transcript?.map(\.text), ["First call", "Reconnected after 2m 0s", "Second call"])
        let note = try await harness.store.markdown(id: meetingId)
        XCTAssertEqual(note, MeetingBYOKProcessor.transcriptOnlyMarkdown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.dir(part).path))
        XCTAssertEqual(harness.events.names, ["transcript", "transcript"])

        harness.addNotesModel()
        let made = await harness.coordinator.retryNotes(meetingId: meetingId)
        XCTAssertTrue(made)
        let seen = harness.llm.transcriptsSeen.first ?? ""
        XCTAssertTrue(seen.contains("First call") && seen.contains("Second call"), "the notes cover every part")
        await harness.close()
    }

    /// A meeting that already has notes, continued after the notes model was
    /// removed: the continued call's transcript is added, the notes stay.
    func test_continued_call_of_a_meeting_with_notes_keeps_the_notes_and_adds_the_transcript() async throws {
        let harness = try TranscriptOnlyHarness(test: self, root: root, session: session)
        harness.addNotesModel()
        let meetingId = UUID(), part = UUID()
        await harness.finish(meetingId, text: "First call")
        let note = try await harness.store.markdown(id: meetingId)
        harness.removeNotesModel()

        await harness.finish(part, text: "Second call", continuation: MeetingContinuation(
            meetingId: meetingId, precedingRecordingId: meetingId,
            startedAt: harness.started, audioOffsetSeconds: 4, gapSeconds: 120))

        let after = try await harness.store.markdown(id: meetingId)
        XCTAssertEqual(after, note, "the notes are not replaced")
        let transcript = try await harness.store.transcript(id: meetingId)
        XCTAssertEqual(transcript?.map(\.text), ["First call", "Reconnected after 2m 0s", "Second call"])
        let row = try await harness.row(meetingId)
        XCTAssertEqual(row?.progressStatus, .ready)
        XCTAssertNil(row?.failureReason)
        XCTAssertFalse(harness.events.names.contains("failed"))
        await harness.close()
    }

    /// A meeting that failed with "not configured" before this change is
    /// still staged: the next launch makes it a transcript-only meeting.
    func test_relaunch_turns_a_staged_not_configured_meeting_into_a_transcript_only_meeting() async throws {
        let harness = try TranscriptOnlyHarness(test: self, root: root, session: session)
        let meetingId = UUID()
        try harness.stage(meetingId)
        try await harness.store.upsertProgress(
            meta: MeetingMetaWithLocalState(
                id: meetingId, startedAt: harness.started, endedAt: harness.started.addingTimeInterval(4),
                durationSeconds: 4, title: nil, syncStatus: .new, serverVersion: 0, createdAt: harness.started),
            status: .failed, failureReason: MeetingsCoordinator.processorNotConfiguredMessage)
        harness.adapterText = "We ship on Friday."

        await harness.coordinator.recoverFinalizeManifestsOnLaunch()

        let row = try await harness.row(meetingId)
        XCTAssertEqual(row?.progressStatus, .ready)
        XCTAssertNil(row?.failureReason)
        let transcript = try await harness.store.transcript(id: meetingId)
        XCTAssertEqual(transcript?.map(\.text), ["We ship on Friday."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.dir(meetingId).path))
        await harness.close()
    }

    /// A configured notes model that fails while the meeting is processed is
    /// still a failure, as before: failed row, failed event, audio kept.
    func test_configured_notes_model_failing_during_processing_still_fails_the_meeting() async throws {
        let harness = try TranscriptOnlyHarness(test: self, root: root, session: session)
        harness.addNotesModel()
        harness.llm.failure = OpenRouterLLMError.unexpectedStatus(402, "no credit")
        let meetingId = UUID()

        await harness.finish(meetingId, text: "We ship on Friday.")

        XCTAssertEqual(harness.events.names, ["failed"])
        let row = try await harness.row(meetingId)
        XCTAssertEqual(row?.progressStatus, .failed)
        XCTAssertEqual(row?.failureReason,
                       "The Meeting notes provider is out of credit. " + MeetingNotesFailure.transcriptKept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.dir(meetingId).path))
        await harness.close()
    }

    /// Nothing can transcribe (Parakeet not downloaded) and no notes model:
    /// as before, failed with the "not configured" copy and the audio staged.
    func test_nothing_configured_still_fails_with_the_not_configured_copy_and_keeps_the_audio() async throws {
        let harness = try TranscriptOnlyHarness(test: self, root: root, session: session, speechReady: false)
        let meetingId = UUID()

        await harness.finish(meetingId, text: "unused")

        XCTAssertEqual(harness.events.names, ["failed"])
        let row = try await harness.row(meetingId)
        XCTAssertEqual(row?.progressStatus, .failed)
        XCTAssertEqual(row?.failureReason, MeetingsCoordinator.processorNotConfiguredMessage)
        XCTAssertEqual(harness.adapterCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.dir(meetingId).path))
        await harness.close()
    }

    /// One meeting through the real processor and coordinator, with the
    /// Meetings route on this Mac (Parakeet) and no Meeting notes model.
    @MainActor private final class TranscriptOnlyHarness {
        let setup: Setup
        let llm: SwitchableLLMClient
        let store: MeetingsStore
        let coordinator: MeetingsCoordinator
        let stagingRoot: URL
        let events = EventLog()
        let started = Date(timeIntervalSince1970: 1_000)
        var adapterCalls = 0
        var adapterText = ""
        private var reader: Task<Void, Never>?

        init(test: XCTestCase, root: URL, session: URLSession, speechReady: Bool = true) throws {
            setup = Setup(meetings: FeatureRoute(account: .thisMac, model: OnDeviceSpeechModel.parakeetTdtV3.rawValue),
                          notes: nil)
            let client = SwitchableLLMClient()
            llm = client
            let meetingsStore = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
            store = meetingsStore
            let staging = root.appendingPathComponent("staging")
            stagingRoot = staging
            var harness: TranscriptOnlyHarness?
            let processor = setup.processor(
                openRouterClient: client, sonioxSession: session,
                recorded: { _ in XCTFail("this Mac has no recorded path"); throw StopAfterAdapter() },
                makeAdapter: { _ in
                    harness?.adapterCalls += 1
                    return FixedTranscriptAdapter(text: harness?.adapterText ?? "")
                },
                onDevice: speechReady ? .ready : OnDeviceSpeechReadiness { false })
            let defaults = UserDefaults(suiteName: "transcript.only.\(UUID().uuidString)")!
            coordinator = MeetingsCoordinator(config: MeetingsConfig(defaults: defaults),
                detector: StubbedMeetingDetector(), stagingRoot: { staging },
                meetingsStore: meetingsStore, directProcessor: processor, meetingsEnabled: { true })
            harness = self
            let stream = coordinator.events
            let log = events
            reader = Task { @MainActor in for await event in stream { log.append(event) } }
        }

        func dir(_ id: UUID) -> URL { stagingRoot.appendingPathComponent(id.uuidString) }

        @discardableResult
        func stage(_ id: UUID) throws -> URL {
            try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
            let chunk = dir(id).appendingPathComponent("chunk-000.wav")
            try MeetingBYOKProcessorTests.wav(samples: [1, 2, 3, 4]).write(to: chunk)
            let manifest = MeetingFinalizeManifest(recorderMeetingId: id, startedAt: started,
                endedAt: started.addingTimeInterval(4), durationSeconds: 4, language: nil,
                chunkFileNames: [chunk.lastPathComponent], isFinal: true)
            try MeetingFinalizeManifestStore().write(manifest, to: dir(id))
            return chunk
        }

        /// Stop: the recording is handed to processing and processed.
        func finish(_ id: UUID, text: String, continuation: MeetingContinuation? = nil) async {
            adapterText = text
            let expected = events.names.count + 1
            guard let chunk = try? stage(id) else { return XCTFail("could not stage") }
            await coordinator.dispatchFinalizedForProcessing(
                event: .init(meetingId: id, chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user),
                startedAt: continuation == nil ? started : started.addingTimeInterval(124),
                endedAt: nil, reconnectMarkers: [], language: nil, continuation: continuation)
            await events.wait(for: expected)
        }

        func row(_ id: UUID) async throws -> MeetingMetaWithLocalState? {
            try await store.list().first { $0.id == id }
        }

        func addNotesModel() {
            setup.routing.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/auto"), for: .meetingNotes)
        }

        func removeNotesModel() { setup.routing.setRoute(nil, for: .meetingNotes) }

        func close() async {
            reader?.cancel()
            await store.close()
        }
    }

    @MainActor private final class EventLog {
        private(set) var names: [String] = []

        func append(_ event: MeetingsCoordinatorEvent) {
            switch event {
            case .newMeetingAvailable: names.append("notes")
            case .meetingTranscriptAvailable: names.append("transcript")
            case .meetingFailed: names.append("failed")
            }
        }

        func wait(for count: Int) async {
            for _ in 0..<200 where names.count < count {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    private static func emptyEvent() -> MeetingRecorder.FinalizedEvent {
        MeetingRecorder.FinalizedEvent(meetingId: UUID(), chunkURLs: [], totalDurationSeconds: 0, reason: .user)
    }

    /// In-memory routing and keys: a Meetings route (with its provider's key),
    /// a Meeting notes route on OpenRouter (key `or-key`), and any extra routes.
    @MainActor private struct Setup {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let vocab: VocabularyCache

        init(
            meetings: FeatureRoute? = nil,
            notes: FeatureRoute? = FeatureRoute(account: .openRouter, model: "openrouter/auto"),
            extra: [(AIFeature, FeatureRoute)] = [],
            saveMeetingsKey: Bool = true
        ) {
            let defaults = UserDefaults(suiteName: "meeting.byok.\(UUID().uuidString)")!
            routing = AIRoutingStore(defaults: defaults)
            let box = InMemoryTokenStore.Box()
            keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
            vocab = VocabularyCache(defaults: defaults)
            routing.setRoute(meetings, for: .meetings)
            routing.setRoute(notes, for: .meetingNotes)
            for (feature, route) in extra { routing.setRoute(route, for: feature) }
            try? keys.save("or-key", account: OpenRouterLLMKeyStore.account)
            if saveMeetingsKey, let account = meetings?.account.keychainAccount(in: routing) {
                try? keys.save("meetings-key", account: account)
            }
            for (_, route) in extra {
                if let account = route.account.keychainAccount(in: routing) {
                    try? keys.save("extra-key", account: account)
                }
            }
        }

        @MainActor
        func processor(
            openRouterClient: any OpenRouterLLMClienting,
            sonioxSession: URLSession,
            recorded: ((RecordedMeetingRoute) throws -> any MeetingRecordedTranscribing)? = nil,
            makeAdapter: @escaping (ResolvedRoute) throws -> BYOKTranscriptionAdapter = RealtimeAdapterFactory.make,
            onDevice: OnDeviceSpeechReadiness = .live
        ) -> MeetingBYOKProcessor {
            MeetingBYOKProcessor(
                routing: routing,
                keys: keys,
                vocab: vocab,
                notesRoute: DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys),
                openRouterClient: openRouterClient,
                sonioxSession: sonioxSession,
                makeAdapter: makeAdapter,
                makeRecordedTranscriber: recorded ?? { route in
                    RecordedMeetingTranscriber(route: route, session: sonioxSession, usageSink: { _ in })
                },
                onDevice: onDevice
            )
        }
    }

    private static func wav(samples: [UInt8]) -> Data {
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(samples.count + 36)); data.append(Data("WAVEfmt ".utf8)); append(16)
        data.append(contentsOf: [1, 0, 1, 0]); append(16000); append(32000)
        data.append(contentsOf: [2, 0, 16, 0]); data.append(Data("data".utf8)); append(UInt32(samples.count))
        data.append(contentsOf: samples)
        return data
    }
}

private struct StopAfterAdapter: Error {}

private final class SpyLLMClient: OpenRouterLLMClienting {
    private(set) var completeCalls = 0
    private(set) var models: [String] = []
    private(set) var endpoints: [OpenAICompatibleLLMEndpoint] = []

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        []
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        completeCalls += 1
        models.append(model)
        endpoints.append(endpoint)
        return "<!-- protocol:v1 -->\n# Unexpected note"
    }
}

/// Fails with `failure` while it is set, then writes a note. Remembers the
/// transcript each request carried.
private final class SwitchableLLMClient: OpenRouterLLMClienting {
    var failure: Error?
    private(set) var transcriptsSeen: [String] = []

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] { [] }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        transcriptsSeen.append(messages.last?.content ?? "")
        if let failure { throw failure }
        return "<!-- protocol:v1 -->\n# Release plan"
    }
}

private final class RefusingLLMClient: OpenRouterLLMClienting {
    let status: Int

    init(status: Int) {
        self.status = status
    }

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        []
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        throw OpenRouterLLMError.unexpectedStatus(status, nil)
    }
}

/// A recorded-API transcriber that answers with one unlabelled segment.
private struct FixedRecordedTranscriber: MeetingRecordedTranscribing {
    let text: String

    func transcribe(chunkURLs: [URL], language: String?, terms: [String]) async throws -> SonioxMeetingTranscriber.Result {
        .init(text: text, segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)])
    }
}

private struct FixedTranscriptAdapter: BYOKTranscriptionAdapter {
    let text: String

    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
        FixedTranscriptSession(text: text)
    }
}

private final class FixedTranscriptSession: BYOKUpstreamSession {
    let events: AsyncStream<BYOKStreamEvent>
    private let continuation: AsyncStream<BYOKStreamEvent>.Continuation
    private let text: String

    init(text: String) {
        self.text = text
        (events, continuation) = AsyncStream.makeStream(of: BYOKStreamEvent.self)
    }

    func sendAudio(_ pcm: Data) async {}
    func endInput() async { continuation.yield(.done(text)); continuation.finish() }
    func close() async { continuation.finish() }
}
