import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The recording wing's live text: an even line that never falls far behind,
/// for any provider's delivery pattern.
final class LiveTextTickerTests: XCTestCase {
    private struct Run {
        var longestLag: TimeInterval = 0
        var stoppedFrames = 0
        var fastestStep: Double = 0
        var shownAtEnd: Double = 0
    }

    /// A speaker at `rate` characters per second whose provider delivers what
    /// was said in batches `gap` seconds apart (a quarter second behind), drawn
    /// at 60 frames per second. `silentFrom...silentTo` delivers nothing.
    private func dictate(
        seconds: TimeInterval, rate: Double = 15, gap: (Int) -> TimeInterval,
        silent: ClosedRange<TimeInterval>? = nil, speechEnds: TimeInterval? = nil,
        measureFrom: TimeInterval = 3
    ) -> Run {
        var pacer = LiveTextPacer()
        var run = Run()
        var arrivedAt: [TimeInterval] = []
        var nextBatch = 0.5
        var batch = 0
        let frame = 1.0 / 60
        var now = 0.0
        while now < seconds {
            now += frame
            let spoken = Int(max(0, min(now, speechEnds ?? now) - 0.25) * rate)
            let quiet = silent.map { $0.contains(now) } ?? false
            if now >= nextBatch, !quiet, spoken > arrivedAt.count {
                arrivedAt.append(contentsOf: Array(repeating: now, count: spoken - arrivedAt.count))
                pacer.delivered(count: spoken, now: now)
                batch += 1
                nextBatch = now + gap(batch)
            }
            let before = pacer.shown
            let after = pacer.advance(now: now)
            for index in Int(before)..<Int(after) {
                run.longestLag = max(run.longestLag, now - arrivedAt[index])
            }
            let speaking = speechEnds.map { now < $0 } ?? true
            if now > measureFrom, speaking, !quiet {
                if after - before <= 0 { run.stoppedFrames += 1 }
                run.fastestStep = max(run.fastestStep, (after - before) / frame)
            }
        }
        run.shownAtEnd = pacer.shown
        return run
    }

    // MARK: - An even line

    func testTheLineNeverStopsBetweenBatches() {
        for gap in [0.2, 0.3, 0.5, 0.8] {
            let run = dictate(seconds: 40, gap: { _ in gap })
            XCTAssertEqual(run.stoppedFrames, 0, "stopped with batches every \(gap) s")
        }
    }

    func testTheLineMovesAtTheSpeakersRateNotInBursts() {
        // Shown as delivered, a 0.8 s batch of 12 characters lands in one
        // frame: 720 characters per second. Paced, it stays near speech rate.
        let run = dictate(seconds: 40, gap: { _ in 0.8 })
        XCTAssertLessThan(run.fastestStep, 15 * 1.6)
    }

    func testUnevenBatchesStillMoveEvenly() {
        let gaps: [TimeInterval] = [0.4, 1.1, 0.35, 0.9, 0.6, 1.2, 0.45]
        let run = dictate(seconds: 60, gap: { gaps[$0 % gaps.count] })
        XCTAssertLessThan(run.fastestStep, 15 * 2)
        XCTAssertLessThanOrEqual(run.longestLag, LiveTextPacer.lagCap + 0.2)
    }

    // MARK: - Never stale

    func testShownTextIsNeverOlderThanTheCap() {
        for rate in [9.0, 15, 26] {
            for gap in [0.2, 0.8, 1.4, 2.5] {
                let run = dictate(seconds: 60, rate: rate, gap: { _ in gap })
                XCTAssertLessThanOrEqual(
                    run.longestLag, LiveTextPacer.lagCap + 0.2,
                    "\(rate) characters per second, batches every \(gap) s"
                )
            }
        }
    }

    func testABigBatchAfterAProviderPauseIsCaughtUp() {
        let run = dictate(seconds: 30, gap: { _ in 0.8 }, silent: 10...13.5)
        XCTAssertLessThanOrEqual(run.longestLag, LiveTextPacer.lagCap + 0.2)
    }

    func testTheLastWordsDoNotCrawlIn() {
        // Speech ends at 10 s; the last batch lands within a second of it.
        let run = dictate(seconds: 13, gap: { _ in 0.8 }, speechEnds: 10)
        XCTAssertEqual(run.shownAtEnd, Double(Int((10 - 0.25) * 15)), accuracy: 0.001)
        XCTAssertLessThanOrEqual(run.longestLag, LiveTextPacer.lagCap + 0.2)
    }

