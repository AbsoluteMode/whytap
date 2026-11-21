import Foundation
import XCTest
@testable import Sidekey

/// A translator whose answers the test releases phrase by phrase, in any order.
private actor PhraseGate: TextTranslating {
    struct Request: Equatable { let text: String; let previous: SubtitlePair? }
    private var waiters: [String: CheckedContinuation<String, Error>] = [:]
    private(set) var requests: [Request] = []
    private(set) var concurrent = 0
    private(set) var maxConcurrent = 0

    func translate(_ text: String, target: TranslationTarget) async throws -> String {
        try await translatePhrase(text, previous: nil, target: target)
    }

    func translatePhrase(_ text: String, previous: SubtitlePair?, target: TranslationTarget) async throws -> String {
        requests.append(.init(text: text, previous: previous))
        concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent)
        defer { concurrent -= 1 }
        // Deliberately ignores cancellation, like a request already on the wire.
        return try await withCheckedThrowingContinuation { waiters[text] = $0 }
    }

    func answer(_ text: String, _ value: String) { waiters.removeValue(forKey: text)?.resume(returning: value) }
    func fail(_ text: String, _ error: Error) { waiters.removeValue(forKey: text)?.resume(throwing: error) }
    var waiting: [String] { Array(waiters.keys) }
}

@MainActor
final class SubtitlePhrasePairTests: XCTestCase {
    // MARK: Splitting the stream into phrases

    func testContinuousSpeechIsCutIntoWholeSentencesWithoutWaitingForAPause() {
        var segmenter = SubtitleSegmenter()
        // Soniox-style subword finals, no pause between the sentences.
        for (index, token) in ["Wel", "come", " to", " the", " show.", " To", "day", " we", " have", " a", " spe"].enumerated() {
            segmenter.append(token, join: .verbatim, now: Double(index) * 0.1)
        }
        XCTAssertEqual(segmenter.take(now: 1.05), "Welcome to the show.", "A sentence end inside the text cuts at once")
        XCTAssertNil(segmenter.take(now: 1.1), "The rest is still growing")
        segmenter.append("cial", join: .verbatim, now: 1.2)
        segmenter.append(" guest.", join: .verbatim, now: 1.3)
        XCTAssertNil(segmenter.take(now: 1.35), "A trailing sentence end waits briefly for the next word")
        XCTAssertEqual(segmenter.take(now: 1.5), "Today we have a special guest.")
    }

    func testALongPhraseWithoutPunctuationIsCutAtAClauseOrWordBoundaryNeverInsideAWord() {
        var segmenter = SubtitleSegmenter()
        let opening = "so what we are going to look at today in quite some detail, is how the"
        segmenter.append(opening, join: .verbatim, now: 0)
        segmenter.append(" neural net", join: .verbatim, now: 0.3)
        segmenter.append("work is struc", join: .verbatim, now: 0.5)
        XCTAssertEqual(segmenter.take(now: 0.55), "so what we are going to look at today in quite some detail,",
                       "A long phrase is cut after its last clause mark")
        segmenter.append("tured inside and what every single layer of it is actually doing for us", join: .verbatim, now: 4.0)
        let cut = segmenter.take(now: 4.1)
        XCTAssertNotNil(cut)
        XCTAssertFalse(cut!.hasSuffix("struc"), "Never cut inside a word")
        XCTAssertTrue(cut!.hasPrefix("is how the neural network is structured"), cut!)
        XCTAssertFalse(segmenter.pending.isEmpty, "The last word waits: it may still be growing")
        XCTAssertEqual(segmenter.take(now: 5), "for us", "A length cut never ends on a function word; a pause releases the rest")
    }

    func testAbbreviationsAndDecimalsDoNotEndASentence() {
        var segmenter = SubtitleSegmenter()
        segmenter.append("Dr. Smith said 3.5 percent, e.g. this one", join: .verbatim, now: 0)
        XCTAssertNil(segmenter.take(now: 0.2))
        XCTAssertEqual(segmenter.take(now: 0.7), "Dr. Smith said 3.5 percent, e.g. this one")
    }

    func testWordProvidersPauseAndStopReleaseTheRest() {
        var segmenter = SubtitleSegmenter()
        segmenter.append("we will see", join: .wordBoundary, now: 0)
        segmenter.append("why", join: .wordBoundary, now: 0.2)
        XCTAssertNil(segmenter.take(now: 0.5))
        XCTAssertEqual(segmenter.take(now: 0.85), "we will see why", "A pause in the finals closes the phrase")
        segmenter.append("and then", join: .wordBoundary, now: 1)
        XCTAssertEqual(segmenter.take(now: 1.01, force: true), "and then")
    }

