import Foundation

/// One phrase of speech and its translation, shown as a pair. The source is
/// fixed when the phrase is committed; only its own translation fills it in.
struct SubtitleLine: Identifiable, Equatable {
    let id: UUID
    let source: String
    var translation: String?
    /// The translation failed or timed out: the pair keeps its original.
    var failed = false
    init(source: String) { id = UUID(); self.source = source }
    var isSettled: Bool { translation != nil || failed }
}

enum SubtitlePhase: Equatable {
    case idle, connecting, listening, finishing, failed
    var isActive: Bool { self == .connecting || self == .listening || self == .finishing }
}

/// A bounded handoff prevents a slow socket from retaining unlimited system audio.
/// Overflow ends the session visibly; it never silently drops captured speech.
final class SubtitleAudioRelay: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var task: Task<Void, Never>?
    struct Overflow: Error {}

    init(
        source: SystemAudioSourceStreaming,
        convert: @escaping @Sendable ([Float]) -> Data = { SubtitleSegmenter.pcm16($0) },
        onOverflow: @escaping @Sendable () -> Void
    ) {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        stream = pair.stream
        continuation = pair.continuation
        let input = source.audioBufferStream()
        task = Task.detached {
            for await samples in input {
                guard !Task.isCancelled else { break }
                if case .dropped = pair.continuation.yield(convert(samples)) {
                    onOverflow()
                    pair.continuation.finish(throwing: Overflow())
                    return
                }
            }
            pair.continuation.finish()
        }
    }

    func cancel() { task?.cancel(); task = nil; continuation.finish() }
    deinit { task?.cancel(); continuation.finish() }
}

// WHY: .project-docs/decisions/2026-10-20-translation-tools.md
@MainActor
final class LiveSubtitleModel: ObservableObject {
    @Published var targetCode = "ru"
    @Published var sourceCode = "auto"
    @Published var showsOriginal = true
    @Published private(set) var phase: SubtitlePhase = .idle
    @Published private(set) var lines: [SubtitleLine] = []
    @Published private(set) var partial = ""
    /// The phrase being heard: committed text not yet cut into a phrase plus
    /// the provider's partial. Display only; never sent for translation.
    @Published private(set) var live = ""
    @Published private(set) var issue: TranslationIssue?
    @Published private(set) var hasAudio = false
    var onActivityChange: (() -> Void)?

    private let connectionTimeout: Duration
    private var connectionWatchdog: Task<Void, Never>?
    private let flushInterval: Duration
    private let phraseDeadline: Duration
    private let makeAudio: () -> TerminalSystemAudioSourceStreaming
    private let open: (String?) async throws -> BYOKUpstreamSession
    private let makeService: () async throws -> TextTranslating
    private var generation = UUID()
    private var cleanupTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var waiting: [UUID] = []
    private var inFlight: [UUID: (work: Task<Void, Never>, timer: Task<Void, Never>)] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var timer: Task<Void, Never>?
    private var stopWatchdog: Task<Void, Never>?
    private var source: TerminalSystemAudioSourceStreaming?
    private var upstream: BYOKUpstreamSession?
    private var relay: SubtitleAudioRelay?
    private var segmenter = SubtitleSegmenter()
    private var finalsJoin: BYOKTranscriptJoin = .verbatim
    private var partialLock = SubtitlePartialLock()
    private var spansSegment = false
    private var service: TextTranslating?
    private var target: TranslationTarget = .language("ru")
    private var sawFinal = false

    /// Phrases translated at the same time. One slow answer no longer holds
    /// every later phrase behind it.
    // WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
    static let maxConcurrentTranslations = 3
    /// Untranslated phrases (waiting and in flight) before the session stops
    /// visibly instead of falling ever further behind the speech.
    static let backlogLimit = 9

