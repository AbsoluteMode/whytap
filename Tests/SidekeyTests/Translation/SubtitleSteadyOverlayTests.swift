import AppKit
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

    /// Plays the recorded OpenAI session event by event and records what the
    /// overlay would show after each one.
    private func snapshots() async throws -> [[SubtitleCaption.Row]] {
        let speech = FakeSpeechTranslation()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { FixtureSubtitleAudio() },
                                      openTranslator: { _, _ in speech })
        model.sourceCode = "en"
        model.targetCode = "ru"
        model.start()
        try await wait(model.phase == .listening)
        var shots: [[SubtitleCaption.Row]] = []
        for event in OpenAITranslateRecordedSession.events {
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
        XCTAssertGreaterThan(shots.count, 20)
        return shots
    }

    func testRowsOnlyAppearAtTheBottomAndNeverVanishFromTheMiddle() async throws {
        let shots = try await snapshots()
        for (before, after) in zip(shots, shots.dropFirst()) {
            let kept = before.map(\.id).filter { id in after.contains { $0.id == id } }
            // Old rows leave only from the top, in order...
            XCTAssertEqual(kept, Array(before.map(\.id).suffix(kept.count)),
                           "a row left from the middle or the bottom")
            // ...and new rows only come in below them.
            XCTAssertEqual(Array(after.map(\.id).prefix(kept.count)), kept, "a row was inserted above an old one")
        }
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
