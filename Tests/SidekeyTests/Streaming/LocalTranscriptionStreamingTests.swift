import XCTest
import FluidAudio
@testable import Sidekey

/// Audio source stub for the LOCAL streaming path. Unlike `StubAudioSource`
/// (which discards audio), this one accumulates every emitted chunk into the
/// buffer returned by `capturedPCM16()` — the local session re-decodes a bounded
/// trailing window of that growing buffer to produce live partials, so the stub
/// must grow with each emit to drive growing hypotheses.
final class AccumulatingStubAudioSource: StreamingAudioSourcing, @unchecked Sendable {
    let chunks: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    let failures: AsyncStream<StreamingAudioEngineError>
    private let failuresContinuation: AsyncStream<StreamingAudioEngineError>.Continuation

    private let lock = NSLock()
    private var captured = Data()

    init() {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        self.chunks = stream
        self.continuation = cont
        let (failStream, failCont) = AsyncStream<StreamingAudioEngineError>.makeStream()
        self.failures = failStream
        self.failuresContinuation = failCont
    }

    func start() throws {}

    /// Mirror the real engine: a graceful `finish()` ends the chunk stream
    /// (the real engine reaches `stop()` via its silence gate / failsafe),
    /// so the session's `await drainTask?.value` can complete and proceed to
    /// the final decode. The captured PCM is retained for that final decode.
    func finish() {
        continuation.finish()
    }

    func stop() {
        continuation.finish()
        failuresContinuation.finish()
    }

    func emit(_ data: Data) {
        lock.lock()
        captured.append(data)
        lock.unlock()
        continuation.yield(data)
    }

    func capturedPCM16() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

/// Fake STATELESS decoder: every `decode` call re-derives the transcript purely
/// from the sample COUNT it is handed (one word per `samplesPerWord` samples),
/// mirroring the production `ParakeetLocalASRDecoder`, which runs a fresh
/// `TdtDecoderState` pass per call for BOTH the live partials (a bounded
/// trailing window of the captured buffer) and the on-stop final (the whole
/// buffer). No carried state — a partial can never corrupt the final.
///
/// It RECORDS the sample count of every `decode` call so the test can assert the
/// session feeds the partial path a BOUNDED window (capped at
/// `partialWindowSamples`), never an unbounded O(buffer) re-feed.
final class ScriptedIncrementalASRDecoder: LocalASRDecoding, @unchecked Sendable {
    let script: [String]
    let samplesPerWord: Int

    private let lock = NSLock()
    private(set) var partialSliceSizes: [Int] = []

    init(script: [String], samplesPerWord: Int) {
        self.script = script
        self.samplesPerWord = samplesPerWord
    }

    /// Stateless decode over whatever samples are handed — used for both the
    /// windowed partials and the full-buffer final. Reveals one word per
    /// `samplesPerWord` samples (clamped to the script), so a growing buffer
    /// yields a monotonically growing transcript.
    func decode(samples: [Float], language: Language?) async throws -> String {
        lock.lock()
        partialSliceSizes.append(samples.count)
        lock.unlock()
        let revealed = min(script.count, samples.count / samplesPerWord)
        guard revealed > 0 else { return "" }
        return script.prefix(revealed).joined(separator: " ")
    }

    /// Sample counts of every `decode` call (partials + final). The last entry
    /// is the on-stop full-buffer final; the preceding entries are the windowed
    /// partials.
    var sliceSizes: [Int] {
        lock.lock(); defer { lock.unlock() }
        return partialSliceSizes
    }
}

@MainActor
final class LocalTranscriptionStreamingTests: XCTestCase {
    /// One ~120 ms chunk worth of PCM16 bytes (1920 samples × 2 bytes). The
    /// production engine yields chunks this size; matching it keeps the
    /// byte-stride arithmetic realistic.
    private static let chunkBytes = 1920 * 2

    private func makeChunk() -> Data {
        // Non-zero bytes so `floatSamples` produces a full-length sample array
        // (the decoder only looks at the COUNT, not the values).
        Data(repeating: 0x10, count: Self.chunkBytes)
    }

