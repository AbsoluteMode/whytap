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
/// Particles mark the first reveal at the live edge. Corrections behind that
/// edge are already readable, even when one update also appends new speech.
/// WHY: .project-docs/decisions/2026-11-15-live-text-rewrites.md
struct LiveTextTicker {
    static let gatherSeconds: TimeInterval = 0.35

    /// A strict truncation can be a transient partial. Retain only one visible
    /// prefix for this take so its return can restore already displayed text.
    private var withdrawn: ArraySlice<Character> = []

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
        withdrawn = []
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
        // A new word may end like the previous one ("что" -> "что это").
        // Prefer the earlier, equally good or stronger match: words after it
        // are new speech and must still pass through the reveal point.
        var revisionEnd = next.count
        if suffix > 0, next.count > characters.count {
            let shortestAnchor = max(3, suffix)
            let longestAnchor = max(suffix, min(24, characters.count - prefix))
            for length in stride(from: longestAnchor, through: shortestAnchor, by: -1) {
                if let match = next[prefix...].firstRange(of: characters.suffix(length)) {
                    revisionEnd = match.upperBound
                    suffix = length
                    break
                }
            }
        }
        let shown = revealedCount
        let oldEnd = characters.count - suffix
        let newEnd = revisionEnd - suffix
        var born = Array(bornAt[..<prefix])
        var delivered = Array(deliveredAt[..<prefix])

        // The common ends handle ordinary appends and single corrections.
        // In a mixed revision (e.g. punctuation plus new speech), also match
        // the unchanged runs inside the edit so the reveal stays on its word.
        let oldMiddle = characters[prefix..<oldEnd]
        let newMiddle = next[prefix..<newEnd]
        var old = prefix
        var new = prefix
        func replace(upTo oldLimit: Int, withNewUpTo newLimit: Int) {
            let count = newLimit - new
            let onScreen: Int
            if old < shown, oldLimit <= shown, oldLimit < characters.count {
                onScreen = count
            } else {
                onScreen = min(count, max(0, shown - old))
            }
            born.append(contentsOf: repeatElement(-.infinity, count: onScreen))
            born.append(contentsOf: repeatElement(.infinity, count: count - onScreen))
            delivered.append(contentsOf: repeatElement(now, count: count))
            old = oldLimit
            new = newLimit
        }
        func keep(_ oldRun: Range<Int>, at newStart: Int) {
            replace(upTo: oldRun.lowerBound, withNewUpTo: newStart)
            born.append(contentsOf: bornAt[oldRun])
            delivered.append(contentsOf: deliveredAt[oldRun])
            old = oldRun.upperBound
            new = newStart + oldRun.count
        }
        // Never run an unbounded edit search on the animation thread. For a
        // wholesale replacement, settle the visible span and pace the tail.
        if !oldMiddle.isEmpty, !newMiddle.isEmpty,
           max(oldMiddle.count, newMiddle.count) <= 512, old < shown {
            let edits = newMiddle.difference(from: oldMiddle)
            var removed = Set<Int>(), inserted = Set<Int>()
            for change in edits {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            var oldMatch = old, newMatch = new
            while oldMatch < oldEnd, newMatch < newEnd {
                while oldMatch < oldEnd, removed.contains(oldMatch - prefix) { oldMatch += 1 }
                while newMatch < newEnd, inserted.contains(newMatch - prefix) { newMatch += 1 }
                let oldStart = oldMatch, newStart = newMatch
                while oldMatch < oldEnd, newMatch < newEnd,
                      !removed.contains(oldMatch - prefix), !inserted.contains(newMatch - prefix) {
                    oldMatch += 1
                    newMatch += 1
                }
                // A stray matching letter in a different word is a poor
                // anchor for where the speaker is now.
                guard oldMatch - oldStart >= 3 else { continue }
                keep(oldStart..<oldMatch, at: newStart)
            }
        } else if max(oldMiddle.count, newMiddle.count) > 512, shown > prefix {
            // A correction near the beginning and an append far past it may
            // enclose a long unchanged passage. Locate the live edge by a
            // short unique run without diffing the entire passage.
            let end = min(shown, oldEnd)
            let anchor = max(prefix, end - 24)..<end
            if anchor.count >= 3, let match = newMiddle.firstRange(of: characters[anchor]),
               newMiddle[match.upperBound...].firstRange(of: characters[anchor]) == nil {
                keep(anchor, at: match.lowerBound)
            }
        }
        replace(upTo: oldEnd, withNewUpTo: newEnd)
        born.append(contentsOf: bornAt[oldEnd...])
        delivered.append(contentsOf: deliveredAt[oldEnd...])
        born.append(contentsOf: repeatElement(.infinity, count: next.count - revisionEnd))
        delivered.append(contentsOf: repeatElement(now, count: next.count - revisionEnd))

        if prefix == next.count, next.count < shown {
            let visible = characters.prefix(shown)
            if !withdrawn.starts(with: visible) { withdrawn = visible }
        } else if !withdrawn.isEmpty {
            let restored = zip(next, withdrawn).prefix { $0 == $1 }.count
            for index in prefix..<max(prefix, restored) where born[index] == .infinity {
                born[index] = -.infinity
            }
            if restored < next.count || restored == withdrawn.count { withdrawn = [] }
        }
        let nextShown = born.firstIndex(of: .infinity) ?? born.count
        pacer.shiftShown(by: nextShown - shown)
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
