import Foundation

/// Finished recordings use Soniox's file API. A durable checkpoint survives
/// network failures and note-generation retries without uploading audio again.
actor SonioxMeetingTranscriber {
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
    }

    private let apiKey: String
    private let session: URLSession
    private let pollInterval: Duration
    private let timeout: TimeInterval
    private let baseURL = URL(string: "https://api.soniox.com/v1/")!

    init(apiKey: String, session: URLSession = .shared,
         pollInterval: Duration = .seconds(3), timeout: TimeInterval = 1800) {
        self.apiKey = apiKey
        self.session = session
        self.pollInterval = pollInterval
        self.timeout = timeout
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
        if let transcript = checkpoint.transcript, let segments = checkpoint.segments,
           !segments.isEmpty {
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
            var body: [String: Any] = [
                "model": "stt-async-v5", "file_id": checkpoint.fileID!,
                "enable_language_identification": true,
                "enable_speaker_diarization": true,
                "client_reference_id": directory.lastPathComponent,
            ]
            if let language, !language.isEmpty { body["language_hints"] = [language] }
            if !terms.isEmpty { body["context"] = ["terms": terms] }
            let data = try await send(path: "transcriptions", method: "POST",
                                      body: JSONSerialization.data(withJSONObject: body))
            checkpoint.transcriptionID = try Self.identifier(in: data)
            try save(checkpoint, to: checkpointURL)
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
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
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
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = object?["id"] as? String, UUID(uuidString: id) != nil else {
            throw MeetingBYOKProcessingError.upstreamError("Invalid Soniox resource identifier.")
        }
        return id
    }

    /// Recorder chunks are canonical 16 kHz mono PCM16 WAVs. Validate every
    /// header and stream their bodies to disk; never concatenate WAV headers
    /// or hold an hour of audio in RAM. Reject incompatible/corrupt recordings.
    static func writeUpload(chunkURLs: [URL], to url: URL, boundary: String) throws {
        var total: UInt64 = 0
        for chunk in chunkURLs {
            try Task.checkCancellation()
            total += UInt64(try pcmBody(chunk).count)
        }
        guard total > 0, total <= UInt32.max - 36 else { throw MeetingBYOKProcessingError.noAudio }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"meeting.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        var header = Data("RIFF".utf8)
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        append(UInt32(total) + 36)
        header.append(Data("WAVEfmt ".utf8)); append(16)
        header.append(contentsOf: [1, 0, 1, 0]); append(16000); append(32000)
        header.append(contentsOf: [2, 0, 16, 0]); header.append(Data("data".utf8)); append(UInt32(total))
        try handle.write(contentsOf: header)
        for chunk in chunkURLs {
            try Task.checkCancellation()
            try handle.write(contentsOf: pcmBody(chunk))
        }
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    private static func pcmBody(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        func uint(_ offset: Int, _ length: Int) -> UInt32 {
            (0..<length).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count >= 44,
              data.prefix(4) == Data("RIFF".utf8), data[8..<16] == Data("WAVEfmt ".utf8),
              uint(16, 4) == 16, uint(20, 2) == 1, uint(22, 2) == 1,
              uint(24, 4) == 16000, uint(28, 4) == 32000,
              uint(32, 2) == 2, uint(34, 2) == 16,
              data[36..<40] == Data("data".utf8),
              UInt64(uint(40, 4)) == data.count - 44, (data.count - 44).isMultiple(of: 2) else {
            throw MeetingBYOKProcessingError.upstreamError("Unsupported or incomplete meeting WAV chunk.")
        }
        return Data(data.dropFirst(44))
    }
}
