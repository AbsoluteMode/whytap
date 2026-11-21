import Foundation

/// Finished recordings use Soniox's file API. A durable checkpoint survives
/// network failures and note-generation retries without uploading audio again.
actor SonioxMeetingTranscriber: MeetingRecordedTranscribing {
    /// Empty `segments` means the completed job recognised no speech.
    struct Result: Codable, Sendable, Equatable {
        let text: String
        let segments: [TranscriptSegment]
    }

    struct Checkpoint: Codable {
        var fileID: String?
        var transcriptionID: String?
        var transcript: String?
        var segments: [TranscriptSegment]?
        var diarizationEnabled: Bool?
        var usageModel: String?
        var usageStartedAt: Date?
        var usageSeconds: Double?
        var usageReference: String?
    }

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let pollInterval: Duration
    private let timeout: TimeInterval
    private let audioSeconds: Double?
    private let usageSink: (AIUsageEvent) -> Void

    init(apiKey: String, model: String, session: URLSession = .shared,
         pollInterval: Duration = .seconds(3), timeout: TimeInterval = 1800,
         audioSeconds: Double? = nil, usageSink: @escaping (AIUsageEvent) -> Void = AIUsageRecorder.record) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.audioSeconds = audioSeconds; self.usageSink = usageSink
    }

    func transcribe(chunkURLs: [URL], language: String?, terms: [String]) async throws -> Result {
        try Task.checkCancellation()
        guard let first = chunkURLs.first else { throw MeetingBYOKProcessingError.noAudio }
        let directory = first.deletingLastPathComponent()
        let checkpointURL = directory.appendingPathComponent("soniox-transcription.json")
        var checkpoint: Checkpoint
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
        } else {
            checkpoint = Checkpoint(diarizationEnabled: true)
        }
        // Old jobs were created without diarization. Never silently reuse their
        // text-only result when the caller expects speaker-attributed segments.
        if checkpoint.diarizationEnabled != true {
            await cleanup(&checkpoint, at: checkpointURL)
            guard checkpoint.transcriptionID == nil, checkpoint.fileID == nil else {
                throw MeetingBYOKProcessingError.upstreamError("Previous Soniox job is still active; retry after it completes.")
            }
            checkpoint = Checkpoint(diarizationEnabled: true)
            try save(checkpoint, to: checkpointURL)
        }
        // An empty transcript without segments is a stored no-speech result.
        if let transcript = checkpoint.transcript, let segments = checkpoint.segments,
           !segments.isEmpty || transcript.isEmpty {
            await cleanup(&checkpoint, at: checkpointURL)
            return Result(text: transcript, segments: segments)
        }

        if checkpoint.fileID == nil {
            let boundary = UUID().uuidString
            let uploadURL = directory.appendingPathComponent("soniox-upload-\(boundary).tmp")
            defer { try? FileManager.default.removeItem(at: uploadURL) }
            try Self.writeUpload(chunkURLs: chunkURLs, to: uploadURL, boundary: boundary)
            var request = request(path: "files", method: "POST")
            request.timeoutInterval = 600
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.upload(for: request, fromFile: uploadURL)
            try Self.validate(response)
            checkpoint.fileID = try Self.identifier(in: data)
            try save(checkpoint, to: checkpointURL)
        }
        if checkpoint.transcriptionID == nil {
            let reference = UUID().uuidString
            var body: [String: Any] = [
                "model": model, "file_id": checkpoint.fileID!,
                "enable_language_identification": true,
                "enable_speaker_diarization": true,
                "client_reference_id": reference,
            ]
            if let language, !language.isEmpty { body["language_hints"] = [language] }
            if !terms.isEmpty { body["context"] = ["terms": terms] }
            let data = try await send(path: "transcriptions", method: "POST",
                                      body: JSONSerialization.data(withJSONObject: body))
            checkpoint.transcriptionID = try Self.identifier(in: data)
            checkpoint.usageModel = model
            checkpoint.usageStartedAt = Date()
            checkpoint.usageSeconds = audioSeconds
            checkpoint.usageReference = reference
            try save(checkpoint, to: checkpointURL)
        }
        if let id = checkpoint.transcriptionID, let model = checkpoint.usageModel,
           let date = checkpoint.usageStartedAt, let seconds = checkpoint.usageSeconds {
            usageSink(.speech(.init(feature: .meetings, account: .soniox, model: model),
                              seconds: seconds, id: checkpoint.usageReference.map { "soniox:\($0)" } ?? "soniox-job:\(id)", at: date))
        }
        let jobPath = "transcriptions/\(checkpoint.transcriptionID!)"
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw MeetingBYOKProcessingError.upstreamError("Soniox file processing timed out; the job is saved for retry.")
            }
            let data = try await send(path: jobPath)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch object?["status"] as? String {
            case "completed":
                let result = try await send(path: jobPath + "/transcript")
                let decoded = try Self.decodeTranscript(result)
                checkpoint.transcript = decoded.text
                checkpoint.segments = decoded.segments
                // Persist attribution BEFORE deleting remote resources or generating notes.
                try save(checkpoint, to: checkpointURL)
                await cleanup(&checkpoint, at: checkpointURL)
                return decoded
            case "error":
                await cleanup(&checkpoint, at: checkpointURL)
                throw MeetingBYOKProcessingError.upstreamError("Soniox could not process the audio file. The recording is saved for retry.")
            case "queued", "processing":
                try await Task.sleep(for: pollInterval)
            default:
                throw MeetingBYOKProcessingError.upstreamError("Invalid Soniox job status.")
            }
        }
    }

    /// Soniox token text already contains spaces and subword boundaries.
    /// Group adjacent tokens, never all tokens with the same speaker globally.
    static func decodeTranscript(_ data: Data) throws -> Result {
        struct Response: Decodable {
            struct Token: Decodable {
                let text: String
                let speaker: String?
                let start_ms: Double?
                let end_ms: Double?
            }
            let text: String
            let tokens: [Token]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var segments: [TranscriptSegment] = []
        var speaker: String?
        var start = 0.0
        var end = 0.0
        var text = ""
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(TranscriptSegment(speaker: speaker, start: start, end: end, text: trimmed))
            }
            text = ""
        }
        for token in response.tokens {
            guard !token.text.isEmpty, !["<end>", "<fin>"].contains(token.text) else { continue }
            let tokenStart = token.start_ms.map { $0 / 1000 } ?? end
            let tokenEnd = token.end_ms.map { $0 / 1000 } ?? tokenStart
            guard tokenStart.isFinite, tokenEnd.isFinite, tokenStart >= 0, tokenEnd >= tokenStart else {
                throw MeetingBYOKProcessingError.upstreamError("Invalid Soniox token timestamp.")
            }
            let label = token.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            var tokenSpeaker = label.flatMap { $0.isEmpty ? nil : "Speaker " + $0 }
            // Unlabelled punctuation belongs to the preceding words; unlabelled
            // speech remains Unknown rather than guessing who said it.
            if tokenSpeaker == nil, token.text.unicodeScalars.allSatisfy({
                CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0)
            }) { tokenSpeaker = speaker }
            if !text.isEmpty && (tokenSpeaker != speaker || tokenStart - end > 2 || text.count >= 1000) {
                flush()
            }
            if text.isEmpty { start = tokenStart; end = tokenEnd; speaker = tokenSpeaker }
            text += token.text
            end = max(end, tokenEnd)
        }
        flush()
        // WHY: .project-docs/decisions/2026-10-18-silent-meetings.md
        // Silence is a final result: the same audio returns the same empty
        // transcript on every retry. Speech without speakers stays an error.
        if segments.isEmpty, response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(text: "", segments: [])
        }
        guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              segments.contains(where: { $0.speaker != nil }) else {
            throw MeetingBYOKProcessingError.upstreamError("Soniox returned no speaker-attributed transcript. The audio is saved for retry.")
        }
        return Result(text: response.text, segments: segments)
    }

    private func cleanup(_ checkpoint: inout Checkpoint, at url: URL) async {
        if let id = checkpoint.transcriptionID,
           (try? await send(path: "transcriptions/\(id)", method: "DELETE")) != nil {
            checkpoint.transcriptionID = nil
        }
        if checkpoint.transcriptionID == nil, let id = checkpoint.fileID,
           (try? await send(path: "files/\(id)", method: "DELETE")) != nil {
            checkpoint.fileID = nil
        }
        try? save(checkpoint, to: url)
    }

    private func save(_ checkpoint: Checkpoint, to url: URL) throws {
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func request(path: String, method: String) -> URLRequest {
        SonioxFileAPI.request(path: path, method: method, apiKey: apiKey)
    }

    private func send(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = request(path: path, method: method)
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        // DELETE is idempotent, including a resource already removed by a prior attempt.
        if method == "DELETE", (response as? HTTPURLResponse)?.statusCode == 404 { return Data() }
        try Self.validate(response)
        return data
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MeetingBYOKProcessingError.upstreamError("Soniox file API HTTP \(code). The recording is saved for retry.")
        }
    }

    private static func identifier(in data: Data) throws -> String {
        guard let id = try SonioxFileAPI.resourceID(in: data) else {
            throw MeetingBYOKProcessingError.upstreamError("Invalid Soniox resource identifier.")
        }
        return id
    }

    /// Recorder chunks are canonical 16 kHz mono PCM16 WAVs, sent as one
    /// multipart `file` part (`MeetingAudioUpload`).
    static func writeUpload(chunkURLs: [URL], to url: URL, boundary: String) throws {
        try MeetingAudioUpload.write(
            chunkURLs: chunkURLs, to: url,
            prefix: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"meeting.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8),
            suffix: Data("\r\n--\(boundary)--\r\n".utf8)
        )
    }
}
