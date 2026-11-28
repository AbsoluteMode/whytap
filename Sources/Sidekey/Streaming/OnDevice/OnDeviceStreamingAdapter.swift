import Foundation
import os.log

/// The on-device model behind the real-time adapter contract, for the
/// features that read a stream through an adapter rather than the Drop
/// session: Subtitles audio (system audio, live) and Meetings (the finished
/// recording fed in chunks). No socket, no key, no network.
///
/// Parakeet decodes whole buffers, not a token stream, so the session cuts
/// the stream into phrases at pauses (`OnDevicePhraseSegmenter`), decodes
/// each phrase once as a `.final` and, when asked, re-decodes the phrase in
/// progress about once a second as a `.partial` for live text.
// WHY: .project-docs/decisions/2026-11-21-on-device-everywhere.md
struct OnDeviceStreamingAdapter: BYOKTranscriptionAdapter {
    let feature: AIFeature
    /// Live text of the phrase in progress. Subtitles show it; Meetings read
    /// only finals, so they skip the extra decodes.
    var livePartials: Bool
    var readiness: OnDeviceSpeechReadiness = .live
    /// No wait limit: phrases queue while the model loads (the first load
    /// after a download can take minutes) instead of ending the meeting's
    /// stream. WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
    var decoder: any OnDeviceSpeechDecoding = ParakeetSpeechDecoder(preparationWait: nil)

    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
        // The downloaded model is the credential: without it nothing opens.
        guard readiness.isReady() else { throw FeatureRouteError.missingKey(feature) }
        return OnDeviceStreamingSession(decoder: decoder, language: language, livePartials: livePartials)
    }
}

/// Cuts 16 kHz mono audio into phrases for whole-buffer decoding. Nothing is
/// dropped: consecutive phrases cover the stream, so quiet speech the pause
/// detector misses is still decoded with its neighbours.
///
/// A phrase ends after `pauseFrames` of quiet following speech, or at
/// `maxSamples` (below Parakeet's 15 s single-pass window), where it is cut at
/// the quietest frame of its last `cutSearchSamples` so a word is rarely split.
struct OnDevicePhraseSegmenter {
    static let frameSamples = 320              // 20 ms
    static let pauseFrames = 35                // 700 ms
    static let maxSamples = 192_000            // 12 s
    static let cutSearchSamples = 64_000       // last 4 s
    /// Quiet is below this absolute level (about -44 dBFS) or within 9 dB of
    /// the quietest recent frame, whichever is higher.
    static let absoluteSpeechLevel: Float = 0.006
    static let floorRatio: Float = 2.8

    private(set) var phrase: [Float] = []
    private var frameLevels: [Float] = []
    private var pending: [Float] = []
    private var sawSpeech = false
    private var quietRun = 0
    private var floor: Float?

    /// The samples of every phrase this audio completed, oldest first.
    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var completed: [[Float]] = []
        var start = 0
        while pending.count - start >= Self.frameSamples {
            let frame = pending[start..<(start + Self.frameSamples)]
            start += Self.frameSamples
            phrase.append(contentsOf: frame)
            let level = Self.rms(frame)
            frameLevels.append(level)
            if isSpeech(level) {
                sawSpeech = true
                quietRun = 0
            } else {
                quietRun += 1
            }
            if sawSpeech, quietRun >= Self.pauseFrames {
                completed.append(take(frames: frameLevels.count))
            } else if phrase.count >= Self.maxSamples {
                completed.append(take(frames: quietestCutFrame()))
            }
        }
        pending.removeFirst(start)
        return completed
    }

    /// What is left at the end of the stream, if anything.
    mutating func finish() -> [Float]? {
        phrase.append(contentsOf: pending)
        pending = []
        guard !phrase.isEmpty else { return nil }
        let rest = phrase
        phrase = []; frameLevels = []; sawSpeech = false; quietRun = 0
        return rest
    }

    /// The phrase in progress, for a live partial.
    var current: [Float] { phrase + pending }

    /// Digital silence (a muted source, an idle system tap) is not decoded.
    static func isSilent(_ samples: [Float]) -> Bool {
        !samples.contains { abs($0) >= 0.001 }
    }

    private mutating func isSpeech(_ level: Float) -> Bool {
        // The floor starts near -60 dBFS, follows quieter frames at once and
        // louder ones slowly (a steady fan or music becomes quiet over
        // seconds; the dips between syllables keep real speech above it).
        let current = floor ?? 0.001
        floor = level < current ? level : current * 0.999 + level * 0.001
        return level > max(Self.absoluteSpeechLevel, current * Self.floorRatio)
    }

    private func quietestCutFrame() -> Int {
        let searchFrames = Self.cutSearchSamples / Self.frameSamples
        let lower = max(1, frameLevels.count - searchFrames)
        var best = frameLevels.count
        var bestLevel = Float.greatestFiniteMagnitude
        for index in lower..<frameLevels.count where frameLevels[index] < bestLevel {
            bestLevel = frameLevels[index]
            best = index + 1
        }
        return best
    }

    private mutating func take(frames: Int) -> [Float] {
        let cut = frames * Self.frameSamples
        let done = Array(phrase[..<cut])
        phrase.removeFirst(cut)
        frameLevels.removeFirst(frames)
        // A remainder after a length cut is the start of the next phrase: its
        // speech and its trailing quiet still count toward the next pause.
        let threshold = max(Self.absoluteSpeechLevel, (floor ?? 0) * Self.floorRatio)
        sawSpeech = frameLevels.contains { $0 > threshold }
        quietRun = frameLevels.reversed().prefix { $0 <= threshold }.count
        return done
    }

    private static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sum = frame.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(frame.count)).squareRoot()
    }
}