    func testTextThatGetsShorterNeverShowsMoreThanThereIs() {
        var pacer = LiveTextPacer()
        pacer.delivered(count: 40, now: 0)
        for frame in 1...300 { pacer.advance(now: Double(frame) / 60) }
        XCTAssertEqual(pacer.shown, 40, accuracy: 0.001)
        pacer.delivered(count: 25, now: 5.1)
        XCTAssertEqual(pacer.shown, 25, accuracy: 0.001)
    }

    func testAShortStallIsNotMadeUpInOneJump() {
        var pacer = LiveTextPacer()
        pacer.delivered(count: 200, now: 0)
        pacer.advance(now: 0.016)
        let before = pacer.shown
        pacer.advance(now: 0.5)  // the main thread was busy for half a second
        XCTAssertGreaterThan(pacer.shown, before)
        XCTAssertLessThan(pacer.shown - before, 60)
    }

    /// Being current comes before being smooth.
    func testTextPastItsDeadlineIsShownAtOnce() {
        var pacer = LiveTextPacer()
        pacer.delivered(count: 200, now: 0)
        pacer.advance(now: 0.016)
        pacer.advance(now: 3)  // the main thread was busy for three seconds
        pacer.advance(now: 3.016)
        XCTAssertEqual(pacer.shown, 200, accuracy: 0.001)
    }

    // MARK: - Characters

    private func settled(_ text: String) -> LiveTextTicker {
        var ticker = LiveTextTicker()
        ticker.textArrived(text, now: 0)
        for frame in 1...600 { ticker.advance(now: Double(frame) / 60) }
        return ticker
    }

    func testEachCharacterGathersWhenItIsRevealed() {
        var ticker = LiveTextTicker()
        ticker.textArrived("привет мир", now: 0)
        XCTAssertEqual(ticker.revealedCount, 0)
        XCTAssertEqual(ticker.gatherProgress(at: 0, now: 0), 0)
        var now = 0.0
        while ticker.revealedCount < 1 {
            now += 1.0 / 60
            ticker.advance(now: now)
        }
        XCTAssertLessThan(ticker.gatherProgress(at: 0, now: now), 0.2)
        XCTAssertEqual(ticker.gatherProgress(at: 0, now: now + LiveTextTicker.gatherSeconds), 1)
        XCTAssertEqual(ticker.gatherProgress(at: 9, now: now), 0, "not revealed yet")
    }

    func testARewrittenWordStaysReadableInPlace() {
        var ticker = settled("я хочу кофе сейчас")
        XCTAssertEqual(ticker.gatherProgress(at: 8, now: 10), 1)
        ticker.textArrived("я хочу кафе сейчас", now: 10)
        XCTAssertEqual(ticker.revealedCount, 18, "nothing is hidden again")
        XCTAssertEqual(ticker.gatherProgress(at: 8, now: 10), 1, "the corrected letter is immediately readable")
        XCTAssertEqual(ticker.gatherProgress(at: 7, now: 10), 1)
        XCTAssertEqual(ticker.gatherProgress(at: 9, now: 10), 1)
    }

    /// The stumble the user reported: the provider takes repeated words back.
    func testAStumbleTakenBackKeepsTheRestInPlace() {
        var ticker = settled("я я я хочу кофе")
        ticker.textArrived("я хочу кофе", now: 10)
        XCTAssertEqual(ticker.revealedCount, 11, "the reveal point stays at the end of the text")
        for index in 0..<11 {
            XCTAssertEqual(ticker.gatherProgress(at: index, now: 10), 1, "character \(index) gathered again")
        }
    }

    func testAWordInsertedEarlierIsSolidAndKeepsTheRevealPoint() {
        var ticker = settled("сегодня мы обсудим новую функцию")
        ticker.textArrived("сегодня вечером мы обсудим новую функцию", now: 10)
        XCTAssertEqual(ticker.revealedCount, 40)
        for index in 0..<40 {
            XCTAssertEqual(ticker.gatherProgress(at: index, now: 10), 1, "character \(index)")
        }
    }

