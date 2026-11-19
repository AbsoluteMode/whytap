import Foundation
import OSLog

/// Where a batch take goes: the provider, model and key of the route of the
/// feature the take belongs to (API & Models), or nowhere.
/// WHY: .project-docs/decisions/2026-10-18-provider-batch-transcription.md
enum ProviderBatchRoute: Equatable, Sendable {
    case soniox(apiKey: String, model: String)
    case deepgram(apiKey: String, model: String)
    case elevenLabs(apiKey: String, model: String)
    /// A server's key is optional: without one no `Authorization` is sent.
    case selfHosted(apiKey: String?, endpoint: URL, model: String)
    /// The model on this Mac: no request leaves it.
    case onDevice(model: String)

    /// The batch counterpart of a resolved route; nil when the route's provider
    /// has no batch transcription (OpenRouter, Anthropic), the key a hosted provider needs
    /// is missing, or the server has no usable base URL. Never another
    /// provider: the take goes where the feature's real-time stream would have
    /// gone, or nowhere.
    ///
    /// Soniox and ElevenLabs real-time routes name a streaming model that their
    /// file APIs do not accept, so recorded audio uses the registry model of the
    /// same provider. Deepgram and a server use the model of the route.
    static func make(for route: ResolvedRoute) -> ProviderBatchRoute? {
        let key = route.apiKey.flatMap { $0.isEmpty ? nil : $0 }
        switch route.account {
        case .soniox:
            guard let key else { return nil }
            return .soniox(apiKey: key, model: ModelRegistry.sonioxRecordedModel)
        case .deepgram:
            guard let key else { return nil }
            return .deepgram(apiKey: key, model: route.model)
        case .elevenLabs:
            guard let key else { return nil }
            return .elevenLabs(apiKey: key, model: ModelRegistry.elevenLabsRecordedModel)
        case .server:
            guard let server = route.server, let endpoint = selfHostedEndpoint(baseURL: server.baseURL) else { return nil }
            return .selfHosted(apiKey: key, endpoint: endpoint, model: route.model)
        case .thisMac:
            return .onDevice(model: route.model)
        case .openRouter, .openAI, .anthropic:
            return nil
        }
    }

    /// `/v1/audio/transcriptions` on the realtime base URL's host, over TLS
    /// whatever the scheme (the realtime socket is always `wss`). A base URL
    /// without a host is nil, never a fallback host.
    static func selfHostedEndpoint(baseURL: String?) -> URL? {
        guard let baseURL, var components = URLComponents(string: baseURL),
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = "https"
        components.path = "/v1/audio/transcriptions"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// For the log only.
    fileprivate var providerName: String {
        switch self {
        case .soniox: return BYOKProvider.soniox.rawValue
        case .deepgram: return BYOKProvider.deepgram.rawValue
        case .elevenLabs: return BYOKProvider.elevenLabs.rawValue
        case .selfHosted: return BYOKProvider.selfHosted.rawValue
        case .onDevice: return "on_device"
        }
    }
}

enum ProviderBatchTranscriptionError: Error, Equatable {
    /// The provider answered with a non-2xx status.
    case httpStatus(Int)
    /// A 2xx answer without the expected fields.
    case malformedResponse
    /// Soniox reported the job as failed.
    case jobFailed
    /// The Soniox job did not finish within `jobTimeout`.
    case timedOut
}

/// Whole-take transcription with the user's own provider key, for the
/// resilient-delivery batch rung, Retry on "Couldn't deliver", the Drop
/// recorder fallback and agent batch voice. Each request makes the same
/// choices as that provider's realtime request (language, Soniox's `en`
/// hint, ElevenLabs' no_verbatim). An empty transcript is silence, not a
/// failure. Every wait is cancellable, so the recovery deadline ends any
/// request or poll. The route is read on every call: a provider chosen
/// later applies without a relaunch.
/// WHY: .project-docs/decisions/2026-10-18-provider-batch-transcription.md
struct ProviderBatchTranscriber: BatchTranscribing {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "byok-batch")

    private struct Selection { let route: ProviderBatchRoute; let usage: AIUsageContext? }
    private let route: @MainActor @Sendable () -> Selection?
    private let session: URLSession
    private let pollInterval: Duration
    private let jobTimeout: Duration
    private let usageSink: (AIUsageEvent) -> Void
    private let onDevice: any BatchTranscribing

