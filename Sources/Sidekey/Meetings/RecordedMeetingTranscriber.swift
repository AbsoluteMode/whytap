import Foundation
import OSLog

/// Where a finished meeting goes when the Meetings route is on ElevenLabs or
/// Deepgram: the provider's pre-recorded API with the route's key. Soniox has
/// its own file-API transcriber; a user's server keeps its real-time adapter.
// WHY: .project-docs/decisions/2026-11-21-recorded-meeting-models.md
enum RecordedMeetingRoute: Equatable, Sendable {
    case elevenLabs(apiKey: String, model: String)
    case deepgram(apiKey: String, model: String)

    /// nil for a provider without a pre-recorded meeting path here. Throws
    /// when the route's own key is missing; never borrows another one.
    static func make(for route: ResolvedRoute) throws -> RecordedMeetingRoute? {
        let key = route.apiKey.flatMap { $0.isEmpty ? nil : $0 }
        switch route.account {
        case .elevenLabs:
            guard let key else { throw MeetingBYOKProcessingError.missingTranscriptionKey }
            return .elevenLabs(apiKey: key, model: ModelRegistry.elevenLabsRecordedModel(for: route.model))
        case .deepgram:
            guard let key else { throw MeetingBYOKProcessingError.missingTranscriptionKey }
            return .deepgram(apiKey: key, model: route.model)
        case .soniox, .server, .thisMac, .openRouter, .openAI, .anthropic:
            return nil
        }
    }

    var account: ProviderAccount {
        switch self {
        case .elevenLabs: return .elevenLabs
        case .deepgram: return .deepgram
        }
    }

    var model: String {
        switch self {
        case .elevenLabs(_, let model), .deepgram(_, let model): return model
        }
    }

    fileprivate var providerName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .deepgram: return "Deepgram"
        }
    }
}

protocol MeetingRecordedTranscribing {
    /// Empty `segments` and empty `text` mean the provider heard no speech.
    func transcribe(chunkURLs: [URL], language: String?, terms: [String]) async throws -> SonioxMeetingTranscriber.Result
}

