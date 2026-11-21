import Foundation
@testable import Sidekey
import XCTest

final class SubtitleSpeechPairerTests: XCTestCase {
    /// Replays the recorded live session with a 100 ms flush, as the model does.
    private func replay(_ events: [(at: Int, stream: OpenAITranslateRecordedSession.Stream, text: String, elapsed: Int)],
                        closeAt: Int) -> (pairs: [SubtitleSpeechPairer.Pair], times: [Int]) {
        var pairer = SubtitleSpeechPairer()
        var pairs: [SubtitleSpeechPairer.Pair] = []
        var times: [Int] = []
        var index = 0
        var clock = 0
        while clock <= closeAt {
            while index < events.count, events[index].at <= clock {
                let event = events[index]
                switch event.stream {
                case .source: pairer.addSource(event.text, elapsedMs: event.elapsed)
                case .translation: pairer.addTranslation(event.text, elapsedMs: event.elapsed, now: Double(event.at) / 1000)
                }
                index += 1
            }
            let carry = pairer.takeCarry()
            if !carry.isEmpty, !pairs.isEmpty { pairs[pairs.count - 1].source += carry }
            for pair in pairer.take(now: Double(clock) / 1000) { pairs.append(pair); times.append(clock) }
            clock += 100
        }
        for pair in pairer.take(now: Double(clock) / 1000, force: true) { pairs.append(pair); times.append(clock) }
        return (pairs, times)
    }

    func testRecordedSessionPairsEverySentenceWithItsTranslation() {
        let result = replay(OpenAITranslateRecordedSession.events, closeAt: OpenAITranslateRecordedSession.closedAt)
        XCTAssertEqual(result.pairs.map(\.source), [
            "Welcome back everyone.",
            "Today we have a special guest who has spent ten years building speech systems.",
            "Before we start, let me explain how a neural network is structured.",
            "Every layer takes the numbers from the previous one, multiplies them by its weights, and passes the result forward.",
            "The most important part is that these weights are learned from data, not written by hand.",
            "When the network makes a mistake, we measure how wrong it was, and we nudge every weight a little bit in the direction that reduces the error.",
            "Repeat this millions of times, and the network slowly learns to turn raw sound into words we can read.",
            "So, with that in mind, let's welcome our guest",
        ])
        XCTAssertEqual(result.pairs.map(\.translation).first, "Добро пожаловать обратно, всем.")
        XCTAssertEqual(result.pairs.map(\.translation).last, "Итак, с этим пониманием, давайте поприветствуем нашего гостя.")
        XCTAssertTrue(result.pairs.allSatisfy { !$0.translation.isEmpty && !$0.source.isEmpty })
        // A pair closes at most half a second after its translation ends.
        for (pair, time) in zip(result.pairs, result.times) {
            let lastDelta = OpenAITranslateRecordedSession.events.last { event in
                event.stream == .translation && pair.translation.hasSuffix(event.text.trimmingCharacters(in: .whitespaces))
                    && event.at <= time
            }
            XCTAssertLessThanOrEqual(time - (lastDelta?.at ?? time), 500, pair.translation)
        }
    }

    func testAPauseClosesThePairAndTheLatePeriodJoinsIt() {
        var pairer = SubtitleSpeechPairer()
        pairer.addSource(" Thank you", elapsedMs: 800)
        pairer.addTranslation("Спасибо.", elapsedMs: 1_200, now: 1.5)
        XCTAssertEqual(pairer.take(now: 1.9), [.init(source: "Thank you", translation: "Спасибо.")])
        pairer.addSource(". Next", elapsedMs: 4_000)
        XCTAssertEqual(pairer.takeCarry(), ".")
        XCTAssertEqual(pairer.liveSource, "Next")
    }

    func testMergedSentencesStayInOnePair() {
        var pairer = SubtitleSpeechPairer()
        pairer.addSource(" Yes", elapsedMs: 500)
        pairer.addSource(". Right", elapsedMs: 900)
        pairer.addSource(". We start now", elapsedMs: 1_400)
        pairer.addSource(". Then", elapsedMs: 7_200)
        // The model merged "Yes. Right." into one sentence that ends late.
        pairer.addTranslation("Да, верно.", elapsedMs: 6_400, now: 7)
        pairer.addTranslation(" Начинаем ", elapsedMs: 6_600, now: 7.1)
        XCTAssertEqual(pairer.take(now: 7.1), [.init(source: "Yes. Right.", translation: "Да, верно.")])
        XCTAssertEqual(pairer.liveSource, "We start now. Then")
        XCTAssertEqual(pairer.liveTranslation, "Начинаем")
    }

    func testASplitSentenceTakesOnlyTheWordsHeardBeforeItsTranslation() {
        var pairer = SubtitleSpeechPairer()
        for (index, word) in [" This", " is", " long", " and", " it", " goes", " on"].enumerated() {
            pairer.addSource(word, elapsedMs: 400 + index * 400)
        }
        pairer.addTranslation("Это длинно.", elapsedMs: 1_200, now: 2)
        pairer.addTranslation(" И", elapsedMs: 2_000, now: 2.1)
        XCTAssertEqual(pairer.take(now: 2.1), [.init(source: "This is long", translation: "Это длинно.")])
        XCTAssertEqual(pairer.liveSource, "and it goes on")
    }

    func testEmptyOrMissingStreamsNeverMakeEmptyPairs() {
        var pairer = SubtitleSpeechPairer()
        XCTAssertEqual(pairer.take(now: 10, force: true), [])
        pairer.addTranslation("  ", elapsedMs: nil, now: 1)
        XCTAssertEqual(pairer.take(now: 10, force: true), [])
        // Translation without any heard original (input transcript off).
        pairer.addTranslation("Привет.", elapsedMs: 600, now: 1)
        XCTAssertEqual(pairer.take(now: 2), [.init(source: "", translation: "Привет.")])
        // Original heard, nothing translated by the end.
        pairer.addSource(" Hello", elapsedMs: 900)
        XCTAssertEqual(pairer.take(now: 3, force: true), [.init(source: "Hello", translation: "")])
    }

    func testALongTranslationWithoutASentenceEndClosesAtAClause() {
        var pairer = SubtitleSpeechPairer()
        pairer.addSource(" the first part of what was said, then more words", elapsedMs: 1_000)
        let clause = String(repeating: "слово ", count: 20) + "и ещё, "
        pairer.addTranslation(clause + String(repeating: "дальше ", count: 10), elapsedMs: 2_000, now: 3)
        let pairs = pairer.take(now: 3.1)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.translation, clause.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(pairs.first?.source, "the first part of what was said,")
    }

    func testTheLiveTranslationShowsOnlyWholeWords() {
        var pairer = SubtitleSpeechPairer()
        pairer.addTranslation("Когда сеть ошиб", elapsedMs: 800, now: 1)
        XCTAssertEqual(pairer.liveTranslation, "Когда сеть")
        pairer.addTranslation("ается,", elapsedMs: 1_000, now: 1.1)
        XCTAssertEqual(pairer.liveTranslation, "Когда сеть ошибается,")
        var single = SubtitleSpeechPairer()
        single.addTranslation("Доб", elapsedMs: 600, now: 1)
        XCTAssertEqual(single.liveTranslation, "")
    }
}