    /// `jobTimeout` bounds Soniox polling on the paths without the recovery
    /// deadline (recorder fallback, agent voice) and the retried deletion of
    /// a job that is still processing.
    init(
        route: @escaping @MainActor @Sendable () -> ProviderBatchRoute?,
        session: URLSession = .shared,
        pollInterval: Duration = .milliseconds(500),
        jobTimeout: Duration = .seconds(30),
        usageSink: @escaping (AIUsageEvent) -> Void = AIUsageRecorder.record,
        onDevice: any BatchTranscribing = OnDeviceBatchTranscriber()
    ) {
        self.route = { route().map { Selection(route: $0, usage: nil) } }
        self.session = session
        self.pollInterval = pollInterval
        self.jobTimeout = jobTimeout
        self.usageSink = usageSink
        self.onDevice = onDevice
    }

    private init(resolvedRoute: @escaping @MainActor @Sendable () -> ResolvedRoute?, session: URLSession,
                 pollInterval: Duration, onDevice: any BatchTranscribing) {
        self.route = {
            guard let resolved = resolvedRoute(), let route = ProviderBatchRoute.make(for: resolved) else { return nil }
            let model: String
            switch route {
            case .soniox(_, let value), .deepgram(_, let value), .elevenLabs(_, let value), .selfHosted(_, _, let value): model = value
            // Nothing is billed and no provider is called: Costs has no row.
            case .onDevice: return Selection(route: route, usage: nil)
            }
            return Selection(route: route, usage: .init(feature: resolved.feature, account: resolved.account, model: model))
        }
        self.session = session; self.pollInterval = pollInterval; self.jobTimeout = .seconds(30)
        self.usageSink = AIUsageRecorder.record
        self.onDevice = onDevice
    }

    func isAvailable() async -> Bool {
        await route() != nil
    }

    func transcribe(audio: Data, language: String?) async throws -> String {
        guard let selection = await route() else { throw BatchTranscriptionUnavailable() }
        let route = selection.route
        let wav = Self.wavFile(audio)
        let language = language.flatMap { $0.isEmpty ? nil : $0 }
        let started = ContinuousClock.now
        let usageStartedAt = Date()
        var providerReference: String?
        let sonioxReference = UUID().uuidString
        func usageEvent(_ context: AIUsageContext, failed: Bool) -> AIUsageEvent {
            let id = context.account == .soniox ? "soniox:\(sonioxReference)"
                : providerReference.map { "elevenlabs:\($0)" } ?? UUID().uuidString
            if failed {
                return AIUsageEvent(id: id, createdAt: usageStartedAt, context: context,
                                    currency: context.currency, amount: nil, basis: .unavailable)
            }
            return .speech(context, seconds: AIUsageAudio.wavSeconds(wav) ?? 0, id: id, at: usageStartedAt)
        }
        do {
            let result: String
            switch route {
            case .soniox(let apiKey, let model):
                result = try await soniox(wav, apiKey: apiKey, model: model, language: language, reference: sonioxReference)
            case .deepgram(let apiKey, let model):
                result = try await deepgram(wav, apiKey: apiKey, model: model, language: language)
            case .elevenLabs(let apiKey, let model):
                result = try await elevenLabs(wav, apiKey: apiKey, model: model, language: language,
                                             onReference: { providerReference = $0 })
            case .selfHosted(let apiKey, let endpoint, let model):
                result = try await selfHosted(wav, apiKey: apiKey, endpoint: endpoint, model: model, language: language)            case .onDevice:
                result = try await onDevice.transcribe(audio: audio, language: language)
            }
            let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if let context = selection.usage {
                usageSink(usageEvent(context, failed: false))
            }
            os_log("batch transcription provider=%{public}@ audio_bytes=%{public}d ms=%{public}d chars=%{public}d",
                   log: Self.log, type: .info,
                   route.providerName, wav.count, Self.milliseconds(since: started), text.count)
            return text
        } catch {
            if let context = selection.usage {
                usageSink(usageEvent(context, failed: true))
            }
            os_log("batch transcription failed provider=%{public}@ ms=%{public}d reason=%{public}@",
                   log: Self.log, type: .error,
                   route.providerName, Self.milliseconds(since: started), Self.reason(error))
            throw error
        }
    }

    // MARK: Providers