    // MARK: Empty or broken recognition

    func testEmptyAndPunctuationOnlyRecognitionMakesNoPairs() async throws {
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        let gate = PhraseGate()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { audio },
                                      open: { _ in upstream }, makeService: { gate })
        model.start()
        await waitUntil { model.phase == .listening }
        upstream.pair.continuation.yield(.partial(""))
        upstream.pair.continuation.yield(.final(""))
        upstream.pair.continuation.yield(.final("   "))
        upstream.pair.continuation.yield(.final("..."))
        upstream.pair.continuation.yield(.final(" — "))
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(model.lines.isEmpty)
        XCTAssertEqual(model.live, "")
        XCTAssertEqual(model.phase, .listening)
        let requests = await gate.requests
        XCTAssertTrue(requests.isEmpty, "Noise is never a paid request")
        XCTAssertEqual(SubtitleCaption.status(hasRows: !SubtitleCaption.rows(lines: model.lines, live: model.live).isEmpty,
                                              phase: model.phase, issue: model.issue), "Waiting for speech…")
        await model.cancel().value
    }

    // MARK: Pairs stay paired

    func testRevisedPartialsNeverChangeACommittedPairAndShowAsTheLiveOriginal() async throws {
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        let gate = PhraseGate()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { audio },
                                      open: { _ in upstream }, makeService: { gate })
        model.start()
        await waitUntil { model.phase == .listening }
        upstream.pair.continuation.yield(.partial("Hello wor"))
        await waitUntil { model.live == "Hello wor" }
        XCTAssertTrue(model.lines.isEmpty, "A partial is display only")
        upstream.pair.continuation.yield(.partial("Hello world, this"))
        await waitUntil { model.live == "Hello world, this" }
        upstream.pair.continuation.yield(.final("Hello world."))
        upstream.pair.continuation.yield(.partial(" This is"))
        await waitUntil { model.lines.count == 1 }
        XCTAssertEqual(model.lines[0].source, "Hello world.")
        // The provider rewrites its partial several times; the pair stays put.
        upstream.pair.continuation.yield(.partial(" Thus is"))
        upstream.pair.continuation.yield(.partial(" This is fine"))
        await waitUntil { model.live == "This is fine" }
        await waitUntil { await gate.waiting.contains("Hello world.") }
        await gate.answer("Hello world.", "Привет, мир.")
        await waitUntil { model.lines[0].translation != nil }
        XCTAssertEqual(model.lines.map(\.source), ["Hello world."])
        XCTAssertEqual(model.lines[0].translation, "Привет, мир.")
        let rows = SubtitleCaption.rows(lines: model.lines, live: model.live)
        XCTAssertEqual(rows.map(\.source), ["Hello world.", "This is fine"])
        XCTAssertEqual(rows.map(\.translation), [.text("Привет, мир."), .pending])
        await model.cancel().value
    }

    func testPhrasesTranslateInParallelAndALateAnswerFillsOnlyItsOwnPair() async throws {
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        let gate = PhraseGate()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { audio },
                                      open: { _ in upstream }, makeService: { gate })
        model.start()
        await waitUntil { model.phase == .listening }
        upstream.pair.continuation.yield(.final("First idea. Second idea. Third idea. Fourth"))
        await waitUntil { model.lines.count == 3 }
        await waitUntil { await gate.waiting.count == 3 }
        let maxConcurrent = await gate.maxConcurrent
        XCTAssertEqual(maxConcurrent, LiveSubtitleModel.maxConcurrentTranslations,
                       "Three phrases are on their way at once, not one after another")
        // The newest answer comes first, the oldest last.
        await gate.answer("Third idea.", "Третья мысль.")
        await gate.answer("Second idea.", "Вторая мысль.")
        await waitUntil { model.lines[1].translation != nil && model.lines[2].translation != nil }
        XCTAssertNil(model.lines[0].translation)
        await gate.answer("First idea.", "Первая мысль.")
        await waitUntil { model.lines[0].translation != nil }
        XCTAssertEqual(model.lines.map(\.source), ["First idea.", "Second idea.", "Third idea."])
        XCTAssertEqual(model.lines.map(\.translation), ["Первая мысль.", "Вторая мысль.", "Третья мысль."])

        // The next phrase carries the newest finished pair as context.
        upstream.pair.continuation.yield(.final(" thought."))
        await waitUntil { await gate.waiting.contains("Fourth thought.") }
        let last = await gate.requests.last
        XCTAssertEqual(last?.previous, SubtitlePair(source: "Third idea.", translation: "Третья мысль."))
        await model.cancel().value
        await gate.answer("Fourth thought.", "late")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.lines.last?.translation, "A cancelled session ignores late answers")
    }

    // MARK: Translation timeout or error

    func testATimedOutOrFailedPhraseKeepsItsOriginalAndTheOverlayGoesOn() async throws {
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        let gate = PhraseGate()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), phraseDeadline: .milliseconds(300),
                                      makeAudio: { audio }, open: { _ in upstream }, makeService: { gate })
        model.start()
        await waitUntil { model.phase == .listening }
        upstream.pair.continuation.yield(.final("Slow phrase. Broken phrase. Good phrase. "))
        await waitUntil { await gate.waiting.count == 3 }
        await gate.fail("Broken phrase.", OpenRouterLLMError.unexpectedStatus(503, nil))
        await gate.answer("Good phrase.", "Хорошая фраза.")
        // "Slow phrase." never answers: its deadline marks it.
        await waitUntil { model.lines.allSatisfy(\.isSettled) }
        XCTAssertEqual(model.phase, .listening, "One slow or failed phrase never stops subtitles")
        XCTAssertNil(model.issue)
        let rows = SubtitleCaption.rows(lines: model.lines, live: "")
        XCTAssertEqual(rows.map(\.source), ["Slow phrase.", "Broken phrase.", "Good phrase."])
        XCTAssertEqual(rows.map(\.translation), [.failed, .failed, .text("Хорошая фраза.")])

        // A later answer of the timed-out phrase changes nothing.
        await gate.answer("Slow phrase.", "Медленная фраза.")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.lines[0].translation)

        // The next phrase still translates.
        upstream.pair.continuation.yield(.final("Next one. "))
        await waitUntil { await gate.waiting.contains("Next one.") }
        await gate.answer("Next one.", "Следующая.")
        await waitUntil { model.lines.last?.translation == "Следующая." }
        await model.cancel().value
    }

    func testARefusedKeyStopsTheSessionWithTheFix() async throws {
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        let gate = PhraseGate()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { audio },
                                      open: { _ in upstream }, makeService: { gate })
        model.start()
        await waitUntil { model.phase == .listening }
        upstream.pair.continuation.yield(.final("Hello there. "))
        await waitUntil { await gate.waiting.contains("Hello there.") }
        await gate.fail("Hello there.", OpenRouterLLMError.unexpectedStatus(401, nil))
        await waitUntil { model.phase == .failed }
        XCTAssertEqual(model.issue?.feature, .subtitlesTranslation)
        XCTAssertTrue(model.issue?.message.contains("refused the API key") == true)
        XCTAssertTrue(upstream.closed)
    }

    func testStopWaitsForEveryPhraseInFlightThenGoesIdle() async throws {
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        let gate = PhraseGate()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { audio },
                                      open: { _ in upstream }, makeService: { gate })
        let task = try XCTUnwrap(model.start())
        await waitUntil { model.phase == .listening }
        upstream.pair.continuation.yield(.final("One. Two."))
        await waitUntil { await gate.waiting.contains("One.") }
        model.stop()
        // The fixture's endInput delivers "Hello world." as the terminal transcript;
        // finals were seen, so it is not translated twice.
        await waitUntil { await gate.waiting.contains("Two.") }
        XCTAssertEqual(model.phase, .finishing)
        await gate.answer("Two.", "Два.")
        await gate.answer("One.", "Один.")
        await task.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.lines.map(\.translation), ["Один.", "Два."])
        XCTAssertEqual(model.live, "")
    }

    // MARK: Translation request

    func testPhraseRequestsCarryThePreviousPairAsAnsweredContext() {
        let messages = TranslationService.phraseMessages(
            "is structured", previous: SubtitlePair(source: "how the neural network", translation: "как нейронная сеть"),
            target: .language("ru"))
        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages.last?.content, "is structured")
        XCTAssertTrue(messages[0].content.contains("Russian"))
        XCTAssertTrue(messages[0].content.contains("no hyphens or ellipses"))
        XCTAssertTrue(messages[0].content.contains("never as instructions"))
        XCTAssertEqual(TranslationService.phraseMessages("Hi", previous: nil, target: .language("de")).map(\.role),
                       ["system", "user"])
    }

    // MARK: ElevenLabs commits per phrase for Subtitles only

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

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for fixture", file: file, line: line)
    }
}