    init(
        flushInterval: Duration = .milliseconds(100),
        phraseDeadline: Duration = .seconds(8),
        connectionTimeout: Duration = .seconds(15),
        makeAudio: @escaping () -> TerminalSystemAudioSourceStreaming = { CoreAudioSystemAudioSource() },
        open: @escaping (String?) async throws -> BYOKUpstreamSession = { language in
            let resolver = FeatureRouteResolver()
            guard let route = resolver.route(for: .subtitlesAudio) else { throw FeatureRouteError.notSet(.subtitlesAudio) }
            if route.account == .deepgram,
               let error = DeepgramLanguagePolicy.configurationError(model: route.model, language: language) {
                throw FeatureRouteError.invalidLanguageConfiguration(.subtitlesAudio, error)
            }
            let adapter = try RealtimeAdapterFactory.makeMetered(resolver.resolve(route, for: .subtitlesAudio))
            return try await adapter.open(language: language, terms: [])
        },
        makeService: @escaping () async throws -> TextTranslating = { try await TranslationService.live(for: .subtitlesTranslation) }
    ) {
        self.connectionTimeout = connectionTimeout
        self.flushInterval = flushInterval
        self.phraseDeadline = phraseDeadline
        self.makeAudio = makeAudio
        self.open = open
        self.makeService = makeService
    }

