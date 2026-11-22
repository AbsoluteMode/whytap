import AppKit
import SwiftUI
@testable import Sidekey
import XCTest

/// The overlay must read like the RealtimeTranslator caption: text already on
/// screen never jumps, rows only appear at the bottom, the live pair settles
/// in place, and Stop takes the first click.
// WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
@MainActor
final class SubtitleSteadyOverlayTests: XCTestCase {
    private func wait(_ condition: @autoclosure () -> Bool, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func text(_ translation: SubtitleCaption.Row.Translation) -> String {
        switch translation {
        case .text(let value), .live(let value): return value
        case .pending, .failed: return ""
        }
    }

    private typealias Event = (stream: OpenAITranslateRecordedSession.Stream, text: String, elapsed: Int)

    nonisolated private static var recorded: [Event] {
        OpenAITranslateRecordedSession.events.map { ($0.stream, $0.text, $0.elapsed) }
    }

    /// Plays a session event by event (the recorded OpenAI one by default)
    /// and records what the overlay would show after each one.
    private func snapshots(_ events: [Event] = recorded, minimum: Int = 20) async throws -> [[SubtitleCaption.Row]] {
        let speech = FakeSpeechTranslation()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { FixtureSubtitleAudio() },
                                      openTranslator: { _, _ in speech })
        model.sourceCode = "en"
        model.targetCode = "ru"
        model.start()
        try await wait(model.phase == .listening)
        var shots: [[SubtitleCaption.Row]] = []
        for event in events {
            switch event.stream {
            case .source: speech.pair.continuation.yield(.source(event.text, elapsedMs: event.elapsed))
            case .translation: speech.pair.continuation.yield(.translation(event.text, elapsedMs: event.elapsed))
            }
            try await Task.sleep(for: .milliseconds(12))
            let rows = SubtitleCaption.rows(lines: model.lines, live: model.live,
                                            liveTranslation: model.liveTranslation, liveID: model.liveID)
            if shots.last != rows { shots.append(rows) }
        }
        await model.cancel().value
        XCTAssertGreaterThanOrEqual(shots.count, minimum)
        return shots
    }

    /// Text on screen never moves: rows only come in at the bottom and leave
    /// at the top, and a row's original and translation only grow, through
    /// every cut, including when its live text settles.
    private func assertSteady(_ shots: [[SubtitleCaption.Row]], file: StaticString = #filePath, line: UInt = #line) {
        for (before, after) in zip(shots, shots.dropFirst()) {
            let kept = before.map(\.id).filter { id in after.contains { $0.id == id } }
            XCTAssertEqual(kept, Array(before.map(\.id).suffix(kept.count)),
                           "a row left from the middle or the bottom", file: file, line: line)
            XCTAssertEqual(Array(after.map(\.id).prefix(kept.count)), kept,
                           "a row was inserted above an old one", file: file, line: line)
            for row in before {
                guard let next = after.first(where: { $0.id == row.id }) else { continue }
                XCTAssertTrue(next.source.hasPrefix(row.source),
                              "original \"\(row.source)\" became \"\(next.source)\"", file: file, line: line)
                XCTAssertTrue(text(next.translation).hasPrefix(text(row.translation)),
                              "translation \"\(text(row.translation))\" became \"\(text(next.translation))\"",
                              file: file, line: line)
            }
        }
    }

    func testRowsOnlyAppearAtTheBottomAndNeverVanishFromTheMiddle() async throws {
        assertSteady(try await snapshots())
    }

    func testTheLivePairSettlesInPlaceUnderTheSameIdentity() async throws {
        let shots = try await snapshots()
        var settled = 0
        for (before, after) in zip(shots, shots.dropFirst()) {
            guard let live = before.last, live.isLive,
                  let same = after.first(where: { $0.id == live.id }), !same.isLive else { continue }
            settled += 1
            XCTAssertTrue(text(same.translation).hasPrefix(text(live.translation)),
                          "the settled translation rewrote what the live row showed")
        }
        XCTAssertGreaterThan(settled, 3, "the live row should become the committed pair, not a new row")
    }

    func testShownTranslationOnlyGrows() async throws {
        let shots = try await snapshots()
        for (before, after) in zip(shots, shots.dropFirst()) {
            for row in before {
                guard let next = after.first(where: { $0.id == row.id }) else { continue }
                let shown = text(row.translation)
                XCTAssertTrue(text(next.translation).hasPrefix(shown),
                              "\"\(shown)\" became \"\(text(next.translation))\"")
            }
        }
    }

