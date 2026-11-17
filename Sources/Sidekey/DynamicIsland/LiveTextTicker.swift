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

    /// The provider rewrote text before the reveal point and its length
    /// changed by `delta`: the reveal point stays on the same character.
    mutating func shiftShown(by delta: Int) {
        guard delta != 0 else { return }
        shown = max(0, shown + Double(delta))
        for index in deadlines.indices { deadlines[index].end = max(0, deadlines[index].end + delta) }
    }

    /// The reveal point moves back to `count` (the text after it was replaced).
    mutating func pullBack(to count: Int) {
        shown = min(shown, Double(max(0, count)))
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
/// A provider also rewrites text it has already sent (a stumble it takes
/// back, a word it hears differently). The old and new text are matched from
/// both ends, so only the part that really changed is touched: everything
/// after it keeps its place in the reveal and does not gather again, and the
/// reveal point stays on the same character even when the length changed.
/// Rewritten characters that are on screen gather in place; a rewrite longer
/// than `maxAnimatedRevisions` is swapped without the effect.
/// WHY: .project-docs/decisions/2026-11-15-live-text-rewrites.md
/// Pure: the caller supplies the clock.
struct LiveTextTicker {
    /// How long one character takes to gather.
    static let gatherSeconds: TimeInterval = 0.35
    /// More rewritten characters than this in one update change at once.
    static let maxAnimatedRevisions = 12

    private(set) var characters: [Character] = []
    /// When each revealed character appeared. `-.infinity` is "long ago".
    private(set) var bornAt: [TimeInterval] = []
    /// When the provider delivered each character.
    private var deliveredAt: [TimeInterval] = []
    private var pacer = LiveTextPacer()

    var revealed: Double { pacer.shown }
    var revealedCount: Int { Int(pacer.shown) }

    /// Text that was already on screen (the face was rebuilt mid-take).
    mutating func prime(_ text: String, now: TimeInterval) {
        characters = Array(text)
        bornAt = Array(repeating: -.infinity, count: characters.count)
        deliveredAt = Array(repeating: now, count: characters.count)
        pacer.delivered(count: characters.count, now: now)
        pacer.revealAll()
    }

    mutating func textArrived(_ text: String, now: TimeInterval) {
        let next = Array(text)
        let shortest = min(characters.count, next.count)
        var prefix = 0
        while prefix < shortest, characters[prefix] == next[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix,
              characters[characters.count - 1 - suffix] == next[next.count - 1 - suffix] { suffix += 1 }
        let oldMiddleEnd = characters.count - suffix
        let newMiddle = next.count - suffix - prefix
        let revealed = revealedCount

        // How much of the replaced part is on screen after the change.
        let visibleMiddle: Int
        if suffix > 0, revealed >= oldMiddleEnd {
            visibleMiddle = newMiddle
            pacer.shiftShown(by: next.count - characters.count)
        } else if revealed > prefix {
            visibleMiddle = min(revealed - prefix, newMiddle)
            pacer.pullBack(to: prefix + visibleMiddle)
        } else {
            visibleMiddle = 0
        }
        let stamp: TimeInterval = visibleMiddle > Self.maxAnimatedRevisions ? -.infinity : now
        var born = Array(bornAt[..<prefix])
        born.append(contentsOf: Array(repeating: stamp, count: visibleMiddle))
        born.append(contentsOf: Array(repeating: .infinity, count: newMiddle - visibleMiddle))
        born.append(contentsOf: bornAt[oldMiddleEnd...])
        var delivered = Array(deliveredAt[..<prefix])
        delivered.append(contentsOf: Array(repeating: now, count: newMiddle))
        delivered.append(contentsOf: deliveredAt[oldMiddleEnd...])
        characters = next
        bornAt = born
        deliveredAt = delivered
        pacer.delivered(count: next.count, now: now)
    }

    /// A character revealed after its deadline (the main thread stalled and
    /// the pacer caught up in one step) is shown solid at once: it is already
    /// late, and gathering would keep it unreadable for longer still.
    mutating func advance(now: TimeInterval) {
        let before = revealedCount
        pacer.advance(now: now)
        let after = min(revealedCount, bornAt.count)
        guard after > before else { return }
        for index in before..<after {
            let overdue = now - deliveredAt[index] >= LiveTextPacer.lagCap
            bornAt[index] = overdue ? -.infinity : now
        }
    }

    /// 0 while a character is still dust, 1 once it has gathered.
    func gatherProgress(at index: Int, now: TimeInterval) -> Double {
        guard index < revealedCount, index < bornAt.count else { return 0 }
        return min(1, max(0, (now - bornAt[index]) / Self.gatherSeconds))
    }

    /// Whether the text can be drawn one character at a time, left to right.
    /// Right-to-left scripts (Arabic, Hebrew and others), explicit direction
    /// controls and scripts whose letters join or reorder across characters
    /// (Indic, Tibetan, Myanmar, Khmer, Mongolian and others) need the whole
    /// line shaped together, so the wing shows them as plain text instead.
    static func canDrawPerCharacter(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            wholeLineScalars.contains { $0.contains(scalar.value) }
        }
    }

    private static let wholeLineScalars: [ClosedRange<UInt32>] = [
        0x0590...0x08FF,    // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic
        0x0900...0x0DFF,    // Devanagari to Sinhala
        0x0F00...0x109F,    // Tibetan, Myanmar
        0x1780...0x18AF,    // Khmer, Mongolian
        0x1A00...0x1AAF,    // Buginese, Tai Tham
        0x1B00...0x1BFF,    // Balinese, Sundanese, Batak
        0x200F...0x200F,    // right-to-left mark
        0x202A...0x202E,    // directional embeddings and overrides
        0x2066...0x2069,    // directional isolates
        0xA800...0xA8FF,    // Syloti Nagri, Phags-pa, Saurashtra, Devanagari Extended
        0xA980...0xAAFF,    // Javanese, Myanmar Extended, Cham, Tai Viet, Meetei Mayek Ext.
        0xABC0...0xABFF,    // Meetei Mayek
        0xFB1D...0xFDFF,    // Hebrew and Arabic presentation forms
        0xFE70...0xFEFC,    // Arabic presentation forms B
        0x10800...0x10FFF,  // historic right-to-left scripts
        0x11000...0x11FFF,  // Brahmi and other historic Indic scripts
        0x1E800...0x1EFFF,  // Mende Kikakui, Adlam, Arabic mathematical symbols
    ]
}