    func testARewriteBeforeTheRevealPointDoesNotRevealOrHideTheTail() {
        var ticker = LiveTextTicker()
        ticker.textArrived("раз раз два три четыре пять шесть", now: 0)
        var now = 0.0
        while ticker.revealedCount < 12 {
            now += 1.0 / 60
            ticker.advance(now: now)
        }
        // "раз раз два " is on screen; the provider drops the repeated word.
        ticker.textArrived("раз два три четыре пять шесть", now: now)
        XCTAssertEqual(ticker.revealedCount, 8, "still up to the end of 'два '")
        XCTAssertEqual(ticker.gatherProgress(at: 8, now: now), 0, "'три' is not revealed early")
    }

    func testTextReplacedAtTheRevealPointIsPacedAgainFromThere() {
        var ticker = LiveTextTicker()
        ticker.textArrived("один два три четыре", now: 0)
        var now = 0.0
        while ticker.revealedCount < 7 {
            now += 1.0 / 60
            ticker.advance(now: now)
        }
        let sharedStart = ticker.gatherProgress(at: 4, now: now)
        ticker.textArrived("один сто пять", now: now)
        XCTAssertEqual(ticker.revealedCount, 7)
        XCTAssertEqual(ticker.gatherProgress(at: 4, now: now), sharedStart, "the shared start is untouched")
        XCTAssertEqual(ticker.gatherProgress(at: 5, now: now), 1, "visible replacements are solid")
    }

    func testALongRewriteChangesAtOnce() {
        var ticker = settled("короткое начало и потом совсем другая длинная фраза конец")
        ticker.textArrived("короткое начало а дальше провайдер услышал иначе конец", now: 10)
        for index in 0..<ticker.revealedCount {
            XCTAssertEqual(ticker.gatherProgress(at: index, now: 10), 1, "character \(index)")
        }
    }

    func testMixedCorrectionAndAppendKeepsSpokenWordsAtTheFrontier() {
        var ticker = settled("я говорю")
        ticker.textArrived("Я сейчас говорю дальше", now: 10)
        let shown = String(ticker.characters.prefix(ticker.revealedCount))
        XCTAssertEqual(shown, "Я сейчас говорю")
        for i in 0..<ticker.revealedCount {
            XCTAssertEqual(ticker.gatherProgress(at: i, now: 10), 1)
        }
        var now = 10.0
        while ticker.revealedCount <= shown.count + 1, now < 11.5 {
            now += 1.0 / 60
            ticker.advance(now: now)
        }
        XCTAssertGreaterThan(ticker.revealedCount, shown.count + 1)
        XCTAssertLessThan(ticker.gatherProgress(at: shown.count + 1, now: now), 1)
    }

    func testRepeatedEndOfWordDoesNotSkipOverNewSpeech() {
        for (old, next, visible) in [
            ("сказать что", "сказать, что это", "сказать, что"),
            ("я говорю", "Я говорю и снова говорю", "Я говорю")
        ] {
            var ticker = settled(old)
            ticker.textArrived(next, now: 10)
            XCTAssertEqual(String(ticker.characters.prefix(ticker.revealedCount)), visible)
        }
    }

    func testEarlyCorrectionInLongTakeKeepsTheCurrentWord() {
        let passage = String(repeating: "короткая пауза ", count: 90) + "здесь уникальное окончание"
        var ticker = settled("я " + passage)
        ticker.textArrived("Сейчас я " + passage + " продолжаю", now: 10)
        XCTAssertEqual(String(ticker.characters.prefix(ticker.revealedCount)), "Сейчас я " + passage)
        XCTAssertEqual(ticker.gatherProgress(at: ticker.revealedCount - 1, now: 10), 1)
    }

    func testWithdrawnPartialCanReturnInPiecesWithoutGatheringTwice() {
        var ticker = settled("я говорю")
        for text in ["я гово", "я", "я г", "я гово", "я говорю дальше"] {
            ticker.textArrived(text, now: 10.1)
            let restored = min(text.count, "я говорю".count)
            XCTAssertEqual(ticker.revealedCount, restored, text)
            for i in 0..<restored { XCTAssertEqual(ticker.gatherProgress(at: i, now: 10.1), 1) }
        }
        ticker.prime("", now: 11)
        ticker.textArrived("я говорю", now: 11.1)
        XCTAssertEqual(ticker.revealedCount, 0, "a new take starts a new reveal")
    }

    func testDifferentSpeechAfterTruncationGetsItsOwnReveal() {
        var ticker = settled("я пишу письмо")
        ticker.textArrived("я ", now: 10.1)
        ticker.textArrived("я отвечаю", now: 10.2)
        XCTAssertEqual(ticker.revealedCount, 2)
    }