    func testEmitsGrowingPartialsDuringRecordingThenFinal() async throws {
        let audio = AccumulatingStubAudioSource()
        let script = ["the", "quick", "brown", "fox", "jumps"]
        // 1920 samples/chunk → reveal one word every ~2 chunks of audio.
        let decoder = ScriptedIncrementalASRDecoder(script: script, samplesPerWord: 1920 * 2)

        let session = LocalTranscriptionSession(
            audioEngine: audio,
            decoder: decoder,
            language: "en-US"
        )

        let collector = TranscriptCollector()
        session.onTranscriptUpdate = { text in collector.append(text) }

        let runTask = Task { await session.run() }

        // Feed enough chunks to reveal the whole script, then stop. A tiny
        // yield between emits lets the drain loop's partial decode run.
        for _ in 0..<20 {
            audio.emit(makeChunk())
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)  // 1 ms
        }

        await session.stop()
        let result = await runTask.value

        let updates = collector.snapshot()

        // Multiple partial emissions during recording (more than just the
        // single final emit the batch-only path produced).
        XCTAssertGreaterThan(updates.count, 1, "expected live partials, got: \(updates)")

        // Monotonic growth in word count — text never shrinks across updates.
        let wordCounts = updates.map { $0.split(separator: " ").count }
        for (prev, next) in zip(wordCounts, wordCounts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next, prev, "transcript shrank across updates: \(updates)")
        }