/// A finished meeting through ElevenLabs speech-to-text or Deepgram
/// pre-recorded, with speaker labels (`diarize`), like Soniox's file API.
/// One synchronous request: the whole recording is streamed from a temporary
/// file in the staging directory. There is no remote job to resume, so no
/// checkpoint: the processor keeps the transcript before the notes model is
/// asked. The request makes the realtime request's choices (language,
/// vocabulary terms, ElevenLabs' no_verbatim). Failures use fixed copy and
/// never quote the provider's body.
// WHY: .project-docs/decisions/2026-11-21-recorded-meeting-models.md
struct RecordedMeetingTranscriber: MeetingRecordedTranscribing {
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "recorded-transcriber")
    /// Covers the upload and the provider's processing of a long recording.
    static let requestTimeout: TimeInterval = 1800

    private let route: RecordedMeetingRoute
    private let session: URLSession
    private let usageSink: (AIUsageEvent) -> Void

    init(route: RecordedMeetingRoute, session: URLSession = .shared,
         usageSink: @escaping (AIUsageEvent) -> Void = AIUsageRecorder.record) {
        self.route = route
        self.session = session
        self.usageSink = usageSink
    }

    func transcribe(chunkURLs: [URL], language: String?, terms: [String]) async throws -> SonioxMeetingTranscriber.Result {
        try Task.checkCancellation()
        guard let first = chunkURLs.first else { throw MeetingBYOKProcessingError.noAudio }
        let language = language.flatMap { $0.isEmpty ? nil : $0 }
        let uploadURL = first.deletingLastPathComponent()
            .appendingPathComponent("recorded-upload-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: uploadURL) }

        var request: URLRequest
        let pcmBytes: UInt64
        switch route {
        case .elevenLabs(let apiKey, let model):
            let boundary = "whytap-\(UUID().uuidString)"
            var fields: [(String, String)] = [
                ("model_id", model), ("diarize", "true"), ("timestamps_granularity", "word"),
                ("tag_audio_events", "false"), ("no_verbatim", "true"),
            ]
            if let language { fields.append(("language_code", language)) }
            for term in terms { fields.append(("keyterms", term)) }
            var prefix = Data()
            for (name, value) in fields {
                prefix.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            prefix.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"meeting.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            pcmBytes = try MeetingAudioUpload.write(
                chunkURLs: chunkURLs, to: uploadURL, prefix: prefix, suffix: Data("\r\n--\(boundary)--\r\n".utf8)
            )
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        case .deepgram(let apiKey, let model):
            request = URLRequest(url: try Self.deepgramURL(model: model, language: language, terms: terms))
            pcmBytes = try MeetingAudioUpload.write(chunkURLs: chunkURLs, to: uploadURL)
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout

        let startedAt = Date()
        let started = ContinuousClock.now
        let (data, response) = try await session.upload(for: request, fromFile: uploadURL)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let refusal: ElevenLabsRefusal? = if case .elevenLabs = route { ElevenLabsRefusal(body: data) } else { nil }
            os_log("recorded meeting transcription failed provider=%{public}@ status=%{public}d",
                   log: Self.log, type: .error, route.providerName, status)
            throw Self.failure(provider: route.providerName, status: status, refusal: refusal)
        }

        let result: SonioxMeetingTranscriber.Result
        let usageID: String
        switch route {
        case .elevenLabs:
            result = try Self.decodeElevenLabs(data)
            usageID = http?.value(forHTTPHeaderField: "request-id")
                .flatMap { !$0.isEmpty && $0.count <= 256 ? "elevenlabs:\($0)" : nil } ?? UUID().uuidString
        case .deepgram:
            result = try Self.decodeDeepgram(data)
            usageID = UUID().uuidString
        }
        usageSink(.speech(.init(feature: .meetings, account: route.account, model: route.model),
                          seconds: Double(pcmBytes) / Double(MeetingAudioUpload.bytesPerSecond),
                          id: usageID, at: startedAt))
        let elapsed = started.duration(to: .now).components
        os_log("recorded meeting transcription provider=%{public}@ audio_bytes=%{public}llu ms=%{public}lld segments=%{public}d",
               log: Self.log, type: .info, route.providerName, pcmBytes,
               elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000, result.segments.count)
        return result
    }

    /// Deepgram pre-recorded `/v1/listen` with the realtime query's language
    /// and key terms, plus speaker labels and utterances.
    static func deepgramURL(model: String, language: String?, terms: [String]) throws -> URL {
        let language = try DeepgramLanguagePolicy.queryLanguage(model: model, language: language)
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var items = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "language", value: language),
        ]
        for term in terms { items.append(URLQueryItem(name: "keyterm", value: term)) }
        components.queryItems = items
        return components.url!
    }

    // MARK: Decoding

    /// ElevenLabs words carry `speaker_id` (`speaker_0`…); spacing tokens join
    /// them and audio events are dropped. Words without timing keep the
    /// previous end. A transcript without words is kept unlabelled.
    static func decodeElevenLabs(_ data: Data) throws -> SonioxMeetingTranscriber.Result {
        struct Response: Decodable {
            struct Word: Decodable {
                let text: String
                let type: String?
                let start: Double?
                let end: Double?
                let speaker_id: String?
            }
            let text: String
            let words: [Word]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw MeetingBYOKProcessingError.upstreamError("ElevenLabs returned an unreadable transcript. The recording is saved for retry.")
        }
        var builder = SpeakerSegmentBuilder()
        for word in response.words ?? [] {
            switch word.type {
            case "audio_event": continue
            case "spacing": builder.appendSpacing(word.text)
            default: builder.append(word.text, speaker: speakerLabel(word.speaker_id), start: word.start, end: word.end)
            }
        }
        return result(text: response.text, segments: builder.finish())
    }

    /// Deepgram utterances carry an integer speaker; consecutive utterances of
    /// one speaker are joined under the same rule as ElevenLabs words.
    static func decodeDeepgram(_ data: Data) throws -> SonioxMeetingTranscriber.Result {
        struct Response: Decodable {
            struct Results: Decodable {
                let channels: [Channel]
                let utterances: [Utterance]?
            }
            struct Channel: Decodable { let alternatives: [Alternative] }
            struct Alternative: Decodable { let transcript: String }
            struct Utterance: Decodable {
                let start: Double?
                let end: Double?
                let transcript: String
                let speaker: Int?
            }
            let results: Results
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let best = response.results.channels.first?.alternatives.first else {
            throw MeetingBYOKProcessingError.upstreamError("Deepgram returned an unreadable transcript. The recording is saved for retry.")
        }
        var builder = SpeakerSegmentBuilder()
        for utterance in response.results.utterances ?? [] {
            builder.append(utterance.transcript, speaker: utterance.speaker.map { "Speaker \($0 + 1)" },
                           start: utterance.start, end: utterance.end, joiner: " ")
        }
        return result(text: best.transcript, segments: builder.finish())
    }

    /// Silence is a final result (`.project-docs/decisions/2026-10-18-silent-meetings.md`).
    /// Speech that came back without segments is kept as one unlabelled segment.
    private static func result(text: String, segments: [TranscriptSegment]) -> SonioxMeetingTranscriber.Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segments.isEmpty {
            if trimmed.isEmpty { return .init(text: "", segments: []) }
            return .init(text: trimmed, segments: [TranscriptSegment(speaker: nil, start: 0, end: 0, text: trimmed)])
        }
        let joined = segments.map(\.text).joined(separator: " ")
        return .init(text: trimmed.isEmpty ? joined : trimmed, segments: segments)
    }

    /// `speaker_0` → `Speaker 1`, the numbering Soniox meetings show.
    static func speakerLabel(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        if id.hasPrefix("speaker_"), let index = Int(id.dropFirst("speaker_".count)), index >= 0 {
            return "Speaker \(index + 1)"
        }
        return "Speaker \(id)"
    }

    /// Fixed copy by status; the provider's own text is never shown.
    static func failure(provider: String, status: Int, refusal: ElevenLabsRefusal?) -> MeetingBYOKProcessingError {
        let saved = "The recording is saved for retry."
        let reason: String
        switch (refusal, status) {
        case (.missingPermissions?, _):
            reason = "This \(provider) key has no Speech to Text access. Check it in Settings > API & Models."
        case (.quotaExceeded?, _), (_, 402):
            reason = "\(provider) is out of credit."
        case (.invalidKey?, _), (_, 401), (_, 403):
            reason = "\(provider) refused the key. Check it in Settings > API & Models."
        case (_, 429):
            reason = "\(provider) is busy or its limit was reached."
        case (_, let code) where code >= 500:
            reason = "\(provider) is not responding (\(code))."
        default:
            reason = "\(provider) refused the recording (HTTP \(status))."
        }
        return .upstreamError("\(reason) \(saved)")
    }
}