    /// Deepgram pre-recorded: the realtime query on `/v1/listen`.
    private func deepgram(_ wav: Data, apiKey: String, model: String, language: String?) async throws -> String {
        let language = try DeepgramLanguagePolicy.queryLanguage(model: model, language: language)
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var items = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]
        items.append(URLQueryItem(name: "language", value: language))
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: wav)
        struct Response: Decodable {
            struct Results: Decodable { let channels: [Channel] }
            struct Channel: Decodable { let alternatives: [Alternative] }
            struct Alternative: Decodable { let transcript: String }
            let results: Results
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let best = response.results.channels.first?.alternatives.first else {
            throw ProviderBatchTranscriptionError.malformedResponse
        }
        return best.transcript
    }

    /// ElevenLabs speech-to-text with the recorded model (Scribe v2;
    /// `scribe_v2_realtime` is the realtime model), without audio-event tags or
    /// filler words.
    private func elevenLabs(_ wav: Data, apiKey: String, model: String, language: String?,
                            onReference: @escaping (String) -> Void) async throws -> String {
        var form = MultipartFormBody()
        form.field("model_id", model)
        if let language { form.field("language_code", language) }
        form.field("tag_audio_events", "false")
        form.field("no_verbatim", "true")
        form.wav(wav)
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: form.finished(), onResponse: { response in
            if let id = response.value(forHTTPHeaderField: "request-id"), !id.isEmpty, id.count <= 256 { onReference(id) }
        })
        return try Self.text(in: data)
    }

    /// OpenAI-compatible `/v1/audio/transcriptions` with the user's model. The
    /// key is optional: without one there is no `Authorization` header.
    private func selfHosted(
        _ wav: Data, apiKey: String?, endpoint: URL, model: String, language: String?
    ) async throws -> String {
        var form = MultipartFormBody()
        form.field("model", model)
        if let language { form.field("language", language) }
        form.field("response_format", "json")
        form.wav(wav)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: form.finished())
        return try Self.text(in: data)
    }

    /// Soniox file API: upload, job, poll, transcript. The file and the job
    /// are deleted afterwards, whatever the outcome.
    private func soniox(_ wav: Data, apiKey: String, model: String, language: String?, reference: String) async throws -> String {
        var form = MultipartFormBody()
        form.wav(wav)
        var upload = SonioxFileAPI.request(path: "files", method: "POST", apiKey: apiKey)
        upload.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let uploaded = try await send(upload, body: form.finished())
        guard let fileID = try? SonioxFileAPI.resourceID(in: uploaded) else {
            throw ProviderBatchTranscriptionError.malformedResponse
        }
        var jobID: String?
        defer { deleteFromSoniox(fileID: fileID, jobID: jobID, apiKey: apiKey) }

        // The realtime request's hints: the chosen language, then English.
        var hints = language.map { [$0] } ?? []
        if !hints.contains("en") { hints.append("en") }
        let job: [String: Any] = ["model": model, "file_id": fileID, "language_hints": hints, "client_reference_id": reference]
        var create = SonioxFileAPI.request(path: "transcriptions", method: "POST", apiKey: apiKey)
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let created = try await send(create, body: JSONSerialization.data(withJSONObject: job))
        guard let id = try? SonioxFileAPI.resourceID(in: created) else {
            throw ProviderBatchTranscriptionError.malformedResponse
        }
        jobID = id

        let giveUp = ContinuousClock.now + jobTimeout
        while true {
            try Task.checkCancellation()
            let data = try await send(SonioxFileAPI.request(path: "transcriptions/\(id)", method: "GET", apiKey: apiKey))
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch object?["status"] as? String {
            case "completed":
                let data = try await send(
                    SonioxFileAPI.request(path: "transcriptions/\(id)/transcript", method: "GET", apiKey: apiKey)
                )
                return try Self.text(in: data)
            case "error":
                throw ProviderBatchTranscriptionError.jobFailed
            case "queued", "processing":
                guard ContinuousClock.now < giveUp else { throw ProviderBatchTranscriptionError.timedOut }
                try await Task.sleep(for: pollInterval)
            default:
                throw ProviderBatchTranscriptionError.malformedResponse
            }
        }
    }

    /// Soniox keeps uploads and transcripts until they are deleted. Detached
    /// from the take, so a take the recovery deadline cancelled still deletes
    /// them and a result is not held back. The file goes first: a queued job
    /// then fails instead of starting. Soniox refuses (409) to delete a job
    /// that is still processing; that deletion is retried every
    /// `pollInterval` until `jobTimeout` passes.
    private func deleteFromSoniox(fileID: String, jobID: String?, apiKey: String) {
        let session = session
        let retryInterval = pollInterval
        let limit = jobTimeout
        Task {
            let fileStatus = await Self.status(
                of: SonioxFileAPI.request(path: "files/\(fileID)", method: "DELETE", apiKey: apiKey), in: session
            )
            var jobStatus: Int?
            if let jobID {
                let giveUp = ContinuousClock.now + limit
                while true {
                    jobStatus = await Self.status(
                        of: SonioxFileAPI.request(path: "transcriptions/\(jobID)", method: "DELETE", apiKey: apiKey),
                        in: session
                    )
                    guard jobStatus == 409, ContinuousClock.now < giveUp else { break }
                    try? await Task.sleep(for: retryInterval)
                }
            }
            os_log("soniox batch cleanup file_status=%{public}d job_status=%{public}d",
                   log: Self.log, type: .info, fileStatus ?? -1, jobStatus ?? -1)
        }
    }

    // MARK: HTTP

    /// The body of a 2xx answer; any other status is thrown.
    private func send(_ request: URLRequest, body: Data? = nil,
                      onResponse: ((HTTPURLResponse) -> Void)? = nil) async throws -> Data {
        var request = request
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse { onResponse?(response) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ProviderBatchTranscriptionError.httpStatus(status) }
        return data
    }

    /// The HTTP status of a request; nil when no answer arrived.
    private static func status(of request: URLRequest, in session: URLSession) async -> Int? {
        guard let response = try? await session.data(for: request).1 else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// `text` of a JSON answer (ElevenLabs, OpenAI-compatible, Soniox
    /// transcript). A missing field is an error, not silence.
    private static func text(in data: Data) throws -> String {
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProviderBatchTranscriptionError.malformedResponse
        }
        return response.text
    }

    /// `AudioRecorder` hands over a canonical WAV, the delivery ladder raw
    /// PCM16. Providers get a WAV either way.
    private static func wavFile(_ audio: Data) -> Data {
        let isWAV = audio.prefix(4).elementsEqual("RIFF".utf8)
            && audio.dropFirst(8).prefix(4).elementsEqual("WAVE".utf8)
        return isWAV ? audio : TurnAudioBuffer.wav(fromPCM16: audio)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }

    /// A failure label without content, for the log.
    private static func reason(_ error: Error) -> String {
        if let failure = error as? ProviderBatchTranscriptionError {
            switch failure {
            case .httpStatus(let status): return "http_\(status)"
            case .malformedResponse: return "malformed_response"
            case .jobFailed: return "job_failed"
            case .timedOut: return "timed_out"
            }
        }
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError { return "url_error_\(urlError.code.rawValue)" }
        return "other"
    }
}

