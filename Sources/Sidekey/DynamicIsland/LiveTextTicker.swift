import Foundation

/// Decides how much of the live transcript the recording wing shows.
///
/// A provider delivers live text in batches, up to a second apart. Shown as it
/// arrives, the line jumps and stops. The pacer reveals it at the speaker's
/// own rate instead: it keeps a small reserve of delivered text to spend
/// between batches, and corrects its speed gently when the reserve grows or
/// shrinks. No character waits longer than `lagCap` after it was delivered:
/// every batch has that deadline, and the pacer goes as fast as the nearest
/// one needs.
/// WHY: .project-docs/decisions/2026-11-13-live-text-sand.md
/// Pure: the caller supplies the clock.
struct LiveTextPacer {
    /// Longest the shown text may trail the delivered text.
    static let lagCap: TimeInterval = 1.4
    /// The speaker's rate is the text delivered over this long.
    static let rateWindow: TimeInterval = 4
    /// How long a reserve that is off its target takes to come back.
    static let correctionSeconds: TimeInterval = 1.5
    /// Speed changes are eased over this long, so the line never jerks.
    static let rateSmoothingSeconds: TimeInterval = 0.25
    /// Slowest reveal of text that is waiting (characters per second), so the
    /// last words of an utterance do not crawl in.
    static let minimumRate: Double = 6
    /// A frame gap longer than this is not made up in one step.
    static let longestStep: TimeInterval = 0.1

    /// Characters revealed so far; the fraction is the next one arriving.
    private(set) var shown: Double = 0

    private var delivered = 0
    private var rate: Double = 0
    private var arrivedTotal = 0
    private var arrivals: [Arrival] = []
    private var gapEstimate: TimeInterval = 0.8
    private var lastArrivalAt: TimeInterval?
    private var lastAdvanceAt: TimeInterval?
    private var deadlines: [Deadline] = []

    private struct Arrival {
        let at: TimeInterval
        let total: Int
    }

    /// The text up to `end` must be shown by `at`.
    private struct Deadline {
        var end: Int
        let at: TimeInterval
    }

    /// The provider's text is now `count` characters long.
    mutating func delivered(count: Int, now: TimeInterval) {
        let growth = count - delivered
        if growth > 0 {
            arrivedTotal += growth
            if let lastArrivalAt {
                gapEstimate = 0.7 * gapEstimate + 0.3 * min(2, max(0, now - lastArrivalAt))
            }
            lastArrivalAt = now
            arrivals.append(Arrival(at: now, total: arrivedTotal))
            deadlines.append(Deadline(end: count, at: now + Self.lagCap))
        }
        delivered = max(0, count)
        shown = min(shown, Double(delivered))
        for index in deadlines.indices { deadlines[index].end = min(deadlines[index].end, delivered) }
    }

    /// Everything delivered is shown at once (text that was already on screen).
    mutating func revealAll() {
        shown = Double(delivered)
        rate = 0
        deadlines.removeAll()
    }

    @discardableResult
    mutating func advance(now: TimeInterval) -> Double {
        let step = min(Self.longestStep, max(0, now - (lastAdvanceAt ?? now)))
        lastAdvanceAt = now
        while arrivals.count > 2, let first = arrivals.first, first.at < now - Self.rateWindow {
            arrivals.removeFirst()
        }
        let backlog = Double(delivered) - shown
        guard backlog > 0 else {
            rate = 0
            return shown
        }
        let speakingRate = self.speakingRate(now: now)
        let reserve = speakingRate * min(gapEstimate * 0.75, Self.lagCap * 0.6)
        let target = max(
            speakingRate + (backlog - reserve) / Self.correctionSeconds,
            backlog / Self.lagCap,
            Self.minimumRate
        )
        rate += (target - rate) * min(1, step / Self.rateSmoothingSeconds)
        deadlines.removeAll { Double($0.end) <= shown }
        let needed = deadlines.map { (Double($0.end) - shown) / max(Self.longestStep, $0.at - now) }.max() ?? 0
        rate = max(rate, needed)
        shown = min(Double(delivered), shown + rate * step)
        return shown
    }

    /// Characters per second the provider has been delivering; zero once it
    /// has gone quiet, so the reserve is spent instead of held.
    private func speakingRate(now: TimeInterval) -> Double {
        guard let lastArrivalAt, let first = arrivals.first,
              now - lastArrivalAt <= max(1.5, gapEstimate * 2)
        else { return 0 }
        return Double(arrivedTotal - first.total) / max(0.5, now - first.at)
    }
}

/// The live transcript as the recording wing shows it: which characters are
/// visible and when each one appeared, so the view can draw it gathering.
///
/// A provider also rewrites text it has already sent. A rewritten character
/// that is on screen gathers again in place; a rewrite that touches many of
/// them at once (a word inserted earlier shifts everything after it) is
/// swapped without the effect.
/// Pure: the caller supplies the clock.
struct LiveTextTicker {
    /// How long one character takes to gather.
    static let gatherSeconds: TimeInterval = 0.35
    /// More rewritten characters than this in one update change at once.
    static let maxAnimatedRevisions = 12

    private(set) var characters: [Character] = []
    /// When each revealed character appeared. `-.infinity` is "long ago".
    private(set) var bornAt: [TimeInterval] = []
    private var pacer = LiveTextPacer()

    var revealed: Double { pacer.shown }
    var revealedCount: Int { Int(pacer.shown) }

    /// Text that was already on screen (the face was rebuilt mid-take).
    mutating func prime(_ text: String, now: TimeInterval) {
        characters = Array(text)
        bornAt = Array(repeating: -.infinity, count: characters.count)
        pacer.delivered(count: characters.count, now: now)
        pacer.revealAll()
    }

    mutating func textArrived(_ text: String, now: TimeInterval) {
        let next = Array(text)
        let visible = min(revealedCount, next.count, characters.count)
        let rewritten = (0..<visible).filter { characters[$0] != next[$0] }
        let stamp: TimeInterval = rewritten.count > Self.maxAnimatedRevisions ? -.infinity : now
        for index in rewritten { bornAt[index] = stamp }
        characters = next
        if bornAt.count > next.count {
            bornAt.removeLast(bornAt.count - next.count)
        } else {
            bornAt.append(contentsOf: Array(repeating: .infinity, count: next.count - bornAt.count))
        }
        pacer.delivered(count: next.count, now: now)
    }

    mutating func advance(now: TimeInterval) {
        let before = revealedCount
        pacer.advance(now: now)
        let after = min(revealedCount, bornAt.count)
        guard after > before else { return }
        for index in before..<after { bornAt[index] = now }
    }

    /// 0 while a character is still dust, 1 once it has gathered.
    func gatherProgress(at index: Int, now: TimeInterval) -> Double {
        guard index < revealedCount, index < bornAt.count else { return 0 }
        return min(1, max(0, (now - bornAt[index]) / Self.gatherSeconds))
    }
}
