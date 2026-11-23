import XCTest
@testable import Sidekey

/// The live line must not take shown words back when a provider alternates
/// between readings of the phrase it is still decoding.
private extension LiveTextStabilizer {
    /// A snapshot for a line that shows all of its text.
    mutating func shows(_ text: String, now: TimeInterval) -> String {
        arrived(text, visible: shown, now: now)
    }
}

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
        return texts.enumerated().map {
            stabilizer.arrived($1, visible: stabilizer.shown, now: Double($0) * gap)
        }
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
        _ = stabilizer.shows("Привет. Спасибо за", now: 0)
        XCTAssertEqual(stabilizer.shows("Привет.", now: 1), "Привет. Спасибо за")
        XCTAssertNil(stabilizer.settled(now: 1 + stabilizer.confirmSeconds - 0.05))
        XCTAssertEqual(stabilizer.settled(now: 1 + stabilizer.confirmSeconds), "Привет.")
        XCTAssertNil(stabilizer.settled(now: 10))
    }

    func testAChangedBeginningWaitsWhileNewWordsAreShownAtOnce() {
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.shows("Угу. Так, щас. А в каталог", now: 0)
        XCTAssertEqual(
            stabilizer.shows("Так, щас. А в каталог заявки тоже", now: 0.3),
            "Угу. Так, щас. А в каталог заявки тоже"
        )
        XCTAssertEqual(stabilizer.settled(now: 0.3 + stabilizer.confirmSeconds), "Так, щас. А в каталог заявки тоже")
    }

    func testAProviderThatChangesItsMindStartsTheWaitAgain() {
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.shows("Угу. Так, щас. А в каталог", now: 0)
        _ = stabilizer.shows("Так, щас. А", now: 0.3)
        _ = stabilizer.shows("Так, сейчас. А в", now: 1.3)   // another reading
        XCTAssertNil(stabilizer.settled(now: 1.9))
        _ = stabilizer.shows("Угу. Так, щас. А в", now: 2.0)  // back to the first
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

    func testWordsNotRevealedYetFollowTheNewestSnapshot() {
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.arrived("первые слова тут", visible: "", now: 0)
        XCTAssertEqual(stabilizer.arrived("другие слова", visible: "", now: 0.1), "другие слова")
        _ = stabilizer.arrived("один два три неверная догадка", visible: "", now: 1)
        // "один два три" is on screen; the guess after it never was.
        XCTAssertEqual(stabilizer.arrived("один два", visible: "один два три", now: 1.1), "один два три")
        XCTAssertEqual(stabilizer.arrived("один два три и ещё", visible: "один два три", now: 1.2), "один два три и ещё")
    }

    func testLettersOfAWordStillBeingRevealedAreNotKept() {
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.arrived("один два три неверная", visible: "один два", now: 0)
        XCTAssertEqual(stabilizer.arrived("один два", visible: "один два три нев", now: 0.1), "один два три ")
        // A whole word on screen is kept.
        _ = stabilizer.arrived("один два три", visible: "один два", now: 1)
        XCTAssertEqual(stabilizer.arrived("один", visible: "один два три", now: 1.1), "один два три")
    }

    func testAWordTheProviderIsTypingAgainIsAnEarlierState() {
        XCTAssertEqual(feed(["А в каталог заявки то", "А в каталог за"]).last, "А в каталог заявки то")
        XCTAssertEqual(feed(["Привет как", "При"]).last, "Привет как")
        XCTAssertEqual(feed(["А в каталог заявки", "А в каталог заяв"]).last, "А в каталог заявки")
    }

    /// The reveal point is inside a word: the provider's whole word matches it.
    func testAWordCutByTheRevealPointMatchesTheWholeWord() {
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.arrived("Угу. Так, щас. А в", visible: "", now: 0)
        XCTAssertEqual(
            stabilizer.arrived("Так, щас. А в каталог", visible: "Угу. Так, ща", now: 0.3),
            "Угу. Так, щас. А в каталог"
        )
    }

    func testADifferentCorrectionDoesNotInheritTheWait() {
        var stabilizer = LiveTextStabilizer()
        stabilizer.reset("one two three four")
        XCTAssertEqual(stabilizer.shows("one two", now: 1), "one two three four")
        XCTAssertEqual(stabilizer.shows("one changed two three four", now: 2.49), "one two three four")
        XCTAssertNil(stabilizer.settled(now: 2.51))
        XCTAssertNil(stabilizer.settled(now: 2.49 + stabilizer.confirmSeconds - 0.01))
        XCTAssertEqual(stabilizer.settled(now: 2.49 + stabilizer.confirmSeconds), "one changed two three four")
    }

    func testTheSameWordCorrectedAtAnotherPlaceDoesNotInheritTheWait() {
        var stabilizer = LiveTextStabilizer()
        let line = "go to the store and go to the bank now"
        stabilizer.reset(line)
        XCTAssertEqual(stabilizer.shows("go into the store and go to the bank now", now: 1), line)
        // The first "to" is back; the second one changes the same way.
        XCTAssertEqual(stabilizer.shows("go to the store and go into the bank now", now: 2.48), line)
        XCTAssertNil(stabilizer.settled(now: 2.5))
        XCTAssertNil(stabilizer.settled(now: 2.48 + stabilizer.confirmSeconds - 0.01))
        XCTAssertEqual(
            stabilizer.settled(now: 2.48 + stabilizer.confirmSeconds),
            "go to the store and go into the bank now"
        )
    }

    @MainActor
    func testARepeatedWordCorrectedAtAnotherPlaceWaitsInTheLine() {
        let model = IslandLiveTextTickerModel()
        model.wingWidth = 226
        model.rewriteHoldSeconds = 0
        let line = "go to the store and go to the bank now"
        model.prime(line, now: 0)
        model.textArrived("go into the store and go to the bank now", now: 1)
        model.textArrived("go to the store and go into the bank now", now: 2.48)
        model.advance(now: 2.5)
        XCTAssertEqual(model.shownText, line)
        model.advance(now: 2.48 + model.confirmSeconds)
        XCTAssertEqual(model.shownText, "go to the store and go into the bank now")
    }

    func testTheSameCorrectionKeepsItsWaitWhileNewWordsArrive() {
        var stabilizer = LiveTextStabilizer()
        stabilizer.reset("one two three four")
        _ = stabilizer.shows("one changed two three four", now: 1)
        XCTAssertEqual(stabilizer.shows("one changed two three four five", now: 1.6), "one two three four five")
        XCTAssertEqual(stabilizer.shows("one changed two three four five six", now: 2.2), "one two three four five six")
        XCTAssertNil(stabilizer.settled(now: 2.49))
        XCTAssertEqual(stabilizer.settled(now: 2.5), "one changed two three four five six")
    }

    func testASecondCorrectionFurtherOnStartsTheWaitAgain() {
        var stabilizer = LiveTextStabilizer()
        stabilizer.reset("one two three four five")
        _ = stabilizer.shows("one changed two three four five", now: 1)
        // The first correction stays and another word changes too.
        _ = stabilizer.shows("one changed two three other four five", now: 2.4)
        XCTAssertNil(stabilizer.settled(now: 2.6))
        XCTAssertNotNil(stabilizer.settled(now: 2.4 + stabilizer.confirmSeconds))
    }

    func testACorrectionSettlesWhileTheProviderTypesTheNextWord() {
        var stabilizer = LiveTextStabilizer()
        stabilizer.reset("Угу. Так, щас. А в каталог")
        let start = "Так, сейчас. А в "
        for (index, word) in ["к", "ка", "кат", "катал", "каталог", "каталог"].enumerated() {
            let now = 1 + Double(index) * 0.25
            XCTAssertNil(stabilizer.settled(now: now))
            XCTAssertEqual(stabilizer.shows(start + word, now: now), "Угу. Так, щас. А в каталог")
        }
        XCTAssertEqual(stabilizer.settled(now: 1 + stabilizer.confirmSeconds), "Так, сейчас. А в каталог")
    }

    func testAFewSharedWordsDoNotTieANewPhraseToTheOldOne() {
        XCTAssertEqual(feed(["Ну и я пошёл домой", "А я потом"]).last, "А я потом")
        XCTAssertEqual(feed(["щас", "Так, сейчас. А щас пойдём"]).last, "Так, сейчас. А щас пойдём")
    }

    func testAWholeLastWordIsNotTakenForTheStartOfAnother() {
        XCTAssertEqual(feed(["Он сказал, что в", "Он сказал, что важно"]).last, "Он сказал, что важно")
        XCTAssertEqual(feed(["Он сказал, что в", "Он сказал: вот что важно"]).last, "Он сказал, что важно")
    }

    // MARK: - The ticker

    /// The reveal point is inside a word on most snapshots; the correction
    /// must still be the same one and settle while the speaker goes on.
    @MainActor
    func testACorrectionSettlesWhileTheSpeakerKeepsTalking() {
        let model = IslandLiveTextTickerModel()
        model.wingWidth = 226
        model.prime("Угу. Так, щас. А в каталог", now: 0)
        var text = "Так, сейчас. А в каталог"
        var settledAt: Double?
        var frame = 0
        for step in 0..<18 {
            let at = 1 + Double(step) * 0.3
            while Double(frame) / 60 < at {
                model.advance(now: Double(frame) / 60)
                frame += 1
            }
            text += " слово\(step)"
            model.textArrived(text, now: at)
            if settledAt == nil, model.shownText.hasPrefix("Так, сейчас") { settledAt = at }
        }
        XCTAssertLessThanOrEqual(settledAt ?? .infinity, 1 + 1.5 + 0.4)
    }

    /// A settled correction is shown at once: a snapshot arriving just after
    /// it must not send it back to wait.
    @MainActor
    func testASnapshotRightAfterTheWaitDoesNotStartItAgain() {
        let model = IslandLiveTextTickerModel()
        model.wingWidth = 226
        model.prime("Угу. Так, щас. А в каталог", now: 0)
        model.advance(now: 0.9)
        model.textArrived("Так, сейчас. А в каталог", now: 1)
        _ = animate(model, from: 1, through: 2.55)
        XCTAssertEqual(model.shownText, "Так, сейчас. А в каталог")
        model.textArrived("Так, сейчас. А в каталог.", now: 2.6)
        _ = animate(model, from: 2.6, through: 3.2)
        XCTAssertEqual(model.shownText, "Так, сейчас. А в каталог.")
    }

    private func visibleText(_ model: IslandLiveTextTickerModel) -> String {
        String(model.shownText.prefix(model.revealedGlyphCount))
    }

    private func animate(_ model: IslandLiveTextTickerModel, from: Double, through: Double) -> [String] {
        (0...Int(((through - from) * 60).rounded())).map { frame in
            model.advance(now: from + Double(frame) / 60)
            return visibleText(model)
        }
    }

    /// Words the provider took back before they were revealed never appear.
    @MainActor
    func testAGuessWithdrawnBeforeItWasRevealedIsNeverDrawn() {
        let model = IslandLiveTextTickerModel()
        model.wingWidth = 226
        model.prime("one two three", now: 0)
        model.advance(now: 1)
        model.textArrived("one two three unrevealed wrong guess", now: 1)
        model.textArrived("one two", now: 1.01)
        for text in animate(model, from: 1.02, through: 2.4) {
            XCTAssertEqual(text, "one two three")
        }
        // The provider keeps the shorter phrase: shown after the wait.
        XCTAssertEqual(animate(model, from: 2.4, through: 3.2).last, "one two")
    }

    /// A rewrite still waiting in the hold is not on screen either.
    @MainActor
    func testARewriteReplacedWhileItWaitsIsNeverDrawn() {
        let model = IslandLiveTextTickerModel()
        model.wingWidth = 226
        model.prime("one two three", now: 0)
        model.advance(now: 1)
        model.textArrived("alpha beta never spoken", now: 1)
        model.textArrived("alpha beta", now: 1.05)
        let frames = animate(model, from: 1.06, through: 2.4)
        XCTAssertFalse(frames.contains { $0.contains("never") || $0.contains("spo") })
        XCTAssertEqual(frames.last, "alpha beta")
        XCTAssertEqual(model.shownText, "alpha beta")
    }

    // MARK: - The plain line (Reduce Motion, scripts shaped as a whole line)

    func testThePlainLineShowsTheSameSnapshots() {
        let model = IslandPlainLiveTextModel()
        XCTAssertEqual(model.textArrived("مرحبا كيف حالك اليوم", now: 0), "مرحبا كيف حالك اليوم")
        // An earlier, shorter state of the phrase is not shown.
        XCTAssertEqual(model.textArrived("مرحبا كيف", now: 0.3), "مرحبا كيف حالك اليوم")
        XCTAssertTrue(model.isWaiting)
        XCTAssertEqual(model.textArrived("مرحبا كيف حالك اليوم يا صديقي", now: 0.6), "مرحبا كيف حالك اليوم يا صديقي")
        XCTAssertFalse(model.isWaiting)
        // A shorter phrase the provider keeps is shown after the wait.
        XCTAssertEqual(model.textArrived("مرحبا كيف حالك", now: 1), "مرحبا كيف حالك اليوم يا صديقي")
        XCTAssertNil(model.settled(now: 2.4))
        XCTAssertEqual(model.settled(now: 2.5), "مرحبا كيف حالك")
        XCTAssertFalse(model.isWaiting)
    }

    /// Snapshots can come faster than the view polls for a settled change.
    func testThePlainLineShowsAKeptChangeWhenTheNextSnapshotArrives() {
        let model = IslandPlainLiveTextModel()
        _ = model.textArrived("one two three four", now: 0)
        XCTAssertEqual(model.textArrived("one changed two three four", now: 1), "one two three four")
        XCTAssertEqual(
            model.textArrived("one changed two three four five", now: 2.6),
            "one changed two three four five"
        )
    }

    func testThePlainLineStartsFromTheProvidersText() {
        let model = IslandPlainLiveTextModel()
        XCTAssertEqual(model.textArrived("one two three", now: 5), "one two three")
        XCTAssertFalse(model.isWaiting)
    }

    func testTextWithoutSpacesAndAnEmptyTextPassThrough() {
        // One word per phrase: a rewrite is shown as it is, a cut is not.
        XCTAssertEqual(feed(["今日は天気", "明日は", ""]), ["今日は天気", "明日は", ""])
        XCTAssertEqual(feed(["今日は天気", "今日は", "今日は天気です"]), ["今日は天気", "今日は天気", "今日は天気です"])
    }

    func testAFirstWordThatChangesIsShownAtOnce() {
        XCTAssertEqual(feed(["Прив", "Приз", "Признаться"]), ["Прив", "Приз", "Признаться"])
    }

    func testZeroConfirmTimeShowsEverySnapshot() {
        var stabilizer = LiveTextStabilizer()
        stabilizer.confirmSeconds = 0
        _ = stabilizer.shows("один два три", now: 0)
        XCTAssertEqual(stabilizer.shows("один", now: 0.1), "один")
    }

    func testALongDictationIsComparedOnlyWhereItDiffers() {
        let start = String(repeating: "слово ", count: 2000)
        var stabilizer = LiveTextStabilizer()
        _ = stabilizer.shows(start + "и вот конец", now: 0)
        XCTAssertEqual(stabilizer.shows(start + "и вот", now: 0.3), start + "и вот конец")
        XCTAssertEqual(stabilizer.shows(start + "и вот конец фразы", now: 0.6), start + "и вот конец фразы")
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
