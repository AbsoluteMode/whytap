import Foundation
import XCTest
@testable import Sidekey

/// Stage 5b: the fully on-device meeting processor. Drives the pipeline
/// (transcribe → diarize → align → summarize) over injected seams and writes
/// the diarized note + transcript into the store, all without touching the
/// meetings backend. Also verifies the model-store eviction sequencing that
/// keeps peak memory bounded.
@MainActor
final class MeetingLocalProcessorTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-processor-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Seams

    private final class FakeTranscriber: MeetingLocalTranscribing, @unchecked Sendable {
        let transcript: MeetingLocalTranscript
        init(_ t: MeetingLocalTranscript) { transcript = t }
        func transcribe(tracks: MeetingRecorder.SeparateTrackURLs) async throws -> MeetingLocalTranscript {
            transcript
        }
    }

    private final class FakeDiarizer: MeetingSystemDiarizing, @unchecked Sendable {
        let turns: [SpeakerTurn]
        private(set) var sampleCallCount = 0
        init(_ turns: [SpeakerTurn]) { self.turns = turns }
        func diarizeSystemTrack(_ url: URL) async throws -> [SpeakerTurn] {
            sampleCallCount += 1
            return turns
        }
    }

    private final class FakeLLM: LocalLLMCompleting, @unchecked Sendable {
        private(set) var prompts: [(system: String, user: String)] = []
        let reply: String
        init(reply: String = "<!-- protocol:v1 -->\n# Local Meeting\n\nSummary.") {
            self.reply = reply
        }
        func complete(system: String, user: String) async throws -> String {
            prompts.append((system, user))
            return reply
        }
    }

    /// Spy over a model store's evict() — tracks call order via a shared log.
    private final class EvictionLog: @unchecked Sendable {
        private(set) var order: [String] = []
        func record(_ stage: String) { order.append(stage) }
    }

    private final class SpyEvictable: MeetingLocalModelEvicting, @unchecked Sendable {
        let name: String
        let log: EvictionLog
        init(name: String, log: EvictionLog) { self.name = name; self.log = log }
        func evict() async { log.record(name) }
    }

    /// Mirror the real recorder layout: the raw tracks live in a per-meeting
    /// staging subdirectory (`stagingRoot/<meetingId>`), kept SEPARATE from the
    /// store so cleanup of the staging dir never touches the store DB.
    private func makeTracks() throws -> MeetingRecorder.SeparateTrackURLs {
        let stagingDir = tempRoot
            .appendingPathComponent("staging")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let micURL = stagingDir.appendingPathComponent("mic.wav")
        let systemURL = stagingDir.appendingPathComponent("system.wav")
        try Data([0x01]).write(to: micURL)
        try Data([0x01]).write(to: systemURL)
        return MeetingRecorder.SeparateTrackURLs(micURL: micURL, systemURL: systemURL)
    }

    private func makeStore() throws -> MeetingsStore {
        try MeetingsStore(rootDirectory: tempRoot.appendingPathComponent("store"))
    }

    // MARK: - Tests

    func test_process_writesDiarizedTranscriptAndNote_meAndSpeakerN() async throws {
        let transcript = MeetingLocalTranscript(
            mic: [MeetingASRSegment(text: "hello team", start: 0, end: 1)],
            system: [MeetingASRSegment(text: "hi back", start: 2, end: 3)],
            systemTokens: [
                MeetingASRToken(text: " hi", start: 2.0, end: 2.4),
                MeetingASRToken(text: " back", start: 2.5, end: 3.0),
            ]
        )
        let diarizer = FakeDiarizer([SpeakerTurn(speaker: "raw_a", start: 1.8, end: 3.2)])
        let llm = FakeLLM()
        let store = try makeStore()

        let processor = MeetingLocalProcessor(
            transcriber: FakeTranscriber(transcript),
            diarizer: diarizer,
            llm: llm,
            transcriptionStore: SpyEvictable(name: "stt", log: EvictionLog()),
            diarizerStore: SpyEvictable(name: "diar", log: EvictionLog()),
            llmStore: SpyEvictable(name: "llm", log: EvictionLog())
        )

        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(),
            chunkURLs: [],
            totalDurationSeconds: 3.0,
            reason: .user,
            separateTrackURLs: try makeTracks()
        )

        let id = try await processor.process(
            event: event,
            startedAt: Date(),
            language: nil,
            meetingsStore: store
        )

        let segments = try await store.transcript(id: id)
        XCTAssertEqual(segments?.map(\.speaker), ["Me", "Speaker 1"])
        XCTAssertEqual(segments?.map(\.text), ["hello team", "hi back"])

        let markdown = try await store.markdown(id: id)
        XCTAssertTrue(markdown?.contains("Local Meeting") == true)

        // The speaker-aware prompt must mention who said what (the transcript
        // fed to the LLM carries the Me / Speaker labels).
        let userPrompt = try XCTUnwrap(llm.prompts.first?.user)
        XCTAssertTrue(userPrompt.contains("Me"), "summary prompt should be speaker-aware")
        XCTAssertTrue(userPrompt.contains("Speaker 1"))
    }

    func test_process_evictsModelsSerially_transcribeThenDiarizeThenLLM() async throws {
        let log = EvictionLog()
        let transcript = MeetingLocalTranscript(
            mic: [MeetingASRSegment(text: "a", start: 0, end: 1)],
            system: [MeetingASRSegment(text: "b", start: 1, end: 2)],
            systemTokens: [MeetingASRToken(text: " b", start: 1.0, end: 2.0)]
        )
        let store = try makeStore()

        let processor = MeetingLocalProcessor(
            transcriber: FakeTranscriber(transcript),
            diarizer: FakeDiarizer([SpeakerTurn(speaker: "x", start: 1, end: 2)]),
            llm: FakeLLM(),
            transcriptionStore: SpyEvictable(name: "stt", log: log),
            diarizerStore: SpyEvictable(name: "diar", log: log),
            llmStore: SpyEvictable(name: "llm", log: log)
        )

        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(),
            chunkURLs: [],
            totalDurationSeconds: 2.0,
            reason: .user,
            separateTrackURLs: try makeTracks()
        )

        _ = try await processor.process(
            event: event, startedAt: Date(), language: nil, meetingsStore: store
        )

        // Parakeet is freed before the diarizer loads; the diarizer is freed
        // before the LLM loads. Order is the whole point of the serialization.
        XCTAssertEqual(log.order, ["stt", "diar", "llm"])
    }

    func test_process_mapReduce_chunksLongTranscript() async throws {
        // Build a transcript whose rendered form far exceeds the chunk
        // threshold so map-reduce kicks in. Many system tokens re-segment into
        // many per-turn segments: each 4-token group falls in its own diarizer
        // turn, alternating speakers, so the rendered diarized transcript is
        // long enough (many "**Speaker N [..]:** …" blocks) to chunk.
        let groupCount = 400
        let tokensPerGroup = 4
        var manyTokens: [MeetingASRToken] = []
        var turns: [SpeakerTurn] = []
        for g in 0..<groupCount {
            let groupStart = Double(g) * 2.0
            for t in 0..<tokensPerGroup {
                let s = groupStart + Double(t) * 0.4
                manyTokens.append(
                    MeetingASRToken(
                        text: " reasonablylongword\(g)x\(t)",
                        start: s,
                        end: s + 0.3
                    )
                )
            }
            // Alternate speakers per group so runs do not merge.
            turns.append(SpeakerTurn(speaker: g % 2 == 0 ? "alpha" : "bravo",
                                     start: groupStart - 0.05,
                                     end: groupStart + 2.0 - 0.1))
        }
        let transcript = MeetingLocalTranscript(mic: [], system: [], systemTokens: manyTokens)
        let llm = FakeLLM()
        let store = try makeStore()

        let processor = MeetingLocalProcessor(
            transcriber: FakeTranscriber(transcript),
            diarizer: FakeDiarizer(turns),
            llm: llm,
            transcriptionStore: SpyEvictable(name: "stt", log: EvictionLog()),
            diarizerStore: SpyEvictable(name: "diar", log: EvictionLog()),
            llmStore: SpyEvictable(name: "llm", log: EvictionLog())
        )

        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(),
            chunkURLs: [],
            totalDurationSeconds: 800,
            reason: .user,
            separateTrackURLs: try makeTracks()
        )

        _ = try await processor.process(
            event: event, startedAt: Date(), language: nil, meetingsStore: store
        )

        // Map-reduce → more than one LLM call (>=2 partials + 1 reduce).
        XCTAssertGreaterThan(llm.prompts.count, 1, "long transcript should trigger map-reduce")
    }

    func test_process_shortTranscript_singleLLMCall() async throws {
        let transcript = MeetingLocalTranscript(
            mic: [MeetingASRSegment(text: "quick sync done", start: 0, end: 2)],
            system: []
        )
        let llm = FakeLLM()
        let store = try makeStore()

        let processor = MeetingLocalProcessor(
            transcriber: FakeTranscriber(transcript),
            diarizer: FakeDiarizer([]),
            llm: llm,
            transcriptionStore: SpyEvictable(name: "stt", log: EvictionLog()),
            diarizerStore: SpyEvictable(name: "diar", log: EvictionLog()),
            llmStore: SpyEvictable(name: "llm", log: EvictionLog())
        )

        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(),
            chunkURLs: [],
            totalDurationSeconds: 2,
            reason: .user,
            separateTrackURLs: try makeTracks()
        )

        _ = try await processor.process(
            event: event, startedAt: Date(), language: nil, meetingsStore: store
        )

        XCTAssertEqual(llm.prompts.count, 1, "short transcript needs a single summary call")
    }

    func test_process_emptyTranscript_throwsNoTranscript() async throws {
        let store = try makeStore()
        let processor = MeetingLocalProcessor(
            transcriber: FakeTranscriber(MeetingLocalTranscript(mic: [], system: [])),
            diarizer: FakeDiarizer([]),
            llm: FakeLLM(),
            transcriptionStore: SpyEvictable(name: "stt", log: EvictionLog()),
            diarizerStore: SpyEvictable(name: "diar", log: EvictionLog()),
            llmStore: SpyEvictable(name: "llm", log: EvictionLog())
        )

        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(),
            chunkURLs: [],
            totalDurationSeconds: 0,
            reason: .user,
            separateTrackURLs: try makeTracks()
        )

        do {
            _ = try await processor.process(
                event: event, startedAt: Date(), language: nil, meetingsStore: store
            )
            XCTFail("expected empty transcript to throw")
        } catch {
            // expected — nothing was said on either track.
        }
    }

    // MARK: - FIX 2: failure-safe eviction

    private struct StageError: Error {}

    private final class ThrowingTranscriber: MeetingLocalTranscribing, @unchecked Sendable {
        func transcribe(tracks: MeetingRecorder.SeparateTrackURLs) async throws -> MeetingLocalTranscript {
            throw StageError()
        }
    }

    private final class ThrowingDiarizer: MeetingSystemDiarizing, @unchecked Sendable {
        func diarizeSystemTrack(_ url: URL) async throws -> [SpeakerTurn] {
            throw StageError()
        }
    }

    private final class ThrowingLLM: LocalLLMCompleting, @unchecked Sendable {
        func complete(system: String, user: String) async throws -> String {
            throw StageError()
        }
    }

    func test_evictsTranscriptionStore_whenTranscribeThrows() async throws {
        let log = EvictionLog()
        let store = try makeStore()
        let processor = MeetingLocalProcessor(
            transcriber: ThrowingTranscriber(),
            diarizer: FakeDiarizer([]),
            llm: FakeLLM(),
            transcriptionStore: SpyEvictable(name: "stt", log: log),
            diarizerStore: SpyEvictable(name: "diar", log: log),
            llmStore: SpyEvictable(name: "llm", log: log)
        )
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [], totalDurationSeconds: 1, reason: .user,
            separateTrackURLs: try makeTracks()
        )

        do {
            _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected transcribe failure to propagate")
        } catch {
            // The Parakeet store MUST be freed even though transcribe threw.
            XCTAssertTrue(log.order.contains("stt"),
                          "transcription store must be evicted on transcribe failure")
        }
    }

    func test_evictsDiarizerStore_whenDiarizeThrows() async throws {
        let log = EvictionLog()
        let store = try makeStore()
        let transcript = MeetingLocalTranscript(
            mic: [MeetingASRSegment(text: "hi", start: 0, end: 1)],
            system: [],
            systemTokens: []
        )
        let processor = MeetingLocalProcessor(
            transcriber: FakeTranscriber(transcript),
            diarizer: ThrowingDiarizer(),
            llm: FakeLLM(),
            transcriptionStore: SpyEvictable(name: "stt", log: log),
            diarizerStore: SpyEvictable(name: "diar", log: log),
            llmStore: SpyEvictable(name: "llm", log: log)
        )
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [], totalDurationSeconds: 1, reason: .user,
            separateTrackURLs: try makeTracks()
        )

        do {
            _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected diarize failure to propagate")
        } catch {
            // Both the (already-run) transcription store AND the diarizer store
            // must be freed even though diarize threw.
            XCTAssertEqual(log.order, ["stt", "diar"],
                           "transcription + diarizer stores must be evicted on diarize failure")
        }
    }

    func test_evictsLLMStore_whenSummaryThrows() async throws {
        let log = EvictionLog()
        let store = try makeStore()
        let transcript = MeetingLocalTranscript(
            mic: [MeetingASRSegment(text: "hi", start: 0, end: 1)],
            system: [],
            systemTokens: []
        )
        let processor = MeetingLocalProcessor(
            transcriber: FakeTranscriber(transcript),
            diarizer: FakeDiarizer([]),
            llm: ThrowingLLM(),
            transcriptionStore: SpyEvictable(name: "stt", log: log),
            diarizerStore: SpyEvictable(name: "diar", log: log),
            llmStore: SpyEvictable(name: "llm", log: log)
        )
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [], totalDurationSeconds: 1, reason: .user,
            separateTrackURLs: try makeTracks()
        )

        do {
            _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected summary failure to propagate")
        } catch {
            XCTAssertEqual(log.order, ["stt", "diar", "llm"],
                           "all three stores must be evicted on summary failure")
        }
    }

    // MARK: - FIX 3: staging audio cleanup

    func test_deletesStagingAudio_onSuccess() async throws {
        let store = try makeStore()
        let tracks = try makeTracks()
        let stagingDir = tracks.micURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracks.micURL.path))

        let transcript = MeetingLocalTranscript(
            mic: [MeetingASRSegment(text: "done", start: 0, end: 1)],
            system: [],
            systemTokens: []
        )
        let processor = MeetingLocalProcessor(
            transcriber: FakeTranscriber(transcript),
            diarizer: FakeDiarizer([]),
            llm: FakeLLM(),
            transcriptionStore: SpyEvictable(name: "stt", log: EvictionLog()),
            diarizerStore: SpyEvictable(name: "diar", log: EvictionLog()),
            llmStore: SpyEvictable(name: "llm", log: EvictionLog())
        )
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [], totalDurationSeconds: 1, reason: .user,
            separateTrackURLs: tracks
        )

        _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tracks.micURL.path),
                       "raw mic.wav must be deleted after the note is stored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracks.systemURL.path),
                       "raw system.wav must be deleted after the note is stored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path),
                       "the staging directory itself must be removed")
    }

    func test_deletesStagingAudio_onFailure() async throws {
        let store = try makeStore()
        let tracks = try makeTracks()
        let stagingDir = tracks.micURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracks.systemURL.path))

        // Diarize throws → the note is never stored, but the raw audio MUST
        // still be wiped (privacy: a failed local meeting must not leave both
        // speakers' un-mixed audio on disk).
        let transcript = MeetingLocalTranscript(
            mic: [MeetingASRSegment(text: "hi", start: 0, end: 1)],
            system: [],
            systemTokens: []
        )
        let processor = MeetingLocalProcessor(
            transcriber: FakeTranscriber(transcript),
            diarizer: ThrowingDiarizer(),
            llm: FakeLLM(),
            transcriptionStore: SpyEvictable(name: "stt", log: EvictionLog()),
            diarizerStore: SpyEvictable(name: "diar", log: EvictionLog()),
            llmStore: SpyEvictable(name: "llm", log: EvictionLog())
        )
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [], totalDurationSeconds: 1, reason: .user,
            separateTrackURLs: tracks
        )

        do {
            _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected diarize failure to propagate")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tracks.micURL.path),
                           "raw mic.wav must be deleted even when a stage throws")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tracks.systemURL.path),
                           "raw system.wav must be deleted even when a stage throws")
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path),
                           "the staging directory must be removed even on failure")
        }
    }
}