/// One stream on this Mac. Phrases decode in order on one worker; `sendAudio`
/// waits while two finished phrases are still waiting, so a fast reader (a
/// meeting's recording) never holds more than a few phrases in memory.
actor OnDeviceStreamingSession: BYOKUpstreamSession {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "on-device-speech")
    /// New audio in the phrase in progress before its next live partial.
    static let partialStrideSamples = 16_000   // ~1 s
    /// Parakeet rejects under 0.3 s; a partial waits for a little more.
    static let minPartialSamples = 8_000
    static let maxWaitingPhrases = 2
    static let minFinalSamples = 4_800

    private enum Job {
        case final([Float])
        case partial([Float])
    }

    nonisolated let events: AsyncStream<BYOKStreamEvent>
    nonisolated var finalsJoin: BYOKTranscriptJoin { .wordBoundary }

    private let continuation: AsyncStream<BYOKStreamEvent>.Continuation
    private let decoder: any OnDeviceSpeechDecoding
    private let language: String?
    private let livePartials: Bool

    private var segmenter = OnDevicePhraseSegmenter()
    private var jobs: [Job] = []
    private var worker: Task<Void, Never>?
    private var spaceWaiters: [CheckedContinuation<Void, Never>] = []
    private var samplesSincePartial = 0
    private var inputEnded = false
    private var finished = false

    init(decoder: any OnDeviceSpeechDecoding, language: String?, livePartials: Bool) {
        (events, continuation) = AsyncStream.makeStream(of: BYOKStreamEvent.self)
        self.decoder = decoder
        self.language = language
        self.livePartials = livePartials
    }

    func sendAudio(_ pcm: Data) async {
        guard !finished, !inputEnded else { return }
        let samples = OnDeviceTranscriptionSession.floatSamples(fromPCM16LittleEndian: pcm)
        for phrase in segmenter.append(samples) {
            enqueueFinal(phrase)
            samplesSincePartial = 0
        }
        samplesSincePartial += samples.count
        if livePartials, jobs.isEmpty, worker == nil,
           samplesSincePartial >= Self.partialStrideSamples {
            let current = segmenter.current
            if current.count >= Self.minPartialSamples, !OnDevicePhraseSegmenter.isSilent(current) {
                samplesSincePartial = 0
                jobs.append(.partial(current))
                startWorker()
            }
        }
        while !finished, waitingFinals >= Self.maxWaitingPhrases {
            await withCheckedContinuation { spaceWaiters.append($0) }
        }
    }

    func endInput() async {
        guard !finished, !inputEnded else { return }
        inputEnded = true
        if let rest = segmenter.finish() { enqueueFinal(rest) }
        if worker == nil { finish(with: .done("")) }
    }

    func close() async {
        worker?.cancel()
        worker = nil
        jobs = []
        finish(with: nil)
    }

    private var waitingFinals: Int {
        jobs.reduce(0) { count, job in
            if case .final = job { return count + 1 }
            return count
        }
    }

    private func enqueueFinal(_ phrase: [Float]) {
        guard !OnDevicePhraseSegmenter.isSilent(phrase) else { return }
        // Parakeet rejects under 0.3 s. A short tail (left after a length
        // cut, or at the end of the stream) is padded with silence instead of
        // being dropped: it can still hold the end of a word.
        var padded = phrase
        if padded.count < Self.minFinalSamples {
            padded += [Float](repeating: 0, count: Self.minFinalSamples - padded.count)
        }
        jobs.append(.final(padded))
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, !finished else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while !jobs.isEmpty, !finished, !Task.isCancelled {
            let job = jobs.removeFirst()
            if case .final = job { resumeWaiters() }
            switch job {
            case .final(let samples):
                do {
                    let text = try await decoder.decode(samples: samples, language: language)
                    guard !finished else { return }
                    if !text.isEmpty {
                        continuation.yield(.final(text))
                    } else if livePartials {
                        // Nothing in the phrase after all: clear its live text.
                        continuation.yield(.partial(""))
                    }
                } catch {
                    guard !finished, !Task.isCancelled else { return }
                    os_log("on-device stream decode failed", log: Self.log, type: .error)
                    finish(with: .error("On this Mac could not transcribe the audio."))
                    return
                }
            case .partial(let samples):
                // A failed preview is only a missing preview: the phrase's
                // final still decodes (and reports a real failure itself).
                guard let text = try? await decoder.decode(samples: samples, language: language) else { continue }
                // A final queued meanwhile supersedes this partial.
                guard !finished, waitingFinals == 0 else { continue }
                continuation.yield(.partial(text))
            }
        }
        worker = nil
        if inputEnded, jobs.isEmpty { finish(with: .done("")) }
    }

    private func resumeWaiters() {
        let waiters = spaceWaiters
        spaceWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func finish(with event: BYOKStreamEvent?) {
        guard !finished else { return }
        finished = true
        if let event { continuation.yield(event) }
        continuation.finish()
        resumeWaiters()
    }
}
