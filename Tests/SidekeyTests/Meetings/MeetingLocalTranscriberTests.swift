import XCTest
import FluidAudio
@testable import Sidekey

final class MeetingLocalTranscriberTests: XCTestCase {

    /// Spy engine: records every `transcribe` call (so we can prove the
    /// mic and system tracks are transcribed SEPARATELY) and returns a
    /// canned `ASRResult` keyed by the first sample value so each track
    /// gets distinct text/timings.
    private actor SpyASREngine: MeetingASRTranscribing {
        struct Call: Sendable, Equatable {
            let sampleCount: Int
            let firstSample: Float
            let language: Language?
        }

        private(set) var calls: [Call] = []
        private let resultsByFirstSample: [Float: ASRResult]
        private let failure: Error?

        init(resultsByFirstSample: [Float: ASRResult], failure: Error? = nil) {
            self.resultsByFirstSample = resultsByFirstSample
            self.failure = failure
        }

        func transcribe(samples: [Float], language: Language?) async throws -> ASRResult {
            calls.append(
                Call(
                    sampleCount: samples.count,
                    firstSample: samples.first ?? 0,
                    language: language
                )
            )
            if let failure { throw failure }
            return resultsByFirstSample[samples.first ?? 0]
                ?? ASRResult(
                    text: "",
                    confidence: 1,
                    duration: 0,
                    processingTime: 0,
                    tokenTimings: nil
                )
        }

        func recordedCalls() -> [Call] { calls }
    }

    private func tokenTimings(
        words: [(String, Double, Double)]
    ) -> [TokenTiming] {
        words.enumerated().map { idx, w in
            TokenTiming(
                token: w.0,
                tokenId: idx,
                startTime: w.1,
                endTime: w.2,
                confidence: 1
            )
        }
    }

    func test_transcribesMicAndSystemTracksSeparately() async throws {
        // Distinct first sample per track so the spy can hand back
        // distinct results, and we can assert each track was sent on its
        // own transcribe call.
        let micSamples: [Float] = [0.5, 0.5, 0.5]
        let systemSamples: [Float] = [-0.5, -0.5, -0.5, -0.5]

        let micResult = ASRResult(
            text: "hello from mic",
            confidence: 1,
            duration: 1.5,
            processingTime: 0.1,
            tokenTimings: tokenTimings(words: [
                ("hello", 0.2, 0.6),
                ("mic", 0.9, 1.4),
            ])
        )
        let systemResult = ASRResult(
            text: "reply from system",
            confidence: 1,
            duration: 2.0,
            processingTime: 0.1,
            tokenTimings: tokenTimings(words: [
                ("reply", 0.3, 0.7),
                ("system", 1.1, 1.9),
            ])
        )

        let engine = SpyASREngine(resultsByFirstSample: [
            0.5: micResult,
            -0.5: systemResult,
        ])

        let transcriber = MeetingLocalTranscriber(engine: engine, language: .english)
        let transcript = try await transcriber.transcribe(
            micSamples: micSamples,
            systemSamples: systemSamples
        )

        // Per-track segments are non-empty with timecodes, kept separate.
        XCTAssertFalse(transcript.mic.isEmpty, "mic track should yield ASR segments")
        XCTAssertFalse(transcript.system.isEmpty, "system track should yield ASR segments")

        XCTAssertEqual(transcript.mic.first?.text, "hello from mic")
        XCTAssertEqual(transcript.mic.first?.start ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(transcript.mic.first?.end ?? -1, 1.4, accuracy: 0.0001)

        XCTAssertEqual(transcript.system.first?.text, "reply from system")
        XCTAssertEqual(transcript.system.first?.start ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(transcript.system.first?.end ?? -1, 1.9, accuracy: 0.0001)

        // The two tracks must be transcribed on SEPARATE engine calls —
        // mic and system never mixed into one buffer.
        let calls = await engine.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.contains(where: { $0.firstSample == 0.5 && $0.sampleCount == 3 }))
        XCTAssertTrue(calls.contains(where: { $0.firstSample == -0.5 && $0.sampleCount == 4 }))
        XCTAssertEqual(calls.map { $0.language }, [.english, .english])
    }

    func test_emptyTrackYieldsNoSegmentsButOtherTrackStillTranscribed() async throws {
        let systemSamples: [Float] = [-0.5, -0.5]
        let systemResult = ASRResult(
            text: "only system audio",
            confidence: 1,
            duration: 1.0,
            processingTime: 0.1,
            tokenTimings: tokenTimings(words: [("only", 0.1, 0.5)])
        )
        let engine = SpyASREngine(resultsByFirstSample: [-0.5: systemResult])

        let transcriber = MeetingLocalTranscriber(engine: engine, language: nil)
        let transcript = try await transcriber.transcribe(
            micSamples: [],
            systemSamples: systemSamples
        )

        XCTAssertTrue(transcript.mic.isEmpty, "empty mic track yields no segments")
        XCTAssertEqual(transcript.system.first?.text, "only system audio")

        // The empty track must NOT hit the engine at all.
        let calls = await engine.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.firstSample, -0.5)
    }

    func test_blankTranscriptResultProducesNoSegments() async throws {
        let micResult = ASRResult(
            text: "   ",
            confidence: 1,
            duration: 1.0,
            processingTime: 0.1,
            tokenTimings: nil
        )
        let engine = SpyASREngine(resultsByFirstSample: [0.5: micResult])

        let transcriber = MeetingLocalTranscriber(engine: engine, language: nil)
        let transcript = try await transcriber.transcribe(
            micSamples: [0.5],
            systemSamples: []
        )

        XCTAssertTrue(transcript.mic.isEmpty, "whitespace-only ASR text yields no segment")
        XCTAssertTrue(transcript.system.isEmpty)
    }

    func test_missingTimingsFallsBackToZeroToDurationSpan() async throws {
        let micResult = ASRResult(
            text: "no timings here",
            confidence: 1,
            duration: 3.25,
            processingTime: 0.1,
            tokenTimings: nil
        )
        let engine = SpyASREngine(resultsByFirstSample: [0.5: micResult])

        let transcriber = MeetingLocalTranscriber(engine: engine, language: nil)
        let transcript = try await transcriber.transcribe(
            micSamples: [0.5, 0.5],
            systemSamples: []
        )

        let segment = try XCTUnwrap(transcript.mic.first)
        XCTAssertEqual(segment.text, "no timings here")
        XCTAssertEqual(segment.start, 0, accuracy: 0.0001)
        XCTAssertEqual(segment.end, 3.25, accuracy: 0.0001)
    }
}
