import XCTest
@testable import Sidekey

final class SonioxMeetingTranscriberTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private let fileID = UUID().uuidString
    private let jobID = UUID().uuidString

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

    private func save(_ checkpoint: SonioxMeetingTranscriber.Checkpoint) throws {
        try JSONEncoder().encode(checkpoint).write(to: directory.appendingPathComponent("soniox-transcription.json"))
    }

    func testMultipartContainsSingleWAVHeaderAndOrderedPCM() throws {
        let first = try chunk()
        let second = try chunk("chunk-001.wav", samples: [5, 6])
        let output = directory.appendingPathComponent("upload")
        try SonioxMeetingTranscriber.writeUpload(chunkURLs: [first, second], to: output, boundary: "test")
        let data = try Data(contentsOf: output)
        let headerStart = try XCTUnwrap(data.range(of: Data("RIFF".utf8))).lowerBound
        XCTAssertEqual(Array(data[(headerStart + 40)..<(headerStart + 50)]), [6, 0, 0, 0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(data.range(of: Data("RIFF".utf8), in: (headerStart + 4)..<data.count), nil)
    }

    func testRejectsWrongSampleRateAndTruncatedChunks() throws {
        let url = try chunk()
        var data = try Data(contentsOf: url)
        data[24] = 0
        try data.write(to: url)
        XCTAssertThrowsError(try SonioxMeetingTranscriber.writeUpload(chunkURLs: [url], to: directory.appendingPathComponent("upload"), boundary: "test"))
        try Data([1, 2]).write(to: url)
        XCTAssertThrowsError(try SonioxMeetingTranscriber.writeUpload(chunkURLs: [url], to: directory.appendingPathComponent("upload"), boundary: "test"))
    }

    func testUploadPollCheckpointCleanupAndReuseWithoutNetwork() async throws {
        let url = try chunk()
        let fileID = fileID, jobID = jobID
        var polls = 0
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            let body: [String: Any]
            if path == "/v1/files" { body = ["id": fileID] }
            else if path == "/v1/transcriptions" { body = ["id": jobID] }
            else if path.hasSuffix("/transcript") { body = ["text": "Recovered meeting transcript", "tokens": [["text": "Recovered meeting transcript", "speaker": "1", "start_ms": 100, "end_ms": 500]]] }
            else { polls += 1; body = ["status": polls == 1 ? "processing" : "completed"] }
            return (200, [:], try JSONSerialization.data(withJSONObject: body))
        }
        let client = SonioxMeetingTranscriber(apiKey: "test-key", session: session, pollInterval: .zero)
        let result = try await client.transcribe(chunkURLs: [url], language: "ru", terms: ["Whytap"])
        XCTAssertEqual(result.text, "Recovered meeting transcript")
        XCTAssertEqual(result.segments, [TranscriptSegment(speaker: "Speaker 1", start: 0.1, end: 0.5, text: result.text)])
        let createIndex = try XCTUnwrap(StubURLProtocol.capturedRequests.firstIndex { $0.url?.path == "/v1/transcriptions" })
        let createBody = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies[createIndex]) as? [String: Any])
        XCTAssertEqual(createBody["enable_speaker_diarization"] as? Bool, true)
        XCTAssertEqual(StubURLProtocol.capturedRequests.filter { $0.httpMethod == "POST" }.count, 2)
        XCTAssertEqual(StubURLProtocol.capturedRequests.filter { $0.httpMethod == "DELETE" }.count, 2)
        let count = StubURLProtocol.capturedRequests.count
        let resumed = try await client.transcribe(chunkURLs: [url], language: "ru", terms: [])
        XCTAssertEqual(resumed, result)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testResumeExistingJobWithoutUploadingAndKeepCheckpointOnNetworkFailure() async throws {
        let url = try chunk()
        try save(.init(fileID: fileID, transcriptionID: jobID, diarizationEnabled: true))
        StubURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        let client = SonioxMeetingTranscriber(apiKey: "test-key", session: session, pollInterval: .zero)
        do {
            _ = try await client.transcribe(chunkURLs: [url], language: nil, terms: [])
            XCTFail("Expected network failure")
        } catch {}
        XCTAssertEqual(StubURLProtocol.capturedRequests.map(\.httpMethod), ["GET"])
        let saved = try JSONDecoder().decode(SonioxMeetingTranscriber.Checkpoint.self,
            from: Data(contentsOf: directory.appendingPathComponent("soniox-transcription.json")))
        XCTAssertEqual(saved.transcriptionID, jobID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTimeoutKeepsJobForLaterRetry() async throws {
        let url = try chunk()
        try save(.init(fileID: fileID, transcriptionID: jobID, diarizationEnabled: true))
        let client = SonioxMeetingTranscriber(apiKey: "test-key", session: session, timeout: 0)
        do {
            _ = try await client.transcribe(chunkURLs: [url], language: nil, terms: [])
            XCTFail("Expected timeout")
        } catch let error as MeetingBYOKProcessingError {
            XCTAssertTrue(error.description.contains("timed out"))
        }
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    func testProviderErrorCleansResourcesButPreservesAudio() async throws {
        let url = try chunk()
        try save(.init(fileID: fileID, transcriptionID: jobID, diarizationEnabled: true))
        StubURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { return (404, [:], Data()) }
            return (200, [:], Data("{\"status\":\"error\"}".utf8))
        }
        do {
            _ = try await SonioxMeetingTranscriber(apiKey: "test-key", session: session)
                .transcribe(chunkURLs: [url], language: nil, terms: [])
            XCTFail("Expected provider error")
        } catch {}
        let saved = try JSONDecoder().decode(SonioxMeetingTranscriber.Checkpoint.self,
            from: Data(contentsOf: directory.appendingPathComponent("soniox-transcription.json")))
        XCTAssertNil(saved.transcriptionID)
        XCTAssertNil(saved.fileID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testTokensPreserveSpeakerChangesSubwordsAndMillisecondTimestamps() throws {
        let payload = #"{"text":"Hello! Hi. Again","tokens":[{"text":"Hel","speaker":"1","start_ms":100,"end_ms":250},{"text":"lo","speaker":"1","start_ms":250,"end_ms":400},{"text":"!","start_ms":400,"end_ms":410},{"text":" Hi.","speaker":"2","start_ms":350,"end_ms":800},{"text":" Again","speaker":"1","start_ms":1000,"end_ms":1600},{"text":"<end>"}]}"#
        let result = try SonioxMeetingTranscriber.decodeTranscript(Data(payload.utf8))
        XCTAssertEqual(result.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(result.segments.map(\.text), ["Hello!", "Hi.", "Again"])
        XCTAssertEqual(result.segments.map(\.start), [0.1, 0.35, 1])
        XCTAssertEqual(result.segments.map(\.end), [0.41, 0.8, 1.6])
        let rendered = TranscriptMarkdownFormatter.format(result.segments)
        XCTAssertTrue(rendered.contains("**Speaker 2 [00:00-00:00]:** Hi."))
    }

    func testUnlabelledSpeechStaysUnknownAndLongPausesSplitTurns() throws {
        let payload = #"{"text":"One unknown two three","tokens":[{"text":"One","speaker":"1","start_ms":0,"end_ms":200},{"text":" unknown","start_ms":300,"end_ms":500},{"text":" two","speaker":"1","start_ms":600,"end_ms":800},{"text":" three","speaker":"1","start_ms":4000,"end_ms":5000}]}"#
        let result = try SonioxMeetingTranscriber.decodeTranscript(Data(payload.utf8))
        XCTAssertEqual(result.segments.map(\.speaker), ["Speaker 1", nil, "Speaker 1", "Speaker 1"])
        XCTAssertEqual(result.segments.map(\.text), ["One", "unknown", "two", "three"])
    }

    func testRejectsMissingAttributionAndInvalidTimes() {
        for payload in [
            #"{"text":"Hello","tokens":[{"text":"Hello","start_ms":0,"end_ms":500}]}"#,
            #"{"text":"Hello","tokens":[{"text":"Hello","speaker":"1","start_ms":500,"end_ms":100}]}"#
        ] {
            XCTAssertThrowsError(try SonioxMeetingTranscriber.decodeTranscript(Data(payload.utf8)))
        }
    }

    func testLegacyTextCheckpointIsNotReusedAsDiarization() async throws {
        let url = try chunk()
        try save(.init(transcript: "Old unlabelled text"))
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/files")
            throw URLError(.networkConnectionLost)
        }
        do {
            _ = try await SonioxMeetingTranscriber(apiKey: "test-key", session: session)
                .transcribe(chunkURLs: [url], language: nil, terms: [])
            XCTFail("Must request fresh diarization")
        } catch {}
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
    }

    func testDiarizedSegmentsSurviveStoreRoundTrip() async throws {
        let store = try MeetingsStore(rootDirectory: directory.appendingPathComponent("store"))
        let segments = [TranscriptSegment(speaker: "Speaker 2", start: 12.5, end: 15.25, text: "Hello")]
        let id = UUID()
        try await store.updateTranscript(id: id, transcript: segments)
        let restored = try await store.transcript(id: id)
        XCTAssertEqual(restored, segments)
        await store.close()
    }

}