    /// The original runs far ahead of a short translation: its whole first
    /// sentence is on screen when the translation's sentence closes at an
    /// earlier audio position. The settled pair keeps all of it.
    func testAnOriginalAheadOfItsTranslationStaysInItsRow() async throws {
        let shots = try await snapshots([
            (.source, " Welcome to", 400),
            (.translation, "Добро пожаловать на лекцию.", 1_000),
            (.source, " the lecture. Today we", 4_000),
            (.translation, " Сегодня", 4_100),
            (.source, " talk about", 4_600),
            (.translation, " мы поговорим", 4_800)
        ], minimum: 4)
        assertSteady(shots)
        let first = try XCTUnwrap(shots.last?.first)
        XCTAssertEqual(first.source, "Welcome to the lecture.")
        XCTAssertEqual(text(first.translation), "Добро пожаловать на лекцию.")
        XCTAssertEqual(shots.last?.last?.source, "Today we talk about")
    }

    /// A long translation without a sentence end closes at a clause; the
    /// words after that clause were already on screen and stay in the row.
    func testALongTranslationClosesAfterTheWordsItShowed() async throws {
        var events: [Event] = [(.source, " So the first part of this, and then a lot more words", 300),
                               (.translation, "Итак, первая часть этого,", 500)]
        for (index, word) in Array(repeating: ["и", "потом", "ещё", "очень", "много", "разных", "слов"], count: 4)
            .joined().enumerated() {
            events.append((.translation, " " + word, 600 + index * 80))
        }
        let shots = try await snapshots(events, minimum: 10)
        assertSteady(shots)
        let rows = try XCTUnwrap(shots.last)
        XCTAssertGreaterThan(rows.count, 1, "the long translation should have closed at least once")
        XCTAssertTrue(text(rows[0].translation).count >= SubtitleSpeechPairer.longTranslation - 10,
                      "it closed at an early clause and moved shown words to the next row")
    }

    func testThePairerKeepsWhatTheLiveRowShowedThroughAPauseCut() {
        var pairer = SubtitleSpeechPairer()
        pairer.addSource(" Welcome to", elapsedMs: 400)
        pairer.addSource(" the lecture. Today", elapsedMs: 4_000)
        pairer.addTranslation("Добро пожаловать", elapsedMs: 1_000, now: 0)
        XCTAssertEqual(pairer.showLive().source, "Welcome to the lecture.")
        // The speaker pauses: the translation closes at its audio position.
        let pairs = pairer.take(now: SubtitleSpeechPairer.pause + 0.1)
        XCTAssertEqual(pairs, [.init(source: "Welcome to the lecture.", translation: "Добро пожаловать")])
        XCTAssertEqual(pairer.liveSourceHead, "Today")
    }

    func testThePairerKeepsShownTranslationThroughAClauseCut() {
        var pairer = SubtitleSpeechPairer()
        pairer.addSource(" One", elapsedMs: 100)
        let head = "Первая часть этой длинной фразы, " + String(repeating: "слово ", count: 20)
        pairer.addTranslation(head + "ещё", elapsedMs: 500, now: 0)
        let shown = pairer.showLive().translation
        XCTAssertTrue(shown.count >= SubtitleSpeechPairer.longTranslation - 15)
        pairer.addTranslation(" два три", elapsedMs: 600, now: 0.1)
        let pair = try? XCTUnwrap(pairer.take(now: 0.2).first)
        XCTAssertTrue(pair?.translation.hasPrefix(shown) == true, "\(pair?.translation ?? "nil") lost \(shown)")
    }

    func testTheLiveOriginalStopsAtItsFirstSentenceEnd() {
        var pairer = SubtitleSpeechPairer()
        pairer.addSource(" Welcome to the lecture.", elapsedMs: 800)
        pairer.addSource(" Today we", elapsedMs: 1_600)
        XCTAssertEqual(pairer.liveSource, "Welcome to the lecture. Today we")
        // "Today we" is the next pair's original: shown there, not here.
        XCTAssertEqual(pairer.liveSourceHead, "Welcome to the lecture.")
        var short = SubtitleSpeechPairer()
        short.addSource(" Still speaking", elapsedMs: 400)
        XCTAssertEqual(short.liveSourceHead, "Still speaking")
    }

    func testALongLiveOriginalIsNeverCutAtTheFront() {
        let heard = String(repeating: "word ", count: 30) + "last words here"
        let row = SubtitleCaption.rows(lines: [], live: heard).first
        XCTAssertEqual(row?.source, heard, "a sliding window moved every word on each update")
    }

    func testTheColumnSplitDependsOnlyOnTheWidth() {
        let layout = SteadyPairsLayout(rowSpacing: 8, columnSpacing: 18, sourceFraction: TranslationView.sourceFraction,
                                       size: CGSize(width: TranslationView.overlayContentWidth,
                                                    height: TranslationView.captionHeight),
                                       inset: TranslationView.bandInset)
        let columns = layout.columns(width: TranslationView.overlayContentWidth)
        XCTAssertEqual(columns.source + columns.translation + 18 + 2 * TranslationView.bandInset.width,
                       TranslationView.overlayContentWidth, accuracy: 1)
        XCTAssertGreaterThan(columns.translation, columns.source)
        XCTAssertEqual(layout.columns(width: TranslationView.overlayContentWidth), columns)
    }

