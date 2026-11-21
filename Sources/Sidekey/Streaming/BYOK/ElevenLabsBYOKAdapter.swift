import Foundation
import os

/// Builds the ElevenLabs Scribe v2 Realtime WS URL. Config rides in the query
/// (ElevenLabs has no client config message); auth is the `xi-api-key` header
/// applied by the adapter. Confirmed against ElevenLabs docs
/// (/v1/speech-to-text/realtime). `audio_format=pcm_16000` and the repeated
/// `keyterms` param are confirmed against the official ElevenLabs realtime docs.
/// `no_verbatim=true` asks Scribe to remove fillers, false starts and
/// disfluencies. Remaining end-to-end behavior is verified once a live key exists.
/// When Scribe commits a segment. Dictation takes commit once, by hand, at
/// the end. Subtitles listen to a continuous stream that nobody ends, so the
/// provider commits each phrase at a pause; manual there meant one commit per
/// ~36 s segment cap, cut mid-word.
enum ElevenLabsCommitStrategy: Equatable {
    case manual
    case vad(silenceSeconds: Double)

    /// Subtitles: commit after half a second of silence (documented range
    /// 0.192–3.0 s), a speaker's pause between phrases.
    // WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
    static let subtitles = ElevenLabsCommitStrategy.vad(silenceSeconds: 0.5)
}

enum ElevenLabsRealtimeURL {
    /// Always a manual commit for takes, auto-stop takes included: a provider
    /// commit cannot be told from Scribe's ~36 s segment cap, so it never ends
    /// a take. Only Subtitles, which have no take, ask for VAD commits.
    /// WHY: .project-docs/decisions/2026-11-12-drop-auto-stop-local-rule-only.md
    static func make(model: String, language: String?, terms: [String],
                     commit: ElevenLabsCommitStrategy = .manual) -> URL {
        var comps = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
        ]
        switch commit {
        case .manual:
            items.append(URLQueryItem(name: "commit_strategy", value: "manual"))
        case .vad(let seconds):
            items.append(URLQueryItem(name: "commit_strategy", value: "vad"))
            items.append(URLQueryItem(name: "vad_silence_threshold_secs", value: String(seconds)))
        }
        items.append(URLQueryItem(name: "no_verbatim", value: "true"))
        if let language, !language.isEmpty { items.append(URLQueryItem(name: "language_code", value: language)) }
        // ElevenLabs expects one `keyterms` query param per term (repeated), not
        // a comma-joined string — same shape as Deepgram's `keyterm`.
        for term in terms { items.append(URLQueryItem(name: "keyterms", value: term)) }
        comps.queryItems = items
        return comps.url!
    }
}

/// ElevenLabs Scribe v2 Realtime BYOK adapter: client-direct with the user's key.
struct ElevenLabsBYOKAdapter: BYOKTranscriptionAdapter {
    /// Language/terms reach the URL (query), so the factory is parameterized.
    typealias TransportFactory = (_ language: String?, _ terms: [String]) -> StreamingTransporting
    private let makeTransport: TransportFactory
    /// Warmup: `prerollSilenceMs` of silence is
    /// prepended before the first real audio and carries `previousText` model
    /// context, so Scribe's no_verbatim doesn't clip the first short word as a
    /// false start. Defaults (`prerollSilenceMs=150`,
    /// `ELEVENLABS_REALTIME_PREVIOUS_TEXT="."`).
    private let prerollSilenceMs: Int
    private let previousText: String?
    let commit: ElevenLabsCommitStrategy

    /// Production: authenticated `URLSessionWebSocketTask` with the URL query.
    init(apiKey: String, model: String, prerollSilenceMs: Int = 150, previousText: String? = ".",
         commit: ElevenLabsCommitStrategy = .manual) {
        self.prerollSilenceMs = prerollSilenceMs
        self.previousText = previousText
        self.commit = commit
        self.makeTransport = { language, terms in
            let url = ElevenLabsRealtimeURL.make(model: model, language: language, terms: terms, commit: commit)
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            return URLSessionWebSocketTransport(task: URLSession.shared.webSocketTask(with: request))
        }
    }