/// Groups adjacent speech of one speaker into transcript segments: a new
/// segment on a speaker change, a pause over 2 s or 1,000 characters (the
/// Soniox meeting rule). Never groups all speech of a speaker globally.
struct SpeakerSegmentBuilder {
    private var segments: [TranscriptSegment] = []
    private var speaker: String?
    private var start = 0.0
    private var end = 0.0
    private var text = ""

    mutating func appendSpacing(_ spacing: String) {
        if !text.isEmpty { text += spacing }
    }

    mutating func append(_ piece: String, speaker pieceSpeaker: String?, start pieceStart: Double?,
                         end pieceEnd: Double?, joiner: String = "") {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let valid = { (value: Double?) in value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let from = valid(pieceStart) ?? end
        let to = max(from, valid(pieceEnd) ?? from)
        if !text.isEmpty && (pieceSpeaker != speaker || from - end > 2 || text.count >= 1000) {
            flush()
        }
        if text.isEmpty {
            start = from; end = to; speaker = pieceSpeaker
            text = joiner.isEmpty ? piece : trimmed
        } else {
            text += joiner + (joiner.isEmpty ? piece : trimmed)
        }
        end = max(end, to)
    }

    mutating func finish() -> [TranscriptSegment] {
        flush()
        return segments
    }

    private mutating func flush() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append(TranscriptSegment(speaker: speaker, start: start, end: end, text: trimmed))
        }
        text = ""
    }
}