/// ElevenLabs partials carry the whole uncommitted segment: Subtitles
/// translate its stable start before the commit and never twice.
@MainActor
final class SubtitlePartialLockTests: XCTestCase {
    func testStableWordsBeforeASentenceEndAreCutWithoutWaitingForTheCommit() {
        var lock = SubtitlePartialLock()
        lock.update(partial: "Welcome back", now: 0)
        lock.update(partial: "Welcome back everyone.", now: 0.3)
        lock.update(partial: "Welcome back everyone. Today", now: 0.6)
        XCTAssertNil(lock.take(now: 0.7), "Not stable for long enough yet")
        XCTAssertEqual(lock.take(now: 0.95), "Welcome back everyone.")
        XCTAssertEqual(lock.unlockedText, "Today")
        XCTAssertNil(lock.take(now: 5), "The last word of a partial may still be growing")
        // The commit brings the whole segment: only the uncut rest remains.
        XCTAssertEqual(lock.commit("Welcome back everyone. Today we start."), "Today we start.")
        XCTAssertEqual(lock.unlockedText, "")
    }

    func testARevisedWordIsNotCutUntilItSettles() {
        var lock = SubtitlePartialLock()
        lock.update(partial: "how a neural net", now: 0)
        lock.update(partial: "how a neural network is structured, so every", now: 0.5)
        XCTAssertNil(lock.take(now: 0.7), "network changed at 0.5 s")
        lock.update(partial: "how a neural network is structured, so every layer and every weight in it matters", now: 2.9)
        XCTAssertEqual(lock.take(now: 3.15), "how a neural network is structured,",
                       "A long phrase is cut at its clause mark once stable")
    }