    /// Test: inject a transport.
    init(
        model: String, prerollSilenceMs: Int = 150, previousText: String? = ".",
        commit: ElevenLabsCommitStrategy = .manual,
        transport: @escaping TransportFactory
    ) {
        self.prerollSilenceMs = prerollSilenceMs
        self.previousText = previousText
        self.commit = commit
        self.makeTransport = transport
    }

    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
        let transport = makeTransport(language, terms)
        transport.resume()
        let session = ElevenLabsBYOKSession(
            transport: transport, prerollSilenceMs: prerollSilenceMs, previousText: previousText,
            commit: commit
        )
        session.start()
        return session
    }
}

final class ElevenLabsBYOKSession: BYOKUpstreamSession, @unchecked Sendable {
    private let transport: StreamingTransporting
    private var continuation: AsyncStream<BYOKStreamEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var finalParts: [String] = []
    /// Guards `_endInputSent`: written by the caller's `endInput()` and read by
    /// the receive task (different executors).
    private let lock = NSLock()
    private var _endInputSent = false
    private var usageSessionID: String?
    /// Preroll silence (PCM16 mono @ sampleRate) prepended before the first real
    /// audio; `previousText` is model context that rides it. Sent once, on the
    /// first `sendAudio`. `firstAudioSent` is touched only from the serial audio
    /// forward loop, so it needs no lock.
    private let prerollSilence: Data
    private let previousText: String?
    private var firstAudioSent = false
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "byok-elevenlabs")
    private static let sampleRate = 16_000

    let events: AsyncStream<BYOKStreamEvent>
    /// `partial_transcript` is the whole segment since the last commit.
    var partialsSpanSegment: Bool { true }

    private let commit: ElevenLabsCommitStrategy

    init(transport: StreamingTransporting, prerollSilenceMs: Int = 0, previousText: String? = nil,
         commit: ElevenLabsCommitStrategy = .manual) {
        self.transport = transport
        self.commit = commit
        self.prerollSilence = prerollSilenceMs > 0
            ? Data(count: Self.sampleRate * 2 * prerollSilenceMs / 1000)
            : Data()
        self.previousText = previousText
        var cont: AsyncStream<BYOKStreamEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func start() { startReceiveLoop() }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await self.transport.receive()
                switch result {
                case .failure:
                    // Socket closed. If segments accumulated (EL closed its
                    // segment-capped stream, or a post-commit close), recover them
                    // as the terminal so a long dictation is delivered, not lost.
                    // Nothing accumulated → a genuine transport error.
                    if self.finalParts.isEmpty {
                        self.emit(.error("transport"))
                    } else {
                        self.emit(.done(self.finalParts.joined(separator: " ")))
                    }
                    self.continuation?.finish()
                    return
                case .success(let frame):
                    guard case .text(let s) = frame,
                          let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                          let type = obj["message_type"] as? String
                    else { continue }
                    os_log("byok elevenlabs event type=%{public}@", log: Self.log, type: .debug, type)
                    // LIVE-VERIFY: the receive envelope (`message_type` discriminator,
                    // `text` field) is from the published docs but unconfirmed against a
                    // live socket. If either name is wrong the terminal is never matched
                    // and `run()` resolves to `.cancelled` (empty) on socket close.
                    switch type {
                    case "session_started":
                        if let id = obj["session_id"] as? String {
                            self.lock.withLock { self.usageSessionID = id }
                        }
                    case "partial_transcript":
                        if let text = obj["text"] as? String { self.emit(.partial(text)) }
                    case "committed_transcript", "committed_transcript_with_timestamps":
                        let text = (obj["text"] as? String) ?? ""
                        self.finalParts.append(text)
                        self.emit(.final(text))
                        // Scribe auto-commits a segment at its ~36 s max length
                        // WITHOUT our manual commit; the socket stays open and
                        // committedTranscript is a LIST of segments. Only OUR commit
                        // (endInput on release) makes a committed_transcript the true
                        // terminal — ending on the first auto-commit truncated any
                        // dictation longer than ~36 s (the long-hold "death").
                        // Accumulate mid-hold segments and keep listening; the joined
                        // terminal is delivered on our commit here, or on close above.
                        // WHY: docs/decisions/2026-06-30-elevenlabs-byok-segment-commit-truncation.md
                        guard self.endInputDidSend else { continue }
                        self.emit(.done(self.finalParts.joined(separator: " ")))
                        self.continuation?.finish()
                        return
                    default:
                        continue  // session_started and anything else → ignore
                    }
                }
            }
        }
    }

    private var endInputDidSend: Bool {
        lock.lock(); defer { lock.unlock() }
        return _endInputSent
    }

    private func emit(_ ev: BYOKStreamEvent) { continuation?.yield(ev) }

    func sendAudio(_ pcm: Data) async {
        guard !firstAudioSent else {
            await sendChunk(audio: pcm, commit: false)  // native PCM16 16 kHz, no resample
            return
        }
        firstAudioSent = true
        // Warm up the stream before the first REAL audio so Scribe's no_verbatim
        // doesn't clip the first short word as a false start (EL guidance; parity
        // with the preroll above). `previousText` is model context that
        // rides the preroll chunk, or the first real chunk when preroll is off.
        if prerollSilence.isEmpty {
            await sendChunk(audio: pcm, commit: false, previousText: previousText)
        } else {
            await sendChunk(audio: prerollSilence, commit: false, previousText: previousText)
            await sendChunk(audio: pcm, commit: false)
        }
    }

    func endInput() async {
        // Mark BEFORE the commit send so the receive loop treats the NEXT
        // committed_transcript as the true terminal, not a mid-hold auto-commit.
        lock.lock(); _endInputSent = true; lock.unlock()
        // Under VAD the documentation does not say a manual commit is honoured:
        // a pause longer than the threshold lets the provider commit the tail
        // itself, and the commit below covers the manual case.
        if case .vad(let seconds) = commit {
            let silence = Data(count: Self.sampleRate * 2 * Int((seconds + 0.2) * 1000) / 1000)
            await sendChunk(audio: silence, commit: false)
        }
        await sendChunk(audio: Data(), commit: true)  // single manual commit → terminal committed_transcript
    }

    private func sendChunk(audio: Data, commit: Bool, previousText: String? = nil) async {
        var msg: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": audio.base64EncodedString(),
            "sample_rate": Self.sampleRate,
            "commit": commit,
        ]
        // `previous_text` is model context ("prior segment closed, new start
        // ahead"), NOT transcript — it must never surface in committed_transcript.
        if let previousText, !previousText.isEmpty { msg["previous_text"] = previousText }
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        do {
            try await transport.send(.text(String(decoding: data, as: UTF8.self)))
        } catch {
            // Only the commit (end-of-stream) send failure is worth a line:
            // it means the receive side will never deliver the terminal
            // transcript, and the session's stop watchdog will fire. Per-audio
            // chunk failures are noisy and the surrounding loop already stops
            // forwarding, so don't log those. Event type only, no payload.
            if commit {
                os_log("byok elevenlabs endInput send failed", log: Self.log, type: .error)
                self.emit(.error(BYOKStreamErrorCode.endOfStreamSendFailed))
                self.continuation?.finish()
            }
        }
    }

    func close() async {
        receiveTask?.cancel()
        continuation?.finish()
        transport.cancel(reason: "client closed")
    }

    func usageSnapshot() async -> BYOKUsageSnapshot? {
        let reference = transport.responseRequestID ?? lock.withLock { usageSessionID }
        return BYOKUsageSnapshot(acceptedAudioBytes: nil, providerReference: reference)
    }
}
