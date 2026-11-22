import XCTest
@testable import Sidekey

/// The live line must not take shown words back when a provider alternates
/// between readings of the phrase it is still decoding.
final class LiveTextStabilizerTests: XCTestCase {
    private typealias Event = ElevenLabsRecordedTake.Event

    /// What a screen recording of 2026-11-23 showed with `scribe_v3_live`:
    /// the line alternated between a reading with a leading interjection and
    /// one without it, "щас" and "сейчас" swapped, and four partials were an
    /// earlier, shorter state of the phrase. The order, lengths and timing
    /// follow the recording; the words are replaced.
    private static let alternatingTake: [Event] = [
        Event(at: 0.2, kind: .partial, text: "Угу. Так"),
        Event(at: 0.5, kind: .partial, text: "Угу. Так, щас."),
        Event(at: 0.9, kind: .partial, text: "Угу. Так, щас. Угу. А"),
        Event(at: 1.9, kind: .partial, text: "Так, щас. А"),
        Event(at: 2.3, kind: .partial, text: "Так, щас. А в"),
        Event(at: 2.6, kind: .partial, text: "Так, сейчас. А в каталог"),
        Event(at: 3.0, kind: .partial, text: "Так, сейчас. А в каталог з"),
        Event(at: 3.2, kind: .partial, text: "Так, щас. А"),
        Event(at: 3.6, kind: .partial, text: "Так, щас. А в каталог заявки"),
        Event(at: 4.4, kind: .partial, text: "Угу. Так, щас"),
        Event(at: 4.7, kind: .partial, text: "Угу. Так, щас. А в каталог"),
        Event(at: 5.1, kind: .partial, text: "Угу. Так, щас. А в каталог заявки то"),
        Event(at: 5.4, kind: .partial, text: "Так, щас"),
        Event(at: 6.2, kind: .partial, text: "Так, щас. А в"),
        Event(at: 6.6, kind: .partial, text: "Угу. Так, щас. А в каталог заявки тоже надо"),
        Event(at: 7.0, kind: .partial, text: "Угу. Так, щас. А в каталог заявки тоже надо что-то,"),
        Event(at: 7.4, kind: .partial, text: "Угу. Так, щас. А в каталог заявки тоже надо что-то, получается, самому"),
        Event(at: 8.0, kind: .partial, text: "Угу. Так, щас. А в каталог заявки тоже надо что-то, получается, самому отправлять?"),
        Event(at: 8.5, kind: .partial, text: "Угу. Так, щас. А в каталог заявки тоже надо что-то, получается, самому отправлять? Или как?"),
        Event(at: 9.2, kind: .committed, text: "Угу. Так, щас. А в каталог заявки тоже надо что-то, получается, самому отправлять? Или как?"),
    ]

    /// Frames in which the text on screen lost more than a word's ending.
    private static func rollbacks(_ frames: [ElevenLabsLiveTextReplayTests.Frame]) -> [Double] {
        zip(frames, frames.dropFirst()).compactMap { before, after in
            after.text.count < before.text.count - 6 ? after.at : nil
        }
    }

    @MainActor
    func testTheAlternatingTakeRollsBackWithoutTheStabilizer() {
        let frames = ElevenLabsLiveTextReplayTests.replay(Self.alternatingTake, confirm: 0)
        XCTAssertGreaterThanOrEqual(Self.rollbacks(frames).count, 3, "the take must reproduce the defect")
    }

    @MainActor
    func testTheAlternatingTakeNeverTakesShownWordsBack() {
        let frames = ElevenLabsLiveTextReplayTests.replay(Self.alternatingTake)
        XCTAssertEqual(Self.rollbacks(frames), [])
        // A word of the phrase, once on screen, stays there.
        for word in ["каталог", "заявки"] {
            guard let first = frames.firstIndex(where: { $0.text.contains(word) }) else {
                return XCTFail("\(word) was never shown")
            }
            for frame in frames[first...] {
                XCTAssertTrue(frame.text.contains(word), "\(word) left the line at \(frame.at) s")
            }
        }
    }

    @MainActor
    func testTheAlternatingTakeNeverMovesVisibleTextBackwards() {
        let wing: CGFloat = 226
        let frames = ElevenLabsLiveTextReplayTests.replay(Self.alternatingTake, wing: wing)
        let worst = ElevenLabsLiveTextReplayTests.backwardMotion(frames, wing: wing)
        XCTAssertLessThan(worst.points, 0.75, "visible text moved back at \(worst.at) s")
    }

    @MainActor
    func testTheAlternatingTakeEndsOnTheProvidersText() throws {
        let last = try XCTUnwrap(ElevenLabsLiveTextReplayTests.replay(Self.alternatingTake).last)
        XCTAssertEqual(last.text, Self.alternatingTake.last?.text)
    }

    @MainActor
    func testNewWordsOfTheAlternatingTakeAreNotDelayed() {
        // "тоже надо" arrives at 6.6 s together with a changed beginning.
        let frames = ElevenLabsLiveTextReplayTests.replay(Self.alternatingTake)
        let shownAt = frames.first { $0.text.contains("тоже надо") }?.at
        XCTAssertNotNil(shownAt)
        XCTAssertLessThan(shownAt ?? .infinity, 6.6 + LiveTextPacer.lagCap + 0.1)
    }

    // MARK: - Order of events

