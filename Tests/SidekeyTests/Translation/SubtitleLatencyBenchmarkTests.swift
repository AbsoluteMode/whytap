import Foundation
import XCTest
@testable import Sidekey

/// The segmenter on origin/main before the phrase pairs (2026-11-21), kept
/// only as the baseline of the latency comparison below.
private struct LegacySubtitleSegmenter {
    private(set) var pending = ""
    private var firstAt: TimeInterval?
    private var lastAt: TimeInterval = 0

    mutating func append(_ text: String, join: BYOKTranscriptJoin, now: TimeInterval) {
        guard !text.isEmpty else { return }
        if pending.isEmpty { firstAt = now }
        if join == .wordBoundary, !pending.isEmpty,
           pending.last?.isWhitespace == false, text.first?.isWhitespace == false {
            pending += " "
        }
        pending += text
        lastAt = now
    }

    mutating func take(now: TimeInterval, force: Bool = false) -> String? {
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sentenceEnd = trimmed.last.map { ".!?。！？".contains($0) } ?? false
        guard force || trimmed.count >= 300 || now - lastAt >= 0.8
                || (sentenceEnd && now - lastAt >= 0.2)
                || (trimmed.count >= 40 && now - (firstAt ?? now) >= 2) else { return nil }
        let end = trimmed.index(trimmed.startIndex, offsetBy: min(600, trimmed.count))
        let split = end == trimmed.endIndex ? end
            : (trimmed[..<end].lastIndex(where: \.isWhitespace) ?? end)
        let result = String(trimmed[..<split])
        pending = String(trimmed[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        firstAt = pending.isEmpty ? nil : now
        return result
    }
}

/// Deterministic latency model of the whole Subtitles path on one scripted
/// lecture: speech timing -> provider finals -> phrase cutting -> translation.
/// Provider and model delays are stated assumptions, not live measurements
/// (tests never make paid requests); both pipelines get exactly the same ones.
// WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
final class SubtitleLatencyBenchmarkTests: XCTestCase {
    struct Word { let text: String; let start: Double; let end: Double }
    struct Delivery { let at: Double; let text: String }
    struct Model { let name: String; let base: Double; let charsPerSecond: Double }
    enum Provider: String { case elevenLabsManual = "ElevenLabs, manual commit (before)",
                                 elevenLabsVAD = "ElevenLabs, VAD commit 0.5 s (after)",
                                 soniox = "Soniox (unchanged provider)" }
    struct Result {
        var median = 0.0, p90 = 0.0, max = 0.0
        var originalMedian: Double?
        var phrases = 0, fragments = 0
        var texts: [String] = []
    }

    static let lecture = """
    Welcome back everyone. Today we have a special guest, who has spent ten years building speech systems. \
    Before we start, let me explain how a neural network is structured. Every layer takes the numbers from the previous one, \
    multiplies them by weights and passes the result forward. The interesting part is how those weights are learned, \
    because nobody writes them by hand. We show the network an example, we measure how wrong the answer is, and we nudge \
    every weight a little bit in the direction that makes the error smaller. Repeat that a few million times and the network \
    starts to recognise patterns that we never described explicitly. That is the whole trick and it is surprisingly simple. \
    Now our guest will show what this looks like when the input is not an image but a sound. So please welcome her.
    """

    /// ~160 words per minute; commas pause 0.25 s, sentence ends alternate
    /// between a clear 0.6 s pause and a run-on 0.3 s.
    static func speak(_ text: String) -> [Word] {
        var time = 0.4, sentence = 0
        return text.split(separator: " ").map { raw in
            let word = String(raw)
            let letters = word.filter(\.isLetter).count
            let start = time
            let end = start + 0.12 + 0.045 * Double(letters)
            time = end + 0.05
            if word.hasSuffix(",") { time += 0.2 }
            if let last = word.last, ".!?".contains(last) { sentence += 1; time += sentence.isMultiple(of: 2) ? 0.25 : 0.55 }
            return Word(text: word, start: start, end: end)
        }
    }

    static var vadSilence: Double {
        if let override = ProcessInfo.processInfo.environment["WHYTAP_SUBTITLE_BENCH_VAD"].flatMap(Double.init) { return override }
        guard case .vad(let seconds) = ElevenLabsCommitStrategy.subtitles else { return .infinity }
        return seconds
    }

    /// ElevenLabs partials: the whole uncommitted segment, ~0.3 s after each word.
    static func segmentPartials(_ words: [Word], provider: Provider) -> [Delivery] {
        guard provider == .elevenLabsVAD else { return [] }
        var partials: [Delivery] = [], segment: [String] = []
        for (index, word) in words.enumerated() {
            segment.append(word.text)
            partials.append(Delivery(at: word.end + 0.3, text: segment.joined(separator: " ")))
            let nextStart = index + 1 < words.count ? words[index + 1].start : .infinity
            if nextStart - word.end >= vadSilence - 1e-9 { segment = [] }
        }
        return partials
    }

    static func finals(_ words: [Word], provider: Provider) -> (join: BYOKTranscriptJoin, finals: [Delivery], partials: [Double]) {
        switch provider {
        case .soniox:
            // Each word's tokens finalize ~0.8–0.95 s after it is spoken, often
            // in two subword pieces; interim tokens show ~0.25 s after.
            var finals: [Delivery] = []
            for word in words {
                let middle = word.text.index(word.text.startIndex, offsetBy: word.text.count / 2)
                finals.append(Delivery(at: word.end + 0.8, text: " " + word.text[..<middle]))
                finals.append(Delivery(at: word.end + 0.95, text: String(word.text[middle...])))
            }
            return (.verbatim, finals, words.map { $0.end + 0.25 })
        case .elevenLabsManual, .elevenLabsVAD:
            // Scribe commits by itself at ~36 s of audio, cutting the word under
            // the cap; VAD also commits at every 0.5 s silence. A commit lands
            // ~0.3 s after its trigger; partials ~0.3 s after each word.
            var finals: [Delivery] = []
            var segment: [String] = []
            var segmentStart = 0.0
            for (index, word) in words.enumerated() {
                let cap = segmentStart + 36
                if word.end > cap {
                    let spoken = max(0, min(1, (cap - word.start) / (word.end - word.start)))
                    let cutAt = word.text.index(word.text.startIndex, offsetBy: Int(Double(word.text.count) * spoken))
                    segment.append(String(word.text[..<cutAt]))
                    finals.append(Delivery(at: cap + 0.3, text: segment.joined(separator: " ")))
                    segment = [String(word.text[cutAt...])]
                    segmentStart = cap
                } else {
                    segment.append(word.text)
                }
                let nextStart = index + 1 < words.count ? words[index + 1].start : .infinity
                if provider == .elevenLabsVAD, nextStart - word.end >= vadSilence - 1e-9 {
                    finals.append(Delivery(at: word.end + vadSilence + 0.3, text: segment.joined(separator: " ")))
                    segment = []
                    segmentStart = word.end + vadSilence
                }
            }
            if !segment.isEmpty, let last = words.last {
                // The take ends: Stop commits the rest.
                finals.append(Delivery(at: last.end + 1.5, text: segment.joined(separator: " ")))
            }
            return (.wordBoundary, finals.filter { !$0.text.isEmpty }, words.map { $0.end + 0.3 })
        }
    }

    /// Runs one pipeline on a 10 ms clock and returns, per phrase, when its
    /// translation is on screen.
    static func run(_ words: [Word], provider: Provider, model: Model, improved: Bool) -> Result {
        let (join, finals, partials) = finals(words, provider: provider)
        let segmentPartials = improved ? segmentPartials(words, provider: provider) : []
        var lock = SubtitlePartialLock()
        var nextPartial = 0
        var legacy = LegacySubtitleSegmenter()
        var current = SubtitleSegmenter()
        var phrases: [(text: String, visible: Double)] = []
        var slots = Array(repeating: 0.0, count: improved ? LiveSubtitleModel.maxConcurrentTranslations : 1)
        func translate(_ text: String, at time: Double) {
            let index = slots.indices.min { slots[$0] < slots[$1] }!
            let start = max(time, slots[index])
            let done = start + model.base + Double(text.count) * 1.15 / model.charsPerSecond
            slots[index] = done
            phrases.append((text, done))
        }
        let tick = improved ? 0.1 : 0.25
        var next = 0
        let end = (finals.last?.at ?? 0) + 2
        var step = 0
        while Double(step) * 0.01 <= end {
            let now = Double(step) * 0.01
            var arrived = false, committed = false
            while next < finals.count, finals[next].at <= now + 1e-9 {
                if improved, !segmentPartials.isEmpty {
                    current.append(lock.commit(finals[next].text), join: join, now: now); committed = true
                } else if improved { current.append(finals[next].text, join: join, now: now) }
                else { legacy.append(finals[next].text, join: join, now: now) }
                next += 1; arrived = true
            }
            while nextPartial < segmentPartials.count, segmentPartials[nextPartial].at <= now + 1e-9 {
                lock.update(partial: segmentPartials[nextPartial].text, now: now)
                nextPartial += 1
            }
            let ticked = step % Int((tick * 100).rounded()) == 0
            if improved, arrived || ticked {
                // Mirrors LiveSubtitleModel.flush: committed text first (forced at
                // a commit), then the stable start of the partial.
                while let phrase = current.take(now: now, force: committed) { translate(phrase, at: now) }
                if !segmentPartials.isEmpty, current.pending.isEmpty {
                    while let phrase = lock.take(now: now) { translate(phrase, at: now) }
                }
            } else if !improved, ticked, let phrase = legacy.take(now: now) {
                translate(phrase, at: now)   // one phrase per tick, one request at a time
            }
            step += 1
        }
        if improved { while let phrase = current.take(now: end, force: true) { translate(phrase, at: end) } }
        else { while let phrase = legacy.take(now: end, force: true) { translate(phrase, at: end) } }

        // Map every spoken word to the phrase holding its last letter.
        let letters = { (text: String) in text.filter { $0.isLetter || $0.isNumber } }
        var owner: [Double] = []
        var boundaries = Set<Int>()
        for phrase in phrases {
            owner += Array(repeating: phrase.visible, count: letters(phrase.text).count)
            boundaries.insert(owner.count)
        }
        var position = 0, latencies: [Double] = [], wordEnds = Set<Int>()
        for word in words {
            position += letters(word.text).count
            wordEnds.insert(position)
            guard position - 1 < owner.count else { continue }
            latencies.append(owner[position - 1] - word.end)
        }
        latencies.sort()
        var result = Result()
        result.median = latencies[latencies.count / 2]
        result.p90 = latencies[Int(Double(latencies.count) * 0.9)]
        result.max = latencies.last ?? 0
        result.phrases = phrases.count
        result.texts = phrases.map(\.text)
        result.fragments = boundaries.subtracting(wordEnds).count
        if improved {
            let shown = zip(words, partials).map { $1 - $0.end }.sorted()
            result.originalMedian = shown[shown.count / 2]
        }
        return result
    }

    func testPhrasePairsReachTheScreenSoonerAndWhole() throws {
        let words = Self.speak(Self.lecture)
        let models = [
            Model(name: "assumed Claude Sonnet 5.5 via OpenRouter (1.1 s + 250 chars/s)", base: 1.1, charsPerSecond: 250),
            Model(name: "assumed fast model (0.45 s + 600 chars/s)", base: 0.45, charsPerSecond: 600),
        ]
        var report = "Speech: \(words.count) words, \(String(format: "%.1f", words.last!.end)) s.\n"
        report += "Latency = word spoken -> its translation on screen (s): median / p90 / max; phrases; mid-word cuts.\n"
        func row(_ label: String, _ r: Result) -> String {
            var text = String(format: "  %@: %.2f / %.2f / %.2f; %d phrases; %d mid-word cuts",
                              label, r.median, r.p90, r.max, r.phrases, r.fragments)
            if let original = r.originalMedian { text += String(format: "; original shown after %.2f s", original) }
            return text + "\n"
        }
        for model in models {
            report += "\n\(model.name)\n"
            let elBefore = Self.run(words, provider: .elevenLabsManual, model: model, improved: false)
            let elAfter = Self.run(words, provider: .elevenLabsVAD, model: model, improved: true)
            let soBefore = Self.run(words, provider: .soniox, model: model, improved: false)
            let soAfter = Self.run(words, provider: .soniox, model: model, improved: true)
            report += row("ElevenLabs before (manual commit, old pipeline)", elBefore)
            report += row("ElevenLabs after  (VAD commit, phrase pairs)  ", elAfter)
            report += row("Soniox before (old pipeline)                  ", soBefore)
            report += row("Soniox after  (phrase pairs)                  ", soAfter)
            if model.base > 1 {
                report += "    ElevenLabs before, phrases: " + elBefore.texts.map { "«\($0.prefix(60))…»" }.joined(separator: " | ") + "\n"
                report += "    ElevenLabs after, phrases: " + elAfter.texts.map { "«\($0)»" }.joined(separator: " | ") + "\n"
                report += "    Soniox before, phrases: " + soBefore.texts.prefix(10).map { "«\($0)»" }.joined(separator: " | ") + " …\n"
            }
            XCTAssertLessThan(elAfter.p90, elBefore.p90 / 4, model.name)
            XCTAssertLessThan(elAfter.median, 4, model.name)
            // Soniox finals were already continuous: whole phrases cost at most
            // a few tenths in the median and must not lose in the tail.
            XCTAssertLessThanOrEqual(soAfter.median, soBefore.median + 0.3, model.name)
            XCTAssertLessThanOrEqual(soAfter.p90, soBefore.p90, model.name)
            XCTAssertEqual(elAfter.fragments, 0, "No phrase may end inside a word")
            XCTAssertEqual(soAfter.fragments, 0, "No phrase may end inside a word")
        }
        print(report)
        if let path = ProcessInfo.processInfo.environment["WHYTAP_SUBTITLE_BENCH_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