        // Final emitted update AND the returned transcript are the full text.
        let expectedFull = script.joined(separator: " ")
        XCTAssertEqual(updates.last, expectedFull)
        if case let .transcript(text) = result {
            XCTAssertEqual(text, expectedFull)
        } else {
            XCTFail("expected .transcript, got \(result)")
        }
    }

    func testFinalTranscriptMatchesBatchDecodeOfFullAudio() async throws {
        let audio = AccumulatingStubAudioSource()
        let script = ["alpha", "beta", "gamma"]
        let decoder = ScriptedIncrementalASRDecoder(script: script, samplesPerWord: 1920 * 2)

        let session = LocalTranscriptionSession(
            audioEngine: audio,
            decoder: decoder,
            language: nil
        )
        let collector = TranscriptCollector()
        session.onTranscriptUpdate = { text in collector.append(text) }

        let runTask = Task { await session.run() }
        for _ in 0..<12 {
            audio.emit(makeChunk())
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await session.stop()
        let result = await runTask.value

        // The authoritative final equals a clean batch decode over the full
        // captured PCM (same decoder, fresh state) — partials never corrupt it.
        let fullSamples = LocalTranscriptionSession.floatSamples(
            fromPCM16LittleEndian: audio.capturedPCM16()
        )
        let expected = try await decoder.decode(samples: fullSamples, language: nil)

        guard case let .transcript(text) = result else {
            return XCTFail("expected .transcript, got \(result)")
        }
        XCTAssertEqual(text, expected)
    }

    /// Regression guard for the perf bug (ROO-257): partial decoding must be
    /// BOUNDED. Each live partial re-decodes only a fixed trailing window of the
    /// captured buffer (`partialWindowSamples`, ~14 s), never the whole growing
    /// buffer — so per-tick decode cost stays constant instead of growing
    /// O(buffer) (the original full-buffer re-decode that pegged a core and fell
    /// ~6 s behind speech). This feeds well past the window cap and asserts the
    /// fed size plateaus at the cap rather than tracking the (larger) buffer.
    func testPartialDecodeFeedsBoundedWindowNotWholeBuffer() async throws {
        let audio = AccumulatingStubAudioSource()
        let script = (1...400).map { "w\($0)" }
        let decoder = ScriptedIncrementalASRDecoder(script: script, samplesPerWord: 1920)

        let session = LocalTranscriptionSession(
            audioEngine: audio,
            decoder: decoder,
            language: nil
        )
        let runTask = Task { await session.run() }
        // Feed enough audio to exceed the trailing-window cap. One chunk =
        // 1920 samples; the window is `partialWindowSamples` (~116_667 samples
        // worth of chunks). 160 chunks ≈ 307_200 samples > the cap, so late
        // partials must plateau at the cap, not track the growing buffer.
        let windowCap = LocalTranscriptionSession.partialWindowSamples
        let chunksToExceedWindow = (windowCap / 1920) + 40
        for _ in 0..<chunksToExceedWindow {
            audio.emit(makeChunk())
            await Task.yield()
        }
        await session.stop()
        _ = await runTask.value

        let slices = decoder.sliceSizes
        XCTAssertGreaterThan(slices.count, 1, "expected multiple partial decodes")

        // The on-stop final (last entry) re-decodes the WHOLE buffer and is
        // legitimately larger than the window; every PARTIAL (all preceding
        // entries) must be capped at the trailing window so cost never grows
        // O(buffer). A capped partial is exactly `windowCap`; a regressed
        // O(buffer) partial would exceed it once the buffer passes the cap.
        let partials = slices.dropLast()
        XCTAssertFalse(partials.isEmpty, "expected at least one partial decode")
        for size in partials {
            XCTAssertLessThanOrEqual(
                size, windowCap,
                "partial decode fed \(size) samples — expected a bounded trailing window (\(windowCap)), not the whole buffer"
            )
        }
        // And at least one late partial actually reached the cap (proves the
        // window is being applied, not that the buffer just never got big).
        XCTAssertEqual(
            partials.max(), windowCap,
            "no partial reached the window cap — the trailing-window slice isn't being applied"
        )
    }

    /// Regression guard for the island FREEZE (ROO-257 follow-up): once the
    /// trailing window saturates, the windowed transcript SCROLLS rather than
    /// grows — newer text is shorter-or-equal in length than the longest text
    /// seen. The old `trimmed.count >= lastEmittedPartial.count` length-monotonic
    /// guard blocked every such partial, freezing the island at the longest text
    /// ("after a certain number of words it stops writing"). The island is a
    /// trailing-window ticker; it MUST keep updating on CHANGE after the window
    /// fills. This drives a sliding-window decoder past the cap and asserts the
    /// island keeps receiving distinct updates from the saturated regime.
    func testIslandKeepsUpdatingAfterWindowFillsDoesNotFreeze() async throws {
        let audio = AccumulatingStubAudioSource()
        // Long script of FIXED-WIDTH tokens so every same-word-count slice has
        // identical character length (no digit-width drift in the char-count
        // comparison the old guard used). Long enough to slide for many ticks.
        let script = (1...80).map { String(format: "word%03d", $0) }
        let windowCap = LocalTranscriptionSession.partialWindowSamples
        // Saturated window (10 words) is narrower than the pre-saturation peak
        // (12 words), so every saturated slice is strictly shorter than the peak
        // — the old `count >=` guard freezes the island at the peak.
        let decoder = SlidingWindowASRDecoder(
            script: script,
            samplesPerWord: 1920,
            windowWords: 10,
            peakWords: 12,
            saturationSamples: windowCap
        )

        let session = LocalTranscriptionSession(
            audioEngine: audio,
            decoder: decoder,
            language: nil
        )
        let collector = TranscriptCollector()
        session.onTranscriptUpdate = { text in collector.append(text) }

        let runTask = Task { await session.run() }
        // Feed well past the window cap so many partials run in the SATURATED
        // (scrolling, non-growing) regime — the exact regime that froze before.
        let chunksToExceedWindow = (windowCap / 1920) + 60
        for _ in 0..<chunksToExceedWindow {
            audio.emit(makeChunk())
            await Task.yield()
        }
        await session.stop()
        _ = await runTask.value

        // Partials the SATURATED window produced (constant length, sliding
        // offset). The decoder records every text it returned; the saturated
        // ones are the fixed-width slices that scroll.
        let decoderTexts = decoder.texts
        let saturatedTexts = decoderTexts.filter {
            $0.split(separator: " ").count == decoder.windowWords
        }
        XCTAssertGreaterThan(
            saturatedTexts.count, 1,
            "test did not exercise the saturated/scrolling regime: \(decoderTexts)"
        )
        // The saturated window scrolls, so successive saturated texts DIFFER but
        // do NOT grow in length — the precise shape the old length-guard froze on.
        XCTAssertNotEqual(
            saturatedTexts.first, saturatedTexts.last,
            "saturated window did not scroll — test is not exercising the freeze regime"
        )

        // THE ACTUAL ASSERTION: the island received UPDATES from the saturated,
        // non-growing regime. Under the old `count >=` guard the island would
        // freeze at the longest pre-saturation text and these updates would all
        // be dropped. Emit-on-change must forward them.
        let updates = collector.snapshot()
        let saturatedUpdates = updates.filter {
            $0.split(separator: " ").count == decoder.windowWords
        }
        XCTAssertGreaterThan(
            saturatedUpdates.count, 1,
            "island FROZE: no scrolling-window updates were forwarded after the window filled — updates: \(updates)"
        )
        // The island advanced — distinct scrolling text reached it, not a single
        // frozen frame repeated.
        XCTAssertGreaterThan(
            Set(saturatedUpdates).count, 1,
            "island received only one distinct saturated frame — it froze"
        )
    }

    /// Stopping the session must tear the drain loop down: no partial decode
    /// may run after stop resolves. A leaked decode task spinning post-stop is
    /// the persistent-lag symptom (the app staying laggy AFTER a dictation).
    func testNoPartialDecodeRunsAfterStop() async throws {
        let audio = AccumulatingStubAudioSource()
        let script = ["a", "b", "c"]
        let decoder = ScriptedIncrementalASRDecoder(script: script, samplesPerWord: 1920 * 2)

        let session = LocalTranscriptionSession(
            audioEngine: audio,
            decoder: decoder,
            language: nil
        )
        let runTask = Task { await session.run() }
        for _ in 0..<6 {
            audio.emit(makeChunk())
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await session.stop()
        _ = await runTask.value

        let countAtStop = decoder.sliceSizes.count
        // Emitting after stop must be inert — the drain loop is gone.
        audio.emit(makeChunk())
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(
            decoder.sliceSizes.count, countAtStop,
            "a partial decode ran after stop — drain loop was not torn down"
        )
    }
}

/// Fake decoder that mimics the PRODUCTION sliding-window behaviour: once the
/// fed window saturates at the cap, the trailing-window transcript STOPS growing
/// in length and instead SCROLLS — older words fall off the front as newer words
/// appear at the back. This is exactly the regime the length-monotonic guard
/// broke (ROO-257 follow-up): a scrolling window yields shorter-or-equal text
/// every tick, so a `count >= lastCount` guard would freeze the island at the
/// longest text ever seen. The fix emits on CHANGE, so partials must keep
/// flowing after the window fills.
///
/// Model: the visible transcript is a SLICE of the script that SLIDES forward as
/// the buffer grows. The session feeds the partial path a fixed-size trailing
/// window once the buffer exceeds the cap, so per-tick sample count can't
/// distinguish ticks — the scroll is driven by a per-call counter that advances
/// only while the fed window is saturated (`samples.count >= saturationSamples`).
///
/// Two regimes, mirroring production:
///  - PRE-saturation: the window grows from the start of the script (so early
///    partials still GROW in length), peaking at `peakWords` words.
///  - POST-saturation: the slice narrows to `windowWords` (< `peakWords`) and
///    SLIDES forward one word per tick. Because each saturated slice is STRICTLY
///    SHORTER (in characters) than the pre-saturation peak AND differs from its
///    predecessor, the old `count >= lastCount` length-guard freezes the island
///    at the peak and drops every saturated update. Fixed-width zero-padded word
///    tokens make all saturated slices identical in character length, so the
///    char-count comparison is deterministic (no digit-width drift).
final class SlidingWindowASRDecoder: LocalASRDecoding, @unchecked Sendable {
    let script: [String]
    let samplesPerWord: Int
    /// Width of the saturated, scrolling window (in words).
    let windowWords: Int
    /// Width the window reaches just before saturating (> `windowWords`), so
    /// every saturated slice is strictly shorter than the pre-saturation peak.
    let peakWords: Int
    let saturationSamples: Int

    private let lock = NSLock()
    private var saturatedTicks = 0
    private(set) var emittedTexts: [String] = []

    init(script: [String], samplesPerWord: Int, windowWords: Int, peakWords: Int, saturationSamples: Int) {
        self.script = script
        self.samplesPerWord = samplesPerWord
        self.windowWords = windowWords
        self.peakWords = peakWords
        self.saturationSamples = saturationSamples
    }

    func decode(samples: [Float], language: Language?) async throws -> String {
        lock.lock()
        let saturated = samples.count >= saturationSamples
        let offset: Int
        let length: Int
        if saturated {
            // Window full: NARROWER constant length, sliding offset — text both
            // shrinks (vs the peak) and changes, the precise shape that froze
            // the island under the old length-monotonic guard.
            offset = min(saturatedTicks, max(0, script.count - windowWords))
            length = min(windowWords, script.count - offset)
            saturatedTicks += 1
        } else {
            // Pre-saturation: window grows from the start of the script up to
            // the peak width.
            offset = 0
            length = min(max(samples.count / samplesPerWord, 0), peakWords, script.count)
        }
        let text = length > 0 ? script[offset..<(offset + length)].joined(separator: " ") : ""
        emittedTexts.append(text)
        lock.unlock()
        return text
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return emittedTexts
    }
}

/// Thread-safe sink for `onTranscriptUpdate` callbacks. The callback fires on
/// the main actor, but the test reads on the main actor too; the lock guards
/// against any future off-main delivery and keeps the intent explicit.
private final class TranscriptCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ text: String) {
        lock.lock()
        values.append(text)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