    func testCommitAlignmentDropsExactlyTheWordsAlreadyCut() {
        // Exact prefix.
        XCTAssertEqual(SubtitlePartialLock.alignedEnd(of: ["So", "we", "start."], in: ["So", "we", "start.", "Then"]), 3)
        // The commit removed a filler from the cut part.
        XCTAssertEqual(SubtitlePartialLock.alignedEnd(of: ["So", "um", "we", "start."], in: ["So", "we", "start.", "Then", "more"]), 3)
        // The commit fixed the last cut word.
        XCTAssertEqual(SubtitlePartialLock.alignedEnd(of: ["the", "neural", "net"], in: ["the", "neural", "network", "is"]), 3)
        // Nothing recognisable: fall back to the cut length, never past the end.
        XCTAssertEqual(SubtitlePartialLock.alignedEnd(of: ["a", "b", "c"], in: ["x", "y"]), 2)
        XCTAssertEqual(SubtitlePartialLock.alignedEnd(of: ["one"], in: []), 0)
    }

    /// Replays a real ElevenLabs `scribe_v3_live` session (its partials revise
    /// punctuation, drop and restore words) through the same steps as
    /// LiveSubtitleModel: every committed word lands in a phrase once, in
    /// order, and long before the provider's commit.
    func testRecordedElevenLabsTakeIsPairedWholeAndEarly() throws {
        var lock = SubtitlePartialLock()
        var segmenter = SubtitleSegmenter()
        var phrases: [(text: String, at: Double)] = []
        var committedWords: [(word: String, at: Double)] = []
        func flush(_ now: Double, force: Bool = false) {
            while let phrase = segmenter.take(now: now, force: force) { phrases.append((phrase, now)) }
            guard segmenter.pending.isEmpty else { return }
            while let phrase = lock.take(now: now) { phrases.append((phrase, now)) }
        }
        let events = ElevenLabsRecordedTake.events
        var clock = 0.0
        for event in events {
            while clock + 0.1 < event.at { clock += 0.1; flush(clock) }
            clock = event.at
            switch event.kind {
            case .partial:
                lock.update(partial: event.text, now: event.at)
                flush(event.at)
            case .committed:
                committedWords += event.text.split(separator: " ").map { (String($0), event.at) }
                segmenter.append(lock.commit(event.text), join: .wordBoundary, now: event.at)
                flush(event.at, force: true)
            }
        }
        flush(clock + 5, force: true)

        let key = { (text: String) in text.split(separator: " ").map { SubtitlePartialLock.normalized(String($0)) }.filter { !$0.isEmpty } }
        let phraseWords = phrases.flatMap { key($0.text) }
        let spoken = committedWords.map { SubtitlePartialLock.normalized($0.word) }.filter { !$0.isEmpty }
        // Word-level edit distance between what was paired and what was said.
        var row = Array(0...spoken.count)
        for (i, word) in phraseWords.enumerated() {
            var next = [i + 1]
            for j in 1...spoken.count {
                next.append(min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (word == spoken[j - 1] ? 0 : 1)))
            }
            row = next
        }
        let edits = row[spoken.count]
        XCTAssertLessThanOrEqual(edits, 3, "Paired words must match the commit: \(phrases.map(\.text))")
        XCTAssertFalse(phrases.contains { $0.text.hasSuffix("-") }, "No phrase ends in a cut word")

