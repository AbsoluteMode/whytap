import Foundation
@testable import Sidekey
import XCTest

/// A lecture as the speech-translation model streams it: the original's
/// words in 200 ms audio steps with each sentence's period arriving with the
/// next word, and the translation of each group of sentences (one, or
/// several the model merged) trailing its original by a delay.
struct SubtitleLecture {
    struct Group { var sources: [String]; var translation: String; var lag: Int }
    enum Event { case source(String, Int), translation(String, Int) }

    var groups: [Group]
    /// Audio per spoken word.
    var wordMs = 360

    var expected: [SubtitleSpeechPairer.Pair] {
        groups.map { .init(source: $0.sources.joined(separator: " "), translation: $0.translation) }
    }

    /// Events in arrival order. Arrival is the audio position plus a fixed
    /// delay, so the order is by audio position (original first on a tie).
    var events: [Event] {
        var timed: [(elapsed: Int, order: Int, event: Event)] = []
        var clock = 0
        var pendingPeriod = ""
        // The model speaks one translation after another.
        var translated = 0
        func step(_ ms: Int) -> Int { (ms / 200 + 1) * 200 }
        for group in groups {
            var spoken: [Int] = []
            for sentence in group.sources {
                var words = sentence.split(separator: " ").map(String.init)
                let terminator = String(words[words.count - 1].last!)
                words[words.count - 1].removeLast()
                for word in words {
                    clock += wordMs
                    timed.append((step(clock), 0, .source(pendingPeriod + " " + word, step(clock))))
                    pendingPeriod = ""
                    spoken.append(clock)
                }
                pendingPeriod = terminator
            }
            // The translation's words spread over its original's, each its
            // delay after the matching point of the original.
            let words = group.translation.split(separator: " ").map(String.init)
            for (index, word) in words.enumerated() {
                let at = max(translated, spoken[max(0, min(spoken.count - 1, (index + 1) * spoken.count / words.count - 1))] + group.lag)
                translated = at
                timed.append((step(at), 1, .translation(" " + word, step(at))))
            }
        }
        // The last period arrives with the next word: speech goes on.
        if !pendingPeriod.isEmpty {
            timed.append((step(clock + wordMs), 0, .source(pendingPeriod + " And", step(clock + wordMs))))
        }
        return timed.enumerated().sorted { ($0.element.elapsed, $0.element.order, $0.offset) < ($1.element.elapsed, $1.element.order, $1.offset) }
            .map(\.element.event)
    }

    /// Plays the lecture through a pairer the way the live model does after
    /// every event: pairs are taken as time passes, then the live row shown.
    func play(originalAsHeard: Bool = false) -> [SubtitleSpeechPairer.Pair] { replay(originalAsHeard: originalAsHeard).pairs }

    /// The pairs, and how many times words the live row showed in its
    /// original went to another row when it settled.
    func replay(originalAsHeard: Bool) -> (pairs: [SubtitleSpeechPairer.Pair], moved: Int) {
        var pairer = SubtitleSpeechPairer()
        pairer.originalAsHeard = originalAsHeard
        var pairs: [SubtitleSpeechPairer.Pair] = []
        var shown = ""
        var moved = 0
        var now = 0.0
        for event in events {
            switch event {
            case .source(let text, let elapsed):
                now = max(now, Double(elapsed + 2_200) / 1_000)
                pairer.addSource(text, elapsedMs: elapsed)
            case .translation(let text, let elapsed):
                now = max(now, Double(elapsed + 2_200) / 1_000)
                pairer.addTranslation(text, elapsedMs: elapsed, now: now)
            }
            // As `LiveSubtitleModel.flushPairs`: carry, settled pairs, then the live row.
            let carry = pairer.takeCarry()
            if !carry.isEmpty, !pairs.isEmpty { pairs[pairs.count - 1].source += carry }
            for pair in pairer.take(now: now) {
                if !pair.source.hasPrefix(shown) { moved += 1 }
                pairs.append(pair)
                shown = ""
            }
            shown = pairer.showLive().source
        }
        pairs += pairer.take(now: now + 2)
        // The words after the last translated sentence are still being heard.
        return (pairs, moved)
    }
}

final class SubtitleLecturePairingTests: XCTestCase {
    /// Maxim's lecture (build 1733): the model joined two sentences into one
    /// translation; the second, short sentence ended under five seconds
    /// before the translation did and moved to the next row, beside the next
    /// sentence's translation.
    func testAShortSentenceTheModelJoinedStaysWithItsTranslation() {
        let lecture = SubtitleLecture(groups: [
            .init(sources: ["So today we look at a very small neural network."],
                  translation: "Сегодня мы посмотрим на очень маленькую нейросеть.", lag: 1_400),
            .init(sources: ["It has two inputs and one output."],
                  translation: "У неё два входа и один выход.", lag: 1_600),
            .init(sources: ["I mean, these are the kinds of expressions.", "Just to show you that it's not very scary."],
                  translation: "Я показываю такие выражения, чтобы показать: ничего страшного.", lag: 1_500),
            .init(sources: ["We have inputs X, for example x1 and x2, and they are mixed with the weights w0, w1 and w2."],
                  translation: "У нас есть входы X, например x1 и x2, и они смешиваются с весами сети: w0, w1 и w2.", lag: 1_700)
        ])
        XCTAssertEqual(lecture.play(), lecture.expected)
    }

