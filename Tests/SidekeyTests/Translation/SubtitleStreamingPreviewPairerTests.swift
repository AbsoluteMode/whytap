import Foundation
@testable import Sidekey
import XCTest

/// The pairer for a provider that streams the original before it is final
/// (Soniox): the live row runs on as heard, each translated piece shows whole
/// at once, and only final words ever enter a pair. OpenAI's sessions keep
/// the in-step row.
// WHY: .project-docs/decisions/2026-11-25-subtitle-soniox-live-original.md
final class SubtitleStreamingPreviewPairerTests: XCTestCase {
    func testThePreviewFollowsTheFinalWordsAndEachResponseReplacesIt() {
        var pairer = SubtitleSpeechPairer(streamingPreview: true)
        pairer.setPreview("Wel")
        XCTAssertEqual(pairer.showLive(now: 0).source, "Wel")
        pairer.addSource("Welcome", elapsedMs: 500)
        pairer.setPreview(" back, every")
        XCTAssertEqual(pairer.showLive(now: 0.1).source, "Welcome back, every")
        pairer.setPreview("")
        XCTAssertEqual(pairer.showLive(now: 0.2).source, "Welcome", "a cleared preview leaves the final words")
    }

    func testALateTranslationNeverHoldsTheNextSentenceBack() {
        var pairer = SubtitleSpeechPairer(streamingPreview: true)
        pairer.addSource("First sentence.", elapsedMs: 1_000)
        pairer.addSource(" Second", elapsedMs: 1_600)
        pairer.setPreview(" one is")
        XCTAssertEqual(pairer.showLive(now: 1).source, "First sentence. Second one is")
        pairer.addTranslation("Первое предложение.", elapsedMs: 1_600, now: 2)
        XCTAssertEqual(pairer.take(now: 2.4), [.init(source: "First sentence.", translation: "Первое предложение.")])
        XCTAssertEqual(pairer.showLive(now: 2.4).source, "Second one is",
                       "the words past the cut continue in the next row")
    }

    func testAWholePieceShowsAtOnceAndADeltaWaitsForItsWord() {
        var pairer = SubtitleSpeechPairer(streamingPreview: true)
        pairer.addTranslation("Микрофон превращает звуковые волны", elapsedMs: 900, now: 1, whole: true)
        XCTAssertEqual(pairer.showLive(now: 1).translation, "Микрофон превращает звуковые волны")
        // A target-language original mirrored subword by subword.
        pairer.addTranslation(" и зву", elapsedMs: 1_000, now: 1.1)
        XCTAssertEqual(pairer.showLive(now: 1.1).translation, "Микрофон превращает звуковые волны и",
                       "a delta's last word still waits for its end")
    }

    func testABrokenSessionKeepsTheWholePieceAndDropsAnUnfinishedWord() {
        var pairer = SubtitleSpeechPairer(streamingPreview: true)
        pairer.addSource("Sound waves", elapsedMs: 900)
        pairer.addTranslation("Звуковые волны", elapsedMs: 900, now: 1, whole: true)
        pairer.addSource(" Bon", elapsedMs: 1_100)
        pairer.addTranslation(" Bon", elapsedMs: 1_100, now: 1.1)
        pairer.setPreview("jour")
        pairer.dropUnfinishedWord()
        XCTAssertEqual(pairer.take(now: 1.2, force: true), [.init(source: "Sound waves Bon", translation: "Звуковые волны")],
                       "the whole piece stays, the unfinished subword goes, the preview is not a pair's")
    }

    func testATargetLanguageSubwordAloneNeverSettlesAsAWord() {
        var pairer = SubtitleSpeechPairer(streamingPreview: true)
        pairer.addSource("Bon", elapsedMs: 200)
        pairer.addTranslation("Bon", elapsedMs: 200, now: 1)
        XCTAssertEqual(pairer.showLive(now: 1).translation, "")
        pairer.dropUnfinishedWord()
        XCTAssertEqual(pairer.take(now: 1.2, force: true).map(\.translation), [""])
    }

    func testOpenAISessionsKeepTheOriginalInStepWithItsTranslation() {
        var pairer = SubtitleSpeechPairer()
        XCTAssertFalse(pairer.originalAsHeard)
        pairer.addSource("First sentence.", elapsedMs: 1_000)
        pairer.setPreview(" never sent by OpenAI")
        XCTAssertEqual(pairer.showLive(now: 0).source, "")
    }
}
