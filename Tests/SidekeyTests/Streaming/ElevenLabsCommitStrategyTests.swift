import Foundation
import XCTest
@testable import Sidekey

/// ElevenLabs' VAD commit strategy, which the retired Subtitles Speech route
/// used. The adapter code stays (shared adapter); Subtitles now run only on
/// Audio translate.
final class ElevenLabsCommitStrategyTests: XCTestCase {
    func testSubtitlesAskElevenLabsToCommitAtPausesAndTakesStayManual() throws {
        func items(_ url: URL) -> [String: String] {
            Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }
        let subtitles = items(ElevenLabsRealtimeURL.make(model: "scribe_v3_live", language: "en", terms: [],
                                                          commit: .subtitles))
        XCTAssertEqual(subtitles["commit_strategy"], "vad")
        XCTAssertEqual(subtitles["vad_silence_threshold_secs"], "0.5")
        XCTAssertEqual(subtitles["no_verbatim"], "true")
        let take = items(ElevenLabsRealtimeURL.make(model: "scribe_v3_live", language: "en", terms: []))
        XCTAssertEqual(take["commit_strategy"], "manual")
        XCTAssertNil(take["vad_silence_threshold_secs"])

        func adapter(_ feature: AIFeature) throws -> ElevenLabsBYOKAdapter {
            let route = ResolvedRoute(feature: feature, account: .elevenLabs, model: "scribe_v3_live",
                                      apiKey: "test-key", server: nil)
            return try XCTUnwrap(RealtimeAdapterFactory.make(route) as? ElevenLabsBYOKAdapter)
        }
        XCTAssertEqual(try adapter(.subtitlesAudio).commit, .subtitles)
        for feature: AIFeature in [.dropFast, .dropSmart, .agentVoice, .voiceSearch, .meetings] {
            XCTAssertEqual(try adapter(feature).commit, .manual, "\(feature)")
        }
    }

    func testVADSessionEndsWithSilenceLongerThanThePauseThenTheCommit() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v3_live", prerollSilenceMs: 0, previousText: nil,
                                            commit: .subtitles) { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var iterator = session.events.makeAsyncIterator()
        // A VAD commit mid-stream is a phrase, not the end.
        stub.deliverText(#"{"message_type":"committed_transcript","text":"First phrase."}"#)
        let first = await iterator.next()
        XCTAssertEqual(first, .final("First phrase."))
        await session.endInput()
        let chunks = stub.sent.compactMap { frame -> [String: Any]? in
            guard case .text(let text) = frame else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        XCTAssertEqual(chunks.count, 2)
        let silence = Data(base64Encoded: chunks[0]["audio_base_64"] as? String ?? "") ?? Data()
        XCTAssertEqual(chunks[0]["commit"] as? Bool, false)
        XCTAssertGreaterThan(silence.count, 16_000 * 2 / 2, "More than the 0.5 s pause")
        XCTAssertTrue(silence.allSatisfy { $0 == 0 })
        XCTAssertEqual(chunks[1]["commit"] as? Bool, true)
        stub.deliverText(#"{"message_type":"committed_transcript","text":"Tail."}"#)
        let tail = await iterator.next()
        XCTAssertEqual(tail, .final("Tail."))
        let done = await iterator.next()
        XCTAssertEqual(done, .done("First phrase. Tail."))
        await session.close()
    }
}