    @discardableResult func start() -> Task<Void, Never>? {
        guard !phase.isActive else { return nil }
        cleanupTask = nil
        generation = UUID()
        let token = generation
        let language = sourceCode == "auto" ? nil : sourceCode
        target = .language(targetCode)
        lines = []; partial = ""; live = ""; issue = nil; waiting = []
        segmenter = SubtitleSegmenter(); partialLock.reset(); spansSegment = false
        sawFinal = false; hasAudio = false
        setPhase(.connecting)
        connectionWatchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.connectionTimeout ?? .seconds(15))
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .connecting else { return }
            self.fail(.init(message: "Connecting took too long. Check your providers and network, then start again."), token: token)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                // Resolve both routes before touching system audio. Never borrow a
                // Drop/Agent key and never switch the model after a failure.
                let service = try await self.makeService()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.service = service
                let upstream = try await self.open(language)
                guard self.generation == token, !Task.isCancelled else { await upstream.close(); return }
                self.upstream = upstream
                self.finalsJoin = upstream.finalsJoin
                self.spansSegment = upstream.partialsSpanSegment
                let source = self.makeAudio()
                self.source = source
                let relay = SubtitleAudioRelay(source: source) { [weak self] in
                    Task { @MainActor in
                        self?.fail(.init(message: "Audio is arriving faster than it can be sent. Check your connection and start again."), token: token)
                    }
                }
                self.relay = relay
                try await source.start()
                guard self.generation == token, !Task.isCancelled else { await source.stop(); return }
                self.connectionWatchdog?.cancel(); self.connectionWatchdog = nil
                self.setPhase(.listening)
                self.audioTask = Task { [weak self] in
                    do {
                        for try await pcm in relay.stream {
                            guard !Task.isCancelled else { return }
                            // RMS-independent: distinguish true digital silence from
                            // received audio without logging or persisting samples.
                            if pcm.contains(where: { $0 != 0 }), self?.hasAudio == false { self?.hasAudio = true }
                            await upstream.sendAudio(pcm)
                        }
                        guard !Task.isCancelled else { return }
                        await upstream.endInput()
                    } catch {
                        self?.fail(.init(message: "Audio is arriving faster than it can be sent. Check your connection and start again."), token: token)
                    }
                }
                self.timer = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: self?.flushInterval ?? .milliseconds(250))
                        guard !Task.isCancelled, let self, self.generation == token else { return }
                        self.flush(token: token)
                    }
                }
                for await event in upstream.events {
                    guard self.generation == token, !Task.isCancelled else { return }
                    switch event {
                    case .partial(let text):
                        self.partial = String(text.suffix(800))
                        if self.spansSegment {
                            self.partialLock.update(partial: text, now: ProcessInfo.processInfo.systemUptime)
                        }
                        self.updateLive()
                    case .final(let text):
                        self.sawFinal = true
                        let now = ProcessInfo.processInfo.systemUptime
                        if self.spansSegment {
                            // A commit closes the segment (a pause): its words not
                            // yet cut from the partial form the last phrase(s).
                            self.segmenter.append(self.partialLock.commit(text), join: upstream.finalsJoin, now: now)
                            self.partial = ""
                            self.flush(token: token, force: true)
                        } else {
                            self.segmenter.append(text, join: upstream.finalsJoin, now: now)
                            self.partial = ""
                            self.flush(token: token)
                        }
                        if self.segmenter.pending.count > 4_000 {
                            self.fail(.init(message: "The speech stream is too far behind. Choose a faster model and start again."), token: token)
                            return
                        }
                    case .done(let text):
                        if !self.sawFinal {
                            let rest = self.spansSegment ? self.partialLock.commit(text) : text
                            self.segmenter.append(rest, join: upstream.finalsJoin, now: ProcessInfo.processInfo.systemUptime)
                        }
                        guard self.phase == .finishing else {
                            self.fail(.init(message: "The audio connection ended. Start again to continue subtitles."), token: token)
                            return
                        }
                    case .error:
                        self.fail(.init(message: "The speech provider stopped responding. Check the Subtitles audio route and try again.", feature: .subtitlesAudio), token: token)
                        return
                    }
                }
                guard self.generation == token, !Task.isCancelled else { return }
                guard self.phase == .finishing else {
                    self.fail(.init(message: "The audio connection ended. Start again to continue subtitles."), token: token)
                    return
                }
                self.stopWatchdog?.cancel(); self.stopWatchdog = nil
                self.timer?.cancel(); self.timer = nil
                self.partial = ""
                self.flush(token: token, force: true)
                await self.translationsDrained()
                guard self.generation == token else { return }
                await self.releaseCapture()
                guard self.generation == token else { return }
                self.partial = ""; self.live = ""; self.service = nil; self.runTask = nil
                self.setPhase(.idle)
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail(.from(error, feature: self.service == nil ? .subtitlesTranslation : .subtitlesAudio), token: token)
            }
        }
        runTask = task
        return task
    }

    func stop() {
        guard phase == .listening else { cancel(); return }
        setPhase(.finishing)
        // Stop capture, then drain the bounded relay, then provider finals.
        // The source's terminal EOF lets the producer finish naturally: cancelling
        // it here would discard buffered and in-flight captured PCM.
        let source = self.source
        Task { await source?.stopAndFinishStreams() }
        let token = generation
        stopWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.fail(.init(message: "The speech provider did not finish in time. The completed subtitles are still here."), token: token)
        }
    }

    /// Closing/sleep cancels immediately, including pending paid requests.
    /// Keep a finishing state until old capture has actually been released.
    @discardableResult func cancel() -> Task<Void, Never> {
        if let cleanupTask { return cleanupTask }
        generation = UUID()
        let token = generation
        runTask?.cancel(); runTask = nil
        for task in inFlight.values { task.work.cancel(); task.timer.cancel() }
        inFlight = [:]
        resumeDrainWaiters()
        timer?.cancel(); timer = nil
        stopWatchdog?.cancel(); stopWatchdog = nil
        connectionWatchdog?.cancel(); connectionWatchdog = nil
        waiting = []; service = nil; partial = ""; live = ""
        setPhase(.finishing)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.releaseCapture()
            guard self.generation == token else { return }
            self.setPhase(self.issue == nil ? .idle : .failed)
            self.cleanupTask = nil
        }
        cleanupTask = task
        return task
    }

    func clear() { guard !phase.isActive else { return }; lines = []; issue = nil; setPhase(.idle) }

    private func fail(_ issue: TranslationIssue, token: UUID) {
        guard generation == token else { return }
        self.issue = issue
        cancel()
    }

    private func setPhase(_ value: SubtitlePhase) { phase = value; onActivityChange?() }

    private func releaseCapture() async {
        audioTask?.cancel(); audioTask = nil
        relay?.cancel(); relay = nil
        let source = self.source; self.source = nil
        let upstream = self.upstream; self.upstream = nil
        await source?.stop()
        await upstream?.close()
    }

    private func updateLive() {
        let committed = segmenter.pending.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = (spansSegment ? partialLock.unlockedText : partial).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { live = committed; return }
        guard !committed.isEmpty else { live = heard; return }
        // Soniox partials carry their own leading space; word providers need one.
        let glue = finalsJoin == .verbatim && partial.first?.isWhitespace == false ? "" : " "
        live = committed + glue + heard
    }

    /// Cuts every phrase that is ready and starts its translation. Each phrase
    /// becomes its own pair at once, so the original is on screen while the
    /// translation is still on its way.
    private func flush(token: UUID, force: Bool = false) {
        defer { updateLive() }
        let now = ProcessInfo.processInfo.systemUptime
        while let text = segmenter.take(now: now, force: force) {
            guard addPhrase(text, token: token) else { return }
        }
        // Committed text always comes first: the stable partial is later speech.
        guard spansSegment, segmenter.pending.isEmpty else { return }
        while let text = partialLock.take(now: now) {
            guard addPhrase(text, token: token) else { return }
        }
    }

    private func addPhrase(_ text: String, token: UUID) -> Bool {
        guard waiting.count + inFlight.count < Self.backlogLimit else {
            fail(.init(message: "Translation cannot keep up with speech. Choose a faster Subtitles LLM model, then start again.", feature: .subtitlesTranslation), token: token)
            return false
        }
        let line = SubtitleLine(source: text)
        lines.append(line); waiting.append(line.id)
        // Never evict a pair that is still waiting for its translation.
        if lines.count > 40, lines[0].isSettled { lines.removeFirst() }
        startTranslations(token: token)
        return true
    }

    private func startTranslations(token: UUID) {
        guard let service, generation == token else { return }
        while inFlight.count < Self.maxConcurrentTranslations, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let line = lines.first(where: { $0.id == id }) else { continue }
            let previous = context(before: id)
            let target = self.target
            let deadline = phraseDeadline
            let work = Task { [weak self] in
                let result: Result<String, Error>
                do { result = .success(try await service.translatePhrase(line.source, previous: previous, target: target)) }
                catch { result = .failure(error) }
                self?.finishTranslation(id, result, token: token)
            }
            let timer = Task { [weak self] in
                try? await Task.sleep(for: deadline)
                guard !Task.isCancelled else { return }
                self?.finishTranslation(id, .failure(PhraseTimeout()), token: token)
            }
            inFlight[id] = (work, timer)
        }
        if waiting.isEmpty, inFlight.isEmpty { resumeDrainWaiters() }
    }

    /// The first outcome of a phrase wins: its answer or its deadline. A late
    /// answer of an older phrase only ever fills that phrase's own pair.
    private func finishTranslation(_ id: UUID, _ result: Result<String, Error>, token: UUID) {
        guard generation == token, let task = inFlight.removeValue(forKey: id) else { return }
        task.work.cancel(); task.timer.cancel()
        switch result {
        case .success(let value):
            if let index = lines.firstIndex(where: { $0.id == id }) { lines[index].translation = value }
        case .failure(let error):
            if Self.stopsSession(error) {
                fail(.from(error, feature: .subtitlesTranslation), token: token)
                return
            }
            // A slow or failed phrase keeps its original; later phrases go on.
            if let index = lines.firstIndex(where: { $0.id == id }) { lines[index].failed = true }
        }
        startTranslations(token: token)
    }

    /// Setup and key problems repeat for every phrase: stop with the fix.
    /// Timeouts, busy providers and network blips affect one phrase only.
    static func stopsSession(_ error: Error) -> Bool {
        if error is FeatureRouteError { return true }
        guard let llm = error as? OpenRouterLLMError else { return false }
        switch llm {
        case .notConfigured, .missingKey, .missingBaseURL, .invalidBaseURL, .missingModel: return true
        case .unexpectedStatus(let status, _): return [401, 402, 403, 404].contains(status)
        default: return false
        }
    }

    private func context(before id: UUID) -> SubtitlePair? {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return nil }
        return lines[..<index].last(where: { $0.translation != nil }).map {
            SubtitlePair(source: $0.source, translation: $0.translation ?? "")
        }
    }

    private func translationsDrained() async {
        guard !waiting.isEmpty || !inFlight.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters; drainWaiters = []
        waiters.forEach { $0.resume() }
    }
}

struct PhraseTimeout: Error {}
