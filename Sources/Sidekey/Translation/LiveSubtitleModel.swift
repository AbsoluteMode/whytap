import Foundation
import os

/// One phrase of speech and its translation, shown as a pair. The source is
/// fixed when the phrase is committed; only its own translation fills it in.
struct SubtitleLine: Identifiable, Equatable {
    let id: UUID
    /// Fixed once committed, except for a sentence end a speech translator
    /// reports with the next word.
    var source: String
    var translation: String?
    /// The translation failed or timed out: the pair keeps its original.
    var failed = false
    /// Position in the session, kept when older pairs leave, so alternating
    /// bands never move from one pair to another.
    var ordinal = 0
    init(id: UUID = UUID(), source: String, translation: String? = nil, failed: Bool = false, ordinal: Int = 0) {
        self.id = id; self.source = source; self.translation = translation; self.failed = failed; self.ordinal = ordinal
    }
    var isSettled: Bool { translation != nil || failed }
}

enum SubtitlePhase: Equatable {
    case idle, connecting, listening, finishing, failed
    var isActive: Bool { self == .connecting || self == .listening || self == .finishing }
    /// Capture is on. After Stop (`finishing`) the overlay already shows the
    /// session as stopped while the last translation arrives in the background.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
    var isRunning: Bool { self == .connecting || self == .listening }
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
    /// Delay measurements only: never text, keys or audio.
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "subtitles")
    @Published var targetCode = "ru"
    @Published var sourceCode = "auto"
    @Published var showsOriginal = true
    @Published private(set) var phase: SubtitlePhase = .idle
    @Published private(set) var lines: [SubtitleLine] = []
    /// The sentence being heard (the newest original not yet in a pair).
    @Published private(set) var live = ""
    /// Its translation so far, in whole words: the live pair's right column.
    @Published private(set) var liveTranslation = ""
    /// The identity the live pair shows under and the next committed pair
    /// keeps, so a pair settles in place instead of leaving and coming back
    /// as a new row.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
    @Published private(set) var liveID = UUID()
    @Published private(set) var issue: TranslationIssue?
    @Published private(set) var hasAudio = false
    var onActivityChange: (() -> Void)?

    private let connectionTimeout: Duration
    private var connectionWatchdog: Task<Void, Never>?
    private let flushInterval: Duration
    private let makeAudio: () -> TerminalSystemAudioSourceStreaming
    /// Opens Subtitles' one engine, OpenAI live speech translation, or says
    /// why it cannot (no OpenAI key).
    private let openTranslator: (_ source: String?, _ target: String) async throws -> SpeechTranslationSession
    private var translator: SpeechTranslationSession?
    private var pairer = SubtitleSpeechPairer()
    private var nextOrdinal = 0
    private var generation = UUID()
    private var cleanupTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var stopWatchdog: Task<Void, Never>?
    /// Subtitles cost about $3 per hour of audio on the user's own key: a
    /// session stops by itself after an hour of listening, quietly, exactly
    /// as if Stop had been pressed. Start begins a new hour. No timer or
    /// message is shown, at the user's request.
    // WHY: .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
    static let maxSessionDuration: Duration = .seconds(60 * 60)
    private let maxSessionDuration: Duration
    private var sessionLimit: Task<Void, Never>?
    private var source: TerminalSystemAudioSourceStreaming?
    private var relay: SubtitleAudioRelay?
    /// A Start waiting for the previous session's cleanup (`start` during
    /// `finishing`).
    private var pendingStart: Task<Void, Never>?
    /// Events received from the session and how many the caption reflects:
    /// tests wait on these instead of on time.
    private var receivedEvents = 0
    private(set) var publishedEvents = 0

    init(
        flushInterval: Duration = .milliseconds(80),
        connectionTimeout: Duration = .seconds(15),
        maxSessionDuration: Duration = LiveSubtitleModel.maxSessionDuration,
        makeAudio: @escaping () -> TerminalSystemAudioSourceStreaming = { CoreAudioSystemAudioSource() },
        // Subtitles run only on Audio translate (OpenAI gpt-realtime-translate)
        // with the OpenAI key from API keys; without it Start names the fix.
        // WHY: .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
        openTranslator: @escaping (_ source: String?, _ target: String) async throws -> SpeechTranslationSession = { _, target in
            let key = try SubtitleAudioTranslate.key()
            let session = try await OpenAIRealtimeTranslateAdapter(apiKey: key, model: SubtitleAudioTranslate.model)
                .open(target: target)
            let context = AIUsageContext(feature: .subtitlesAudio, account: SubtitleAudioTranslate.account,
                                         model: SubtitleAudioTranslate.model)
            return AIUsageMeteredSpeechTranslation(session: session, context: context)
        }
    ) {
        self.openTranslator = openTranslator
        self.maxSessionDuration = maxSessionDuration
        self.connectionTimeout = connectionTimeout
        self.flushInterval = flushInterval
        self.makeAudio = makeAudio
    }

    @discardableResult func start() -> Task<Void, Never>? {
        guard !phase.isRunning else { return nil }
        if phase == .finishing {
            // Start after Stop while the last translation still arrives: drop
            // that tail and its capture, then start fresh. The restart is
            // tracked: closing, sleep or any cancel before it begins drops it.
            let cleanup = cancel()
            let restart = Task { [weak self] in
                await cleanup.value
                guard !Task.isCancelled, let self, self.phase == .idle || self.phase == .failed else { return }
                self.pendingStart = nil
                await self.start()?.value
            }
            pendingStart = restart
            return restart
        }
        pendingStart?.cancel(); pendingStart = nil
        cleanupTask = nil
        generation = UUID()
        let token = generation
        let language = sourceCode == "auto" ? nil : sourceCode
        lines = []; live = ""; liveTranslation = ""; issue = nil
        pairer = SubtitleSpeechPairer(); nextOrdinal = 0; liveID = UUID()
        receivedEvents = 0; publishedEvents = 0
        hasAudio = false
        setPhase(.connecting)
        connectionWatchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.connectionTimeout ?? .seconds(15))
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .connecting else { return }
            self.fail(.init(message: "Connecting took too long. Check your network, then start again."), token: token)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                // One session hears and translates; the key is checked before
                // any system audio is captured.
                // WHY: .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
                let translator = try await self.openTranslator(language, self.targetCode)
                guard self.generation == token, !Task.isCancelled else { await translator.close(); return }
                try await self.runSpeechTranslation(translator, token: token)
            } catch let failure as SpeechTranslationFailure {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail(.speechTranslation(failure, target: self.targetCode), token: token)
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail(.from(error, feature: .subtitlesAudio), token: token)
            }
        }
        runTask = task
        return task
    }

    /// The current session's identity: a control drawn for one session never
    /// stops another.
    var sessionID: UUID { generation }

    /// Stop (or Cancel while connecting) for the session `session` only, if it
    /// still runs: a click that began on another session's button does nothing.
    func stop(session: UUID) {
        guard generation == session, phase.isRunning else { return }
        stop()
    }

    func stop() {
        guard phase == .listening else { cancel(); return }
        sessionLimit?.cancel(); sessionLimit = nil
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
        // A Start queued behind a finishing session never runs after a cancel.
        pendingStart?.cancel(); pendingStart = nil
        if let cleanupTask { return cleanupTask }
        generation = UUID()
        let token = generation
        runTask?.cancel(); runTask = nil
        sessionLimit?.cancel(); sessionLimit = nil
        timer?.cancel(); timer = nil
        stopWatchdog?.cancel(); stopWatchdog = nil
        connectionWatchdog?.cancel(); connectionWatchdog = nil
        live = ""; liveTranslation = ""
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
        // A session that broke off keeps what it already said as pairs
        // (whole words), before the error replaces the live row.
        if translator != nil {
            pairer.dropUnfinishedWord()
            flushPairs(token: token, force: true)
        }
        self.issue = issue
        cancel()
    }

    private func setPhase(_ value: SubtitlePhase) { phase = value; onActivityChange?() }

    private func releaseCapture() async {
        audioTask?.cancel(); audioTask = nil
        relay?.cancel(); relay = nil
        let source = self.source; self.source = nil
        let translator = self.translator; self.translator = nil
        await source?.stop()
        await translator?.close()
    }

    // MARK: - Session

    /// One session hears and translates: audio goes in, the heard original
    /// and the translation come back as two streams that `pairer` cuts into
    /// pairs. Stop flushes the audio and waits for the provider's close.
    private func runSpeechTranslation(_ translator: SpeechTranslationSession, token: UUID) async throws {
        self.translator = translator
        let source = makeAudio()
        self.source = source
        let relay = SubtitleAudioRelay(source: source) { [weak self] in
            Task { @MainActor in
                self?.fail(.init(message: "Audio is arriving faster than it can be sent. Check your connection and start again."), token: token)
            }
        }
        self.relay = relay
        try await source.start()
        guard generation == token, !Task.isCancelled else { await source.stop(); return }
        connectionWatchdog?.cancel(); connectionWatchdog = nil
        setPhase(.listening)
        let limit = maxSessionDuration
        sessionLimit = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .listening else { return }
            self.stop()
        }
        // Audio goes out off the main actor: a busy caption never holds it
        // back (the relay's 128 buffers would fill and stop the session).
        // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
        nonisolated(unsafe) let session = translator
        audioTask = Task.detached { [weak self] in
            var heard = false
            do {
                for try await pcm in relay.stream {
                    guard !Task.isCancelled else { return }
                    if !heard, pcm.contains(where: { $0 != 0 }) {
                        heard = true
                        await MainActor.run { if self?.hasAudio == false { self?.hasAudio = true } }
                    }
                    await session.sendAudio(pcm)
                }
                guard !Task.isCancelled else { return }
                await session.endInput()
            } catch {
                await self?.fail(.init(message: "Audio is arriving faster than it can be sent. Check your connection and start again."), token: token)
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.flushInterval ?? .milliseconds(250))
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.flushPairs(token: token)
            }
        }
        var closedCleanly = false
        for await event in translator.events {
            guard generation == token, !Task.isCancelled else { return }
            switch event {
            case .source(let text, let elapsed):
                receivedEvents += 1
                pairer.addSource(text, elapsedMs: elapsed)
                publishSoon(token: token)
            case .translation(let text, let elapsed):
                receivedEvents += 1
                pairer.addTranslation(text, elapsedMs: elapsed, now: ProcessInfo.processInfo.systemUptime)
                publishSoon(token: token)
                // Numbers only: with the adapter's arrival log, whether a delay
                // that grows builds up at the provider or before the caption.
                let sent = Int(translator.acceptedAudioSeconds() * 1_000)
                os_log("processed elapsed_ms=%d sent_ms=%d trail_ms=%d", log: Self.log, type: .info,
                       elapsed ?? -1, sent, sent - (elapsed ?? 0))
            case .closed:
                closedCleanly = true
            case .failed(let failure):
                fail(.speechTranslation(failure, target: targetCode), token: token)
                return
            }
            if pairer.liveSource.count > 4_000 {
                fail(.init(message: "The translation is too far behind the speech. Start again."), token: token)
                return
            }
        }
        guard generation == token, !Task.isCancelled else { return }
        // Only session.closed after Stop is a complete ending; anything else
        // may have lost the last translation.
        guard phase == .finishing, closedCleanly else {
            fail(.speechTranslation(.connectionLost, target: targetCode), token: token)
            return
        }
        stopWatchdog?.cancel(); stopWatchdog = nil
        timer?.cancel(); timer = nil
        flushPairs(token: token, force: true)
        await releaseCapture()
        guard generation == token else { return }
        live = ""; liveTranslation = ""; runTask = nil
        setPhase(.idle)
    }

    /// Deltas often arrive several at once: the caption is published at once
    /// when the last publish is `publishInterval` old, otherwise by the flush
    /// timer, so a burst redraws (and restarts its motion) once.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
    static let publishInterval: TimeInterval = 0.08
    private var lastPublish: TimeInterval = 0

    private func publishSoon(token: UUID) {
        if ProcessInfo.processInfo.systemUptime - lastPublish >= Self.publishInterval { flushPairs(token: token) }
    }

    private func flushPairs(token: UUID, force: Bool = false) {
        guard generation == token else { return }
        lastPublish = ProcessInfo.processInfo.systemUptime
        publishedEvents = receivedEvents
        let carry = pairer.takeCarry()
        if !carry.isEmpty, let last = lines.indices.last { lines[last].source += carry }
        for pair in pairer.take(now: ProcessInfo.processInfo.systemUptime, force: force) {
            let translated = !pair.translation.isEmpty
            lines.append(SubtitleLine(id: liveID, source: pair.source, translation: translated ? pair.translation : nil,
                                      failed: !translated, ordinal: nextOrdinal))
            nextOrdinal += 1
            liveID = UUID()
            if lines.count > 40 { lines.removeFirst() }
        }
        let row = pairer.showLive(now: ProcessInfo.processInfo.systemUptime)
        if live != row.source { live = row.source }
        if liveTranslation != row.translation { liveTranslation = row.translation }
    }
}