    /// A long original without punctuation must not push the newest row's
    /// translation out of the caption: a column at most `columnCap` high
    /// shows its newest lines, and the row then fits below the top fade.
    func testALongColumnShowsItsNewestLinesAndLeavesTheTranslationInSight() {
        for height in [TranslationView.captionHeight, TranslationView.stoppedCaptionHeight] {
            let layout = SteadyPairsLayout(rowSpacing: 8, columnSpacing: 18, sourceFraction: TranslationView.sourceFraction,
                                           size: CGSize(width: TranslationView.overlayContentWidth, height: height),
                                           inset: TranslationView.bandInset)
            let cap = layout.columnCap
            XCTAssertLessThanOrEqual(cap + 2 * TranslationView.bandInset.height, height * (1 - SteadyPairsLayout.topFade))
            // A clipped original: its first baseline is above the column.
            let row = SteadyPairsLayout.row(source: .init(height: cap, firstBaseline: -400),
                                            translation: .init(height: 24, firstBaseline: 19),
                                            cap: cap, inset: TranslationView.bandInset.height)
            XCTAssertEqual(row.translationY, 0, "the translation must start at the top of the visible row")
            XCTAssertLessThanOrEqual(row.height, height * (1 - SteadyPairsLayout.topFade))
            // Short columns still share their first baseline.
            let short = SteadyPairsLayout.row(source: .init(height: 20, firstBaseline: 15),
                                              translation: .init(height: 24, firstBaseline: 19),
                                              cap: cap, inset: 3)
            XCTAssertEqual(short.sourceY, 4)
        }
        let long = String(repeating: "and then the speaker kept going ", count: 20)
        let column = NSHostingView(rootView: Text(long).font(.system(size: 15))
            .modifier(NewestLinesColumn(cap: 100)).frame(width: 240))
        XCTAssertLessThanOrEqual(column.fittingSize.height, 100.5)
        let short = NSHostingView(rootView: Text("Hello").font(.system(size: 15))
            .modifier(NewestLinesColumn(cap: 100)).frame(width: 240))
        XCTAssertLessThan(short.fittingSize.height, 40)
    }

    /// From Connecting to the end of Finishing the caption keeps one size,
    /// whatever it shows: no audio yet, no words yet, or Stop before them.
    func testTheRunningBoxKeepsOneSizeInEveryPhase() {
        for phase in [SubtitlePhase.connecting, .listening, .finishing] {
            for hasRows in [false, true] {
                XCTAssertEqual(TranslationView.overlayCaption(phase: phase, hasRows: hasRows, hasIssue: false),
                               .fixed(TranslationView.captionHeight), "\(phase), rows: \(hasRows)")
            }
        }
        XCTAssertEqual(TranslationView.overlayCaption(phase: .idle, hasRows: true, hasIssue: false),
                       .fixed(TranslationView.stoppedCaptionHeight))
        XCTAssertEqual(TranslationView.overlayCaption(phase: .idle, hasRows: false, hasIssue: false), .hidden)
        XCTAssertEqual(TranslationView.overlayCaption(phase: .failed, hasRows: true, hasIssue: true), .hugging)
        // Stop before the first words still says what is happening.
        XCTAssertEqual(SubtitleCaption.status(hasRows: false, phase: .finishing, issue: nil), "Finishing…")
    }

    /// The panel can be resized down to its minimum width: the caption takes
    /// the width it is given, and its columns still depend only on it.
    func testTheCaptionFitsANarrowPanel() {
        let layout = SteadyPairsLayout(rowSpacing: 8, columnSpacing: 18, sourceFraction: TranslationView.sourceFraction,
                                       size: CGSize(width: TranslationView.overlayContentWidth,
                                                    height: TranslationView.captionHeight),
                                       inset: TranslationView.bandInset)
        let narrow: CGFloat = 480 - 2 * 10 - 2 * 16
        XCTAssertEqual(layout.width(proposed: narrow), narrow)
        XCTAssertEqual(layout.width(proposed: nil), TranslationView.overlayContentWidth)
        XCTAssertEqual(layout.width(proposed: .infinity), TranslationView.overlayContentWidth)
        XCTAssertEqual(layout.width(proposed: 2_000), TranslationView.overlayContentWidth)
        let columns = layout.columns(width: narrow)
        XCTAssertEqual(columns.source + columns.translation + 18 + 2 * TranslationView.bandInset.width, narrow, accuracy: 1)
        XCTAssertEqual(layout.columns(width: narrow), columns)
    }

    func testTheOverlayTakesTheFirstClickWithoutBeingKey() throws {
        let controller = TranslationWindowController(textModel: TextTranslationModel(makeService: { FixtureTranslator() }),
                                                     subtitleModel: LiveSubtitleModel(makeAudio: { FixtureSubtitleAudio() }),
                                                     openSettings: { _ in }, activityChanged: { _ in })
        let panel = try XCTUnwrap(controller.window)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(panel.contentView?.acceptsFirstMouse(for: nil), true,
                       "Stop and × must work on the first click while the overlay is not key")
    }
}
