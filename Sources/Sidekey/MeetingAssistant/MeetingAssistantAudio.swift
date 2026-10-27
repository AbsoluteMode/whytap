import Foundation

/// Meeting system-audio session. No microphone, research writer, notes store or
/// retained PCM. The relay is bounded and rejects overflow visibly.
@MainActor
final class MeetingAssistantAudio {
    private let connectionTimeout: Duration
    private let makeAudio: () -> TerminalSystemAudioSourceStreaming
    private let open: () async throws -> BYOKUpstreamSession
    private var source: TerminalSystemAudioSourceStreaming?
    private var upstream: BYOKUpstreamSession?
    private var relay: SubtitleAudioRelay?
    private var task: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var generation = UUID()
    var onText: ((String) -> Void)?
    /// Each newly finalized piece, joined exactly as it was appended to the transcript.
    var onFinal: ((String) -> Void)?
    var onState: ((Bool, String?) -> Void)?
    private(set) var active = false
    private(set) var ready = false

    init(connectionTimeout: Duration = .seconds(15), makeAudio: @escaping () -> TerminalSystemAudioSourceStreaming = { CoreAudioSystemAudioSource() },
         open: @escaping () async throws -> BYOKUpstreamSession = {
            let resolver = FeatureRouteResolver()
            let route = try resolver.resolve(.meetingAssistantAudio)
            if route.account == .deepgram, let error = DeepgramLanguagePolicy.configurationError(model: route.model, language: nil) {
                throw FeatureRouteError.invalidLanguageConfiguration(.meetingAssistantAudio, error)
            }
            let adapter = try RealtimeAdapterFactory.makeMetered(route)
            return try await adapter.open(language: nil, terms: [])
         }) {
        self.connectionTimeout = connectionTimeout
        self.makeAudio = makeAudio; self.open = open
    }

    func start() {
        guard !active else { return }
        let previousCleanup = cleanup
        generation = UUID(); let token = generation
        active = true; ready = false; onState?(true, nil)
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.connectionTimeout ?? .seconds(15))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.fail("Подключение заняло слишком много времени. Проверь модель речи и повтори.")
        }
        task = Task { [weak self] in
            guard let self else { return }
            await previousCleanup?.value
            do {
                let upstream = try await self.open()
                guard self.generation == token, !Task.isCancelled else { await upstream.close(); return }
                self.upstream = upstream
                let source = self.makeAudio(); self.source = source
                let relay = SubtitleAudioRelay(source: source) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.fail("Поток речи не успевает за звуком. Остановлено; попробуй более быструю модель.")
                    }
                }
                self.relay = relay
                try await source.start()
                guard self.generation == token, !Task.isCancelled else { await source.stop(); return }
                self.watchdog?.cancel()
                self.ready = true
                self.onState?(true, nil)
                self.sender = Task {
                    do {
                        for try await pcm in relay.stream {
                            guard !Task.isCancelled else { return }
                            await upstream.sendAudio(pcm)
                        }
                    } catch { return }
                }
                var committed = "", sawFinal = false
                for await event in upstream.events {
                    guard self.generation == token, !Task.isCancelled else { return }
                    switch event {
                    case .final(let text):
                        sawFinal = true
                        var piece = text
                        if upstream.finalsJoin == .wordBoundary, !committed.isEmpty,
                           committed.last?.isWhitespace == false, text.first?.isWhitespace == false { piece = " " + text }
                        committed += piece
                        committed = String(committed.suffix(12_000))
                        self.onText?(committed)
                        self.onFinal?(piece)
                    case .error:
                        self.fail("Распознавание остановилось. Проверь модель Meeting Assistant audio и соединение."); return
                    case .done(let text):
                        if !sawFinal { self.onText?(String(text.suffix(12_000))) }
                    case .partial: break
                    }
                }
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail("Поток встречи завершён. Включи ассистента волшебной палочкой, чтобы подключиться снова.")
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                let message = error is FeatureRouteError
                    ? "Выбери провайдера и модель Meeting Assistant audio в API & Models."
                    : "Не удалось слушать встречу. Проверь доступ к системному звуку и настройки модели."
                self.fail(message)
            }
        }
    }

    func fail(_ message: String) { cancel(); onState?(false, message) }

    @discardableResult func cancel() -> Task<Void, Never> {
        generation = UUID()
        active = false; ready = false
        task?.cancel(); task = nil; sender?.cancel(); sender = nil
        watchdog?.cancel(); watchdog = nil; relay?.cancel(); relay = nil
        let source = self.source, upstream = self.upstream, previous = cleanup
        self.source = nil; self.upstream = nil
        let work = Task { await previous?.value; await source?.stop(); await upstream?.close() }
        cleanup = work
        onState?(false, nil)
        return work
    }
}
