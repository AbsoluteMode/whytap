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

/// The session button's action as drawn. Cancel and Stop carry the session
/// they were drawn for.
// WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
enum SubtitleSessionAction: Hashable {
    case start
    case cancel(UUID)
    case stop(UUID)
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
    /// Listening has heard only silence for `accessHintDelay`, and no capture
    /// has ever heard this Mac's sound: macOS may be withholding system
    /// audio. Only then does the overlay offer the privacy pane.
    // WHY: .project-docs/decisions/2026-11-25-system-audio-heard-means-allowed.md
    @Published private(set) var silenceMayMeanNoAccess = false
    var onActivityChange: (() -> Void)?

    private let connectionTimeout: Duration
    private var connectionWatchdog: Task<Void, Never>?
    private let flushInterval: Duration
    private let makeAudio: () -> TerminalSystemAudioSourceStreaming
    private let systemAudioHeard: () -> Bool
    private let accessHintDelay: Duration
    private var accessHint: Task<Void, Never>?
    /// Another capture (a meeting, the detector) can prove the grant while
    /// the hint is already shown: it goes away then too.
    nonisolated(unsafe) private var accessObserver: NSObjectProtocol?
    /// Opens Subtitles' engine (Soniox live translation, or OpenAI's without
    /// a Soniox key), or says why it cannot (no key).
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
    /// How long Stop waits for the provider's close before it gives up.
    private let stopDeadline: Duration
    /// Subtitles cost up to about $3 per hour of audio on the user's own key
    /// (OpenAI; Soniox about $0.12): a
    /// session stops by itself after an hour of listening, quietly, exactly
    /// as if Stop had been pressed. Start begins a new hour. No timer or
    /// message is shown, at the user's request.
    // WHY: .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
    static let maxSessionDuration: Duration = .seconds(60 * 60)
    /// Subtitles capture the system mix at the provider's 24 kHz, low-passed
    /// before resampling, instead of the 16 kHz Meeting Notes use.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-realtime-audio.md
    nonisolated static let captureSampleRate: Double = 24_000
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
        accessHintDelay: Duration = .seconds(5),
        stopDeadline: Duration = .seconds(10),
        systemAudioHeard: @escaping () -> Bool = { SystemAudioAccess.heard() },
        makeAudio: @escaping () -> TerminalSystemAudioSourceStreaming = {
            CoreAudioSystemAudioSource(targetSampleRate: LiveSubtitleModel.captureSampleRate, antiAlias: true)
        },
        // Subtitles run on Soniox live translation with the Soniox key, or on
        // OpenAI gpt-realtime-translate with the OpenAI key; without either
        // Start names the fix.
        // WHY: .project-docs/decisions/2026-11-25-subtitle-soniox-engine.md
        openTranslator: @escaping (_ source: String?, _ target: String) async throws -> SpeechTranslationSession = { source, target in
            try await SubtitleAudioTranslate.open(source: source, target: target)
        }
    ) {
        self.openTranslator = openTranslator
        self.maxSessionDuration = maxSessionDuration
        self.connectionTimeout = connectionTimeout
        self.flushInterval = flushInterval
        self.makeAudio = makeAudio
        self.accessHintDelay = accessHintDelay
        self.stopDeadline = stopDeadline
        self.systemAudioHeard = systemAudioHeard
        accessObserver = NotificationCenter.default.addObserver(
            forName: SystemAudioAccess.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessMayBeProven() }
        }
    }

    deinit {
        if let accessObserver { NotificationCenter.default.removeObserver(accessObserver) }
    }

    /// The grant was proven elsewhere: no hint, now or later this session.
    private func accessMayBeProven() {
        guard systemAudioHeard() else { return }
        accessHint?.cancel(); accessHint = nil
        silenceMayMeanNoAccess = false
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
        accessHint?.cancel(); accessHint = nil
        silenceMayMeanNoAccess = false
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
            } catch let failure as SubtitleAudioTranslate.EngineFailure {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail(.speechTranslation(failure.failure, target: self.targetCode, provider: failure.provider),
                          token: token)
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

    /// What the session button shows now, bound to this session: Start while
    /// nothing runs, Cancel while connecting, Stop while listening.
    var sessionAction: SubtitleSessionAction {
        switch phase {
        case .connecting: .cancel(generation)
        case .listening: .stop(generation)
        case .idle, .failed, .finishing: .start
        }
    }

    /// Runs `action` only while it is still the action the button shows: a
    /// click that began on Start, Cancel or Stop never runs another one, or
    /// acts on another session.
    func perform(_ action: SubtitleSessionAction) {
        guard action == sessionAction else { return }
        switch action {
        case .start: start()
        case .cancel: cancel()
        case .stop: stop()
        }
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
        let stopDeadline = self.stopDeadline
        stopWatchdog = Task { [weak self] in
            try? await Task.sleep(for: stopDeadline)
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
        accessHint?.cancel(); accessHint = nil
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

    /// The first sound of a session: the caption can start, and no
    /// permission hint is due.
    private func markHeard() {
        guard !hasAudio else { return }
        hasAudio = true
        silenceMayMeanNoAccess = false
        accessHint?.cancel(); accessHint = nil
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
        // Soniox: the original shows as heard, the translation piece by piece.
        // WHY: .project-docs/decisions/2026-11-25-subtitle-soniox-live-original.md
        pairer = SubtitleSpeechPairer(streamingPreview: translator.streamsOriginalPreview)
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
        // A quiet Mac is not a refusal: the hint waits, and never appears
        // once any capture has heard sound on this Mac.
        if !systemAudioHeard() {
            let delay = accessHintDelay
            accessHint = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.generation == token, self.phase == .listening,
                      !self.hasAudio, !self.systemAudioHeard() else { return }
                self.silenceMayMeanNoAccess = true
            }
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
                        await self?.markHeard()
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
            case .closed:
                closedCleanly = true
            case .failed(let failure):
                fail(.speechTranslation(failure, target: targetCode, provider: translator.providerName), token: token)
                return
            default:
                // A provider frame (`.update`) is applied whole before it is
                // published: the caption never shows half of it.
                // WHY: .project-docs/decisions/2026-11-25-subtitle-soniox-live-original.md
                apply(event, translator: translator)
                publishSoon(token: token)
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
            fail(.speechTranslation(.connectionLost, target: targetCode, provider: translator.providerName), token: token)
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

    /// Feeds one text event to the pairer; the caller publishes.
    private func apply(_ event: SpeechTranslationEvent, translator: SpeechTranslationSession) {
        switch event {
        case .source(let text, let elapsed):
            receivedEvents += 1
            pairer.addSource(text, elapsedMs: elapsed)
        case .sourcePreview(let text):
            receivedEvents += 1
            pairer.setPreview(text)
        case .translation(let text, let elapsed), .translationPiece(let text, let elapsed):
            receivedEvents += 1
            let whole: Bool
            if case .translationPiece = event { whole = true } else { whole = false }
            pairer.addTranslation(text, elapsedMs: elapsed, now: ProcessInfo.processInfo.systemUptime, whole: whole)
            // Numbers only: with the adapter's arrival log, whether a delay
            // that grows builds up at the provider or before the caption.
            let sent = Int(translator.acceptedAudioSeconds() * 1_000)
            os_log("processed elapsed_ms=%d sent_ms=%d trail_ms=%d", log: Self.log, type: .info,
                   elapsed ?? -1, sent, sent - (elapsed ?? 0))
        case .update(let frame):
            for part in frame { apply(part, translator: translator) }
        case .closed, .failed:
            break
        }
    }

    /// Deltas often arrive several at once: the caption is published at once
    /// when the last change it showed is `publishInterval` old, otherwise by
    /// the flush timer, so a burst redraws (and restarts its motion) once.
    /// Only a flush that changed the caption counts: the timer's empty ticks
    /// used to make almost every delta wait for the next tick (about 80 ms).
    // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
    // WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
    static let publishInterval: TimeInterval = 0.08
    private var lastPublish: TimeInterval = 0

    private func publishSoon(token: UUID) {
        if ProcessInfo.processInfo.systemUptime - lastPublish >= Self.publishInterval { flushPairs(token: token) }
    }

    private func flushPairs(token: UUID, force: Bool = false) {
        guard generation == token else { return }
        let now = ProcessInfo.processInfo.systemUptime
        publishedEvents = receivedEvents
        var changed = false
        let carry = pairer.takeCarry()
        if !carry.isEmpty, let last = lines.indices.last { lines[last].source += carry; changed = true }
        for pair in pairer.take(now: now, force: force) {
            let translated = !pair.translation.isEmpty
            lines.append(SubtitleLine(id: liveID, source: pair.source, translation: translated ? pair.translation : nil,
                                      failed: !translated, ordinal: nextOrdinal))
            nextOrdinal += 1
            liveID = UUID()
            if lines.count > SubtitleCaption.historyPairs { lines.removeFirst() }
            changed = true
        }
        let row = pairer.showLive(now: now)
        if live != row.source { live = row.source; changed = true }
        if liveTranslation != row.translation { liveTranslation = row.translation; changed = true }
        if changed { lastPublish = now }
    }
}