    private func feed(_ texts: [String], every gap: TimeInterval = 0.3) -> [String] {
        var stabilizer = LiveTextStabilizer()
        return texts.enumerated().map { stabilizer.arrived($1, now: Double($0) * gap) }
    }

    func testAppendedWordsPassThrough() {
        let texts = ["Привет", "Привет, как", "Привет, как дела?"]
        XCTAssertEqual(feed(texts), texts)
    }

    func testAnEarlierShorterSnapshotIsNotShown() {
        XCTAssertEqual(
            feed(["один два три", "один два три четыре", "один два три", "один два три четыре пять"]),
            ["один два три", "один два три четыре", "один два три четыре", "один два три четыре пять"]
        )
    }

    func testAShorterPhraseTheProviderKeepsIsShownAfterTheConfirmTime() {
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.arrived("Привет. Спасибо за", now: 0)
        XCTAssertEqual(stabilizer.arrived("Привет.", now: 1), "Привет. Спасибо за")
        XCTAssertNil(stabilizer.settled(now: 1 + stabilizer.confirmSeconds - 0.05))
        XCTAssertEqual(stabilizer.settled(now: 1 + stabilizer.confirmSeconds), "Привет.")
        XCTAssertNil(stabilizer.settled(now: 10))
    }

    func testAChangedBeginningWaitsWhileNewWordsAreShownAtOnce() {
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.arrived("Угу. Так, щас. А в каталог", now: 0)
        XCTAssertEqual(
            stabilizer.arrived("Так, щас. А в каталог заявки тоже", now: 0.3),
            "Угу. Так, щас. А в каталог заявки тоже"
        )
        XCTAssertEqual(stabilizer.settled(now: 0.3 + stabilizer.confirmSeconds), "Так, щас. А в каталог заявки тоже")
    }

    func testAProviderThatChangesItsMindStartsTheWaitAgain() {
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.arrived("Угу. Так, щас. А в каталог", now: 0)
        _ = stabilizer.arrived("Так, щас. А", now: 0.3)
        _ = stabilizer.arrived("Так, сейчас. А в", now: 1.3)   // another reading
        XCTAssertNil(stabilizer.settled(now: 1.9))
        _ = stabilizer.arrived("Угу. Так, щас. А в", now: 2.0)  // back to the first
        XCTAssertNil(stabilizer.settled(now: 3.0))
        XCTAssertEqual(stabilizer.shown, "Угу. Так, щас. А в каталог")
    }

    func testTheLiveWordIsReplacedAtOnce() {
        XCTAssertEqual(feed(["мы едем на", "мы едем нас", "мы едем наступать"]).last, "мы едем наступать")
        XCTAssertEqual(feed(["Подумай-", "Подумай.", "Подумай, э-э"]), ["Подумай-", "Подумай.", "Подумай, э-э"])
        // Words after the last common one are the provider's live guess.
        XCTAssertEqual(feed(["А в каталог з", "А в каталог заявки"]).last, "А в каталог заявки")
        XCTAssertEqual(feed(["чем стоит, ну, как мы", "чем стоит заняться"]).last, "чем стоит заняться")
    }

    func testARepeatedWordAtTheLiveEdgeIsNewSpeech() {
        XCTAssertEqual(feed(["он пришёл и", "он пришёл и вот и"]).last, "он пришёл и вот и")
    }

    func testWordsNotRevealedYetAreReplacedFreely() {
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.arrived("первые слова тут", now: 0)
        XCTAssertEqual(stabilizer.arrived("другие слова", revealed: 0, now: 0.1), "другие слова")
        _ = stabilizer.arrived("один два три четыре", now: 1)
        // Only "один два" is on screen: the shorter text takes nothing back.
        XCTAssertEqual(stabilizer.arrived("один два", revealed: 8, now: 1.1), "один два")
    }

    func testTextWithoutSpacesAndAnEmptyTextPassThrough() {
        XCTAssertEqual(feed(["今日は天気", "今日は", ""]), ["今日は天気", "今日は", ""])
    }

    func testAFirstWordThatChangesIsShownAtOnce() {
        XCTAssertEqual(feed(["Прив", "Приз", "Признаться"]), ["Прив", "Приз", "Признаться"])
    }

    func testZeroConfirmTimeShowsEverySnapshot() {
        var stabilizer = LiveTextStabilizer()
        stabilizer.confirmSeconds = 0
        _ = stabilizer.arrived("один два три", now: 0)
        XCTAssertEqual(stabilizer.arrived("один", now: 0.1), "один")
    }

    func testALongDictationIsComparedOnlyWhereItDiffers() {
        let start = String(repeating: "слово ", count: 2000)
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.arrived(start + "и вот конец", now: 0)
        XCTAssertEqual(stabilizer.arrived(start + "и вот", now: 0.3), start + "и вот конец")
        XCTAssertEqual(stabilizer.arrived(start + "и вот конец фразы", now: 0.6), start + "и вот конец фразы")
    }

    /// The face is rebuilt mid-take with the provider's current text.
    @MainActor
    func testPrimingStartsFromTheProvidersText() {
        let model = IslandLiveTextTickerModel()
        model.wingWidth = 226
        model.prime("один два три четыре", now: 0)
        model.textArrived("один два", now: 0.1)
        model.advance(now: 0.2)
        XCTAssertEqual(model.shownText, "один два три четыре")
        model.prime("один два", now: 0.3)
        XCTAssertEqual(model.shownText, "один два")
    }
}