    /// The opposite case: a short sentence that ended before the previous
    /// translation did, but has its own translation.
    func testAShortSentenceWithItsOwnTranslationStartsTheNextRow() {
        let lecture = SubtitleLecture(groups: [
            .init(sources: ["Welcome back everyone, it is good to see so many of you here today."],
                  translation: "С возвращением всех, рад видеть так много из вас сегодня здесь.", lag: 1_500),
            .init(sources: ["Let's begin."], translation: "Начнём.", lag: 1_500),
            .init(sources: ["The first thing we need is a way to measure how wrong the network is."],
                  translation: "Первое, что нам нужно, это способ измерить, насколько ошибается сеть.", lag: 1_500)
        ])
        XCTAssertEqual(lecture.play(), lecture.expected)
    }

    /// The last word waits for the next delta to show it was whole, but at
    /// most `wordHold`: at a pause it is shown instead of waiting for the
    /// speaker to go on (it waited up to the 1.2 s pause cut before).
    func testAWordBeforeAPauseShowsAfterTheHold() {
        var pairer = SubtitleSpeechPairer()
        pairer.addSource("Every layer takes", elapsedMs: 400)
        pairer.addTranslation("Каждый слой получает", elapsedMs: 1_200, now: 10)
        XCTAssertEqual(pairer.showLive(now: 10.1).translation, "Каждый слой", "a possible fragment waits")
        XCTAssertEqual(pairer.showLive(now: 10 + SubtitleSpeechPairer.wordHold).translation, "Каждый слой получает")
        // A word that did go on grows at the end of the row; nothing shown leaves.
        pairer.addTranslation("ся", elapsedMs: 1_400, now: 10.4)
        XCTAssertEqual(pairer.showLive(now: 10.5).translation, "Каждый слой получает")
        pairer.addTranslation(" числа", elapsedMs: 1_600, now: 10.6)
        XCTAssertEqual(pairer.showLive(now: 10.7).translation, "Каждый слой получается")
        XCTAssertEqual(SubtitleSpeechPairer.wordHold, 0.3)
    }

    /// Sixty lectures with sentences of 2 to 20 words, translations 0.75-1.4
    /// times as long, a delay drifting between 0.4 and 3 s (as measured in the
    /// recorded session) and every fourth translation joining two sentences.
    /// The 5 s merge rule alone misaligned 519 of 720 rows: one miss shifts
    /// every later pair. Matching length and delay misaligns 47 (6.5 %),
    /// mostly a two-word sentence beside a 3 s delay.
    func testVariedLecturesKeepTheirPairs() {
        var generator = SeededGenerator(seed: 23_11_2026)
        var rows = 0
        var wrong = 0
        var wrongAsHeard = 0
        var movedAsHeard = 0
        var movedInStep = 0
        for _ in 0..<60 {
            var groups: [SubtitleLecture.Group] = []
            var lag = Int.random(in: 400...3_000, using: &generator)
            for _ in 0..<12 {
                lag = min(3_000, max(400, lag + Int.random(in: -800...800, using: &generator)))
                let count = Int.random(in: 0..<4, using: &generator) == 0 ? 2 : 1
                let sources = (0..<count).map { _ in Self.sentence(words: Int.random(in: 2...20, using: &generator)) }
                let length = Double(sources.joined(separator: " ").count) * Double.random(in: 0.75...1.4, using: &generator)
                groups.append(.init(sources: sources, translation: Self.translation(characters: Int(length)),
                                    lag: lag))
            }
            let lecture = SubtitleLecture(groups: groups)
            let played = lecture.play()
            let asHeard = lecture.replay(originalAsHeard: true)
            movedAsHeard += asHeard.moved
            movedInStep += lecture.replay(originalAsHeard: false).moved
            wrongAsHeard += zip(asHeard.pairs, lecture.expected).filter { $0.source != $1.source }.count
                + abs(asHeard.pairs.count - lecture.expected.count)
            rows += lecture.expected.count
            wrong += zip(played, lecture.expected).filter { $0.source != $1.source }.count
                + abs(played.count - lecture.expected.count)
        }
        print("lecture rows \(rows), misaligned \(wrong); original as heard: misaligned \(wrongAsHeard), "
              + "rows whose shown original lost words \(movedAsHeard) (in step with the translation: \(movedInStep))")
        XCTAssertEqual(movedInStep, 0, "in step with its translation, a shown original never moves")
        XCTAssertLessThanOrEqual(Double(wrong) / Double(rows), 0.08, "\(wrong) of \(rows) rows took another row's original")
    }

    private static func sentence(words: Int) -> String {
        let vocabulary = ["the", "network", "learns", "weights", "from", "data", "and", "we", "measure", "error", "inputs",
                          "layer", "output", "values", "small", "change", "gradient", "model", "speech", "signal"]
        var generator = SeededGenerator(seed: UInt64(words * 7_919))
        return (0..<words).map { _ in vocabulary.randomElement(using: &generator)! }.joined(separator: " ") + "."
    }

    private static func translation(characters: Int) -> String {
        let words = ["сеть", "учится", "весам", "по", "данным", "и", "мы", "меряем", "ошибку", "вход", "слой", "выход"]
        var text = ""
        var index = 0
        while text.count < max(4, characters - 1) { text += (text.isEmpty ? "" : " ") + words[index % words.count]; index += 1 }
        return text + "."
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