    @MainActor
    func testShortCorrectionKeepsPrefixStillAndRevisedLettersVisible() {
        let model = IslandLiveTextTickerModel()
        model.prime("я говорю", now: 0)
        _ = render(model, now: 1, name: "rewrite-before")
        model.textArrived("Я говорю дальше", now: 1.01)
        let first = render(model, now: 1.01, name: "rewrite-corrected")
        XCTAssertGreaterThan(first.lit, 80)
        XCTAssertEqual(model.glyphX(at: 0), 0)
        _ = render(model, now: 1.12, name: "rewrite-new-speech")
        XCTAssertEqual(model.glyphX(at: 0), 0)
    }

    @MainActor
    func testOverflowingCorrectionKeepsVisiblePrefixStillOnItsFirstFrame() {
        let model = IslandLiveTextTickerModel()
        let phrase = String(repeating: "привет ", count: 10)
        model.prime(phrase + "узко", now: 0)
        _ = render(model, now: 1, name: "overflow-before")
        let before = model.glyphX(at: phrase.count - 20)
        XCTAssertGreaterThan(before, 0)
        model.textArrived(phrase + "широко", now: 1)
        _ = render(model, now: 1, name: "overflow-corrected")
        XCTAssertEqual(model.glyphX(at: phrase.count - 20), before, accuracy: 4)
        let tip = model.glyphX(at: phrase.count + "широко".count - 1)
        XCTAssertLessThan(tip, 180, "the live edge stays inside the viewport even during scrolling")
        _ = render(model, now: 1.02, name: "overflow-moving")
        XCTAssertLessThan(abs(model.glyphX(at: phrase.count - 20) - before), 7)
    }

    func testAFaceRebuiltMidTakeShowsItsTextAtOnce() {
        var ticker = LiveTextTicker()
        ticker.prime("уже сказанный текст", now: 5)
        XCTAssertEqual(ticker.revealedCount, 19)
        XCTAssertEqual(ticker.gatherProgress(at: 18, now: 5), 1)
        ticker.textArrived("уже сказанный текст и ещё", now: 5.5)
        XCTAssertEqual(ticker.revealedCount, 19, "only the new words are paced")
    }

    /// After a long main-thread stall the late text appears in one step; it
    /// must be readable on that very frame, not start gathering from dust.
    func testTextRevealedPastItsDeadlineIsSolidAtOnce() {
        var ticker = LiveTextTicker()
        ticker.prime("", now: 0)
        ticker.textArrived(String(repeating: "a", count: 200), now: 0)
        ticker.advance(now: 0.016)
        let early = ticker.revealedCount
        XCTAssertLessThan(early, 200)
        ticker.advance(now: 3)  // the main thread was busy for three seconds
        ticker.advance(now: 3.016)
        XCTAssertEqual(ticker.revealedCount, 200)
        for index in early..<200 {
            XCTAssertEqual(ticker.gatherProgress(at: index, now: 3.016), 1, "character \(index)")
        }
    }

    func testTextRevealedOnTimeStillGathers() {
        var ticker = LiveTextTicker()
        ticker.textArrived("привет", now: 0)
        var now = 0.0
        while ticker.revealedCount < 6 {
            now += 1.0 / 60
            ticker.advance(now: now)
        }
        XCTAssertLessThan(now, LiveTextPacer.lagCap)
        XCTAssertLessThan(ticker.gatherProgress(at: 5, now: now), 0.2)
    }

    func testOnlyLeftToRightUnjoinedScriptsAreDrawnPerCharacter() {
        for text in ["", "привет мир", "hello, world!", "café naïve", "日本語のテキスト", "한국어", "👍🏽 👨‍👩‍👧 ok", "ภาษาไทย"] {
            XCTAssertTrue(LiveTextTicker.canDrawPerCharacter(text), text)
        }
        for text in ["سلام", "שלום", "привет سلام", "नमस्ते", "ক্ষমা", "ܫܠܡܐ", "abc\u{202E}def", "abc\u{200F}"] {
            XCTAssertFalse(LiveTextTicker.canDrawPerCharacter(text), text)
        }
    }

    func testShorterTextDropsItsTail() {
        var ticker = settled("раз два три")
        ticker.textArrived("раз два", now: 10)
        XCTAssertEqual(ticker.revealedCount, 7)
        XCTAssertEqual(ticker.characters.count, 7)
        XCTAssertEqual(ticker.bornAt.count, 7)
    }