        // When text reaches translation: each phrase's cut time, weighted by its
        // words, against the commit times of the same words.
        let pairedAt = phrases.reduce(0.0) { $0 + Double(key($1.text).count) * $1.at } / Double(max(1, phraseWords.count))
        let committedAt = committedWords.reduce(0.0) { $0 + $1.at } / Double(max(1, committedWords.count))
        let firstPhrase = phrases.first?.at ?? .infinity
        // Per phrase: from the moment the whole phrase is in a partial to its
        // cut (now), and to the provider commit that carried it (before).
        var cutDelays: [Double] = [], commitDelays: [Double] = []
        for phrase in phrases {
            let wanted = key(phrase.text)
            guard !wanted.isEmpty else { continue }
            let heard = events.first { event in
                let have = key(event.text)
                return have.count >= wanted.count
                    && (0...(have.count - wanted.count)).contains { Array(have[$0..<($0 + wanted.count)]) == wanted }
            }?.at ?? phrase.at
            let commit = events.first { $0.kind == .committed && $0.at >= heard }?.at ?? phrase.at
            cutDelays.append(phrase.at - heard); commitDelays.append(commit - heard)
        }
        let median = { (values: [Double]) in values.sorted()[values.count / 2] }
        let report = String(format: "Recorded ElevenLabs take (%d words, %.1f s): first phrase at %.2f s (first commit %.2f s); "
                            + "words reach translation on average at %.2f s instead of %.2f s; a heard phrase goes to translation "
                            + "after a median %.2f s (max %.2f s) instead of %.2f s (max %.2f s) waiting for the commit; "
                            + "%d phrases; %d word edits.",
                            spoken.count, events.last?.at ?? 0, firstPhrase,
                            events.first { $0.kind == .committed }?.at ?? 0, pairedAt, committedAt,
                            median(cutDelays), cutDelays.max() ?? 0, median(commitDelays), commitDelays.max() ?? 0,
                            phrases.count, edits)
        print(report)
        print(phrases.map { String(format: "%.1f «%@»", $0.at, $0.text) }.joined(separator: "\n"))
        if let path = ProcessInfo.processInfo.environment["WHYTAP_SUBTITLE_REPLAY_OUT"] {
            try (report + "\n" + phrases.map { String(format: "%.1f s  %@", $0.at, $0.text) }.joined(separator: "\n"))
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertLessThan(firstPhrase, 3, "The first phrase does not wait for Scribe's ~36 s commit")
        XCTAssertLessThan(pairedAt, committedAt - 10)
    }

    func testElevenLabsStyleSessionPairsEveryWordOnceAndInOrder() async throws {
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        upstream.finalsJoin = .wordBoundary
        upstream.spansSegment = true
        let model = LiveSubtitleModel(flushInterval: .milliseconds(20), makeAudio: { audio },
                                      open: { _ in upstream }, makeService: { FixtureTranslator() })
        model.start()
        await waitUntil { model.phase == .listening }
        upstream.pair.continuation.yield(.partial("Welcome back everyone. Today"))
        await waitUntil { model.lines.count == 1 }
        XCTAssertEqual(model.lines[0].source, "Welcome back everyone.", "Cut from the stable partial, before any commit")
        XCTAssertEqual(model.live, "Today")
        upstream.pair.continuation.yield(.partial("Welcome back everyone. Today we start"))
        upstream.pair.continuation.yield(.final("Welcome back everyone. Today we start."))
        await waitUntil { model.lines.count == 2 }
        XCTAssertEqual(model.lines.map(\.source), ["Welcome back everyone.", "Today we start."])
        upstream.pair.continuation.yield(.partial("And then"))
        await waitUntil { model.live == "And then" }
        await waitUntil { model.lines.allSatisfy { $0.translation != nil } }
        XCTAssertEqual(model.lines.map(\.translation), ["Перевод: Welcome back everyone.", "Перевод: Today we start."])
        await model.cancel().value
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for fixture", file: file, line: line)
    }
}
