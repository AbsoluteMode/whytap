import Foundation

/// Finished recordings use Soniox's file API. A durable checkpoint survives
/// network failures and note-generation retries without uploading audio again.
actor SonioxMeetingTranscriber {
    struct Checkpoint: Codable {
        var fileID: String?
        var transcriptionID: String?
        var transcript: String?
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

    func transcribe(chunkURLs: [URL], language: String?, terms: [String]) async throws -> String {
        guard let first = chunkURLs.first else { throw MeetingBYOKProcessingError.noAudio }
        let directory = first.deletingLastPathComponent()
        let checkpointURL = directory.appendingPathComponent("soniox-transcription.json")
        var checkpoint: Checkpoint
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
        } else {
            checkpoint = Checkpoint()
        }
        if let transcript = checkpoint.transcript {
            await cleanup(&checkpoint, at: checkpointURL)
            return transcript
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
                let transcriptObject = try JSONSerialization.jsonObject(with: result) as? [String: Any]
                guard let text = transcriptObject?["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MeetingBYOKProcessingError.noTranscript
                }
                checkpoint.transcript = text
                // Persist text BEFORE deleting remote resources or generating notes.
                try save(checkpoint, to: checkpointURL)
                await cleanup(&checkpoint, at: checkpointURL)
                return text
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