    // MARK: - Drawing

    @MainActor
    func testRevealedWidthGrowsFrameByFrameEvenWhenTheFirstBatchIsLong() {
        let model = IslandLiveTextTickerModel()
        model.textArrived(String(repeating: "wide ", count: 14), now: 0)
        XCTAssertEqual(model.advance(now: 0), 0)

        let first = model.advance(now: 1.0 / 60)
        let second = model.advance(now: 2.0 / 60)
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThan(second, first)
        XCTAssertLessThan(second, 20)
        XCTAssertEqual(model.advance(now: 2.0 / 60), second)

        for frame in 3...120 { model.advance(now: Double(frame) / 60) }
        XCTAssertGreaterThan(model.advance(now: 2), IslandFrameLayout.agentWingRecordingWidth)
    }

    /// Renders one frame offscreen. `LIVE_TEXT_RENDER_DIR` keeps the frames
    /// for a look at them; nothing is shown on screen.
    @MainActor
    private func render(
        _ model: IslandLiveTextTickerModel, now: TimeInterval, name: String, visibleWidth: CGFloat = 180
    ) -> (lit: Int, rightmost: Int) {
        let size = CGSize(width: 180, height: 28)
        let view = Canvas { context, canvasSize in
            model.draw(in: &context, size: canvasSize, now: now, visibleWidth: visibleWidth)
        }
        .frame(width: size.width, height: size.height)
        .frame(width: visibleWidth, alignment: .leading)
        .clipped()
        .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return (0, 0) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let directory = ProcessInfo.processInfo.environment["LIVE_TEXT_RENDER_DIR"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        var lit = 0
        var rightmost = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y), color.brightnessComponent > 0.35 else { continue }
                lit += 1
                rightmost = max(rightmost, x)
            }
        }
        return (lit, rightmost)
    }

    @MainActor
    func testGatheringUsesTheRightEdgeBeforeTheWingIsFull() {
        let model = IslandLiveTextTickerModel()
        model.textArrived(String(repeating: "W", count: 20), now: 0)
        _ = model.advance(now: 0)
        var reach: CGFloat = -.infinity
        for frame in 1...40 {
            let now = Double(frame) / 60
            let visibleWidth = max(64, ceil(model.advance(now: now)) + 1)
            let rendered = render(model, now: now, name: "growing-\(frame)", visibleWidth: visibleWidth)
            if rendered.lit > 0 { reach = max(reach, CGFloat(rendered.rightmost) / 2 - visibleWidth) }
        }
        XCTAssertGreaterThan(reach, -5, "the gathering line uses the last few points inside the capsule")
    }

    @MainActor
    func testTheLineIsDrawnAndKeepsItsTailInsideTheWing() {
        let model = IslandLiveTextTickerModel()
        model.textArrived("коротко", now: 0)
        XCTAssertEqual(render(model, now: 0, name: "0-empty").lit, 0, "nothing revealed yet")

        var now = 0.0
        while now < 0.45 {
            now += 1.0 / 60
            _ = render(model, now: now, name: "skip")
        }
        XCTAssertGreaterThan(render(model, now: now, name: "1-gathering").lit, 0)

        let long = "это длинная фраза которая точно не помещается в крыло острова целиком"
        model.textArrived(long, now: now)
        while now < 12 {
            now += 1.0 / 30
            model.textArrived(long, now: now)
            _ = render(model, now: now, name: "skip")
        }
        let settled = render(model, now: now + 1, name: "2-long")
        XCTAssertGreaterThan(settled.lit, 200)
        XCTAssertGreaterThan(settled.rightmost, 320, "the tail sits at the right edge")
        XCTAssertLessThan(settled.rightmost, 360, "and stays inside the wing")
    }

    @MainActor
    func testLateTextIsVisibleOnTheFirstFrameAfterAStall() {
        let model = IslandLiveTextTickerModel()
        model.textArrived(String(repeating: "a", count: 200), now: 0)
        _ = render(model, now: 0.016, name: "skip")
        let resumed = render(model, now: 3, name: "3-after-stall")
        XCTAssertGreaterThan(resumed.lit, 200, "the caught-up line is drawn solid")
        XCTAssertGreaterThan(resumed.rightmost, 320, "up to its newest character")
    }
}
