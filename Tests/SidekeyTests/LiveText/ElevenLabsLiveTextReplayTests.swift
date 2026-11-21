import XCTest
@testable import Sidekey

/// Replays a recorded ElevenLabs take through the same join the streaming
/// session uses and the wing's ticker, frame by frame.
final class ElevenLabsLiveTextReplayTests: XCTestCase {
    struct Frame {
        let at: Double
        let text: String
        let width: CGFloat
        let xs: [CGFloat]
    }

    @MainActor
    static func replay(wing: CGFloat = 226, hold: TimeInterval? = nil) -> [Frame] {
        let model = IslandLiveTextTickerModel()
        if let hold { model.rewriteHoldSeconds = hold }
        model.wingWidth = wing
        model.prime("", now: 0)
        var committed = ""
        var last = ""
        var next = 0
        var frames: [Frame] = []
        let events = ElevenLabsRecordedTake.events
        let end = (events.last?.at ?? 0) + 3
        var frame = 0
        while Double(frame) / 60 < end {
            let now = Double(frame) / 60
            while next < events.count, events[next].at <= now {
                let event = events[next]
                next += 1
                let text: String
                switch event.kind {
                case .partial:
                    text = DirectProviderStreamingSession.appendingLiveTranscriptSegment(
                        event.text, to: committed, join: .wordBoundary)
                case .committed:
                    committed = DirectProviderStreamingSession.appendingLiveTranscriptSegment(
                        event.text, to: committed, join: .wordBoundary)
                    text = committed
                }
                if text != last {
                    last = text
                    model.textArrived(text, now: event.at)
                }
            }
            let width = model.advance(now: now)
            let shown = model.shownText
            let count = model.revealedGlyphCount
            frames.append(Frame(at: now, text: String(shown.prefix(count)), width: width,
                                xs: (0..<count).map { model.glyphX(at: $0) }))
            frame += 1
        }
        return frames
    }

    /// The largest move to the right, in points per frame, of a letter that
    /// was on screen and did not change. Scrolling moves letters left.
    static func backwardMotion(_ frames: [Frame], wing: CGFloat) -> (points: CGFloat, at: Double) {
        var worst: (points: CGFloat, at: Double) = (0, 0)
        for (before, after) in zip(frames, frames.dropFirst()) {
            let old = Array(before.text), new = Array(after.text)
            let shortest = min(old.count, new.count)
            var prefix = 0
            while prefix < shortest, old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < shortest - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            for index in 0..<prefix where before.xs[index] > -8 && before.xs[index] < wing {
                let moved = after.xs[index] - before.xs[index]
                if moved > worst.points { worst = (moved, after.at) }
            }
            for offset in 0..<suffix {
                let from = old.count - 1 - offset, to = new.count - 1 - offset
                guard before.xs[from] > -8, before.xs[from] < wing else { continue }
                let moved = after.xs[to] - before.xs[from]
                if moved > worst.points { worst = (moved, after.at) }
            }
        }
        return worst
    }

    /// The recorded take: Scribe removed a repeated "чем стоит," (66 pt), a
    /// false start ", ну, как мы будем" (111 pt) and for a moment cut the end
    /// of the phrase (147 pt). Each made the whole line travel back.
    @MainActor
    func testTheRecordedTakeNeverMovesVisibleTextBackwards() {
        let wing: CGFloat = 226
        let frames = Self.replay(wing: wing)
        let worst = Self.backwardMotion(frames, wing: wing)
        XCTAssertLessThan(worst.points, 0.75, "visible text moved back at \(worst.at) s")
    }

    @MainActor
    func testTheRecordedTakeEndsOnTheProvidersTextWithItsEndInView() throws {
        let wing: CGFloat = 226
        let last = try XCTUnwrap(Self.replay(wing: wing).last)
        let committed = ElevenLabsRecordedTake.events.filter { $0.kind == .committed }.map(\.text)
        XCTAssertEqual(last.text, committed.joined(separator: " "))
        let tip = try XCTUnwrap(last.xs.last)
        XCTAssertLessThan(tip, wing)
        XCTAssertGreaterThan(tip, wing - 20, "the end of a full line sits at the right edge")
    }

    /// How many times the revealed text stood still for 0.4 s or longer
    /// while the speaker was talking.
    static func stalls(_ frames: [Frame]) -> Int {
        var still = 0, stalls = 0
        for (before, after) in zip(frames, frames.dropFirst()) {
            if after.at > 1, after.at < 43, after.text == before.text {
                still += 1
            } else {
                if still >= 24 { stalls += 1 }
                still = 0
            }
        }
        return stalls + (still >= 24 ? 1 : 0)
    }

    /// Scribe ends about half of its partials with a provisional "-" or ".".
    /// Once such a mark was revealed, every following partial counted as a
    /// rewrite of visible text and was held: the line stood still.
    @MainActor
    func testHoldingRewritesDoesNotMakeTheRecordedTakeStandStillMoreOften() {
        let held = Self.stalls(Self.replay())
        let unheld = Self.stalls(Self.replay(hold: 0))
        XCTAssertLessThanOrEqual(held, unheld)
    }

    /// The recording must really contain what the tests are about.
    func testTheRecordingContainsShorterPartialsAndRewrittenTails() {
        var shorter = 0, rewritten = 0
        var previous = ""
        for event in ElevenLabsRecordedTake.events {
            guard event.kind == .partial else { previous = ""; continue }
            if event.text.count < previous.count - 4 { shorter += 1 }
            if !event.text.hasPrefix(previous) { rewritten += 1 }
            previous = event.text
        }
        XCTAssertGreaterThanOrEqual(shorter, 5)
        XCTAssertGreaterThanOrEqual(rewritten, 40)
    }
}