/// The transcribers the app binds: one per feature route, never a shared one.
extension ProviderBatchTranscriber {
    /// A Drop take's batch path (recorder fallback, resilient-delivery batch
    /// rung, Retry). It goes to the route latched in `take` when the take began
    /// for the take's feature, not to the route the feature has now, so a mode
    /// or route change mid-take cannot move the audio to another provider. The
    /// key is read when the call is made; without it, or without a latched
    /// route, there is no batch path.
    @MainActor
    static func forDrop(
        take: DropTake? = nil,
        resolver: FeatureRouteResolver = FeatureRouteResolver(),
        session: URLSession = .shared,
        pollInterval: Duration = .milliseconds(500),
        onDevice: any BatchTranscribing = OnDeviceBatchTranscriber()
    ) -> ProviderBatchTranscriber {
        let take = take ?? .shared
        return ProviderBatchTranscriber(
            resolvedRoute: {
                guard let latched = take.route,
                      let resolved = try? resolver.resolve(latched, for: take.feature) else { return nil }
                return resolved
            },
            session: session,
            pollInterval: pollInterval,
            onDevice: onDevice
        )
    }

    /// The batch path of a feature that has no take of its own (Agent voice):
    /// the feature's current route and key, read on every call.
    @MainActor
    static func forFeature(
        _ feature: AIFeature,
        resolver: FeatureRouteResolver = FeatureRouteResolver(),
        session: URLSession = .shared,
        pollInterval: Duration = .milliseconds(500),
        onDevice: any BatchTranscribing = OnDeviceBatchTranscriber()
    ) -> ProviderBatchTranscriber {
        ProviderBatchTranscriber(
            resolvedRoute: {
                guard let resolved = try? resolver.resolve(feature) else { return nil }
                return resolved
            },
            session: session,
            pollInterval: pollInterval,
            onDevice: onDevice
        )
    }
}

/// multipart/form-data with a random boundary.
private struct MultipartFormBody {
    private let boundary = "exodia-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    /// The take as the `file` part, the name all three APIs expect.
    mutating func wav(_ content: Data) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(content)
        append("\r\n")
    }

    func finished() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
