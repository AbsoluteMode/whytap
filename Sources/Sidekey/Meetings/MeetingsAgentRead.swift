import Foundation

// Read access to meetings for a coding harness the user allowed.
// WHY: .project-docs/decisions/2026-11-20-harness-access.md

struct MeetingSearchRequest: Sendable, Equatable {
    var query = ""
    /// Meetings that started at or after this moment.
    var from: Date?
    /// Meetings that started before this moment.
    var to: Date?
    var limit = 10
}

struct MeetingSegmentHit: Sendable, Equatable {
    let index: Int
    let segment: TranscriptSegment
}

struct MeetingSearchHit: Sendable, Equatable {
    let meta: MeetingMetaWithLocalState
    let title: String?
    let hasNote: Bool
    let segmentCount: Int
    /// The note around the first match; nil when the note does not match.
    let noteSnippet: String?
    /// The best matching replies, at most `MeetingTextSearch.segmentsPerMeeting`.
    let segments: [MeetingSegmentHit]
}

struct MeetingSearchResult: Sendable, Equatable {
    let hits: [MeetingSearchHit]
    /// Meetings that matched, before `limit`.
    let total: Int
    /// True when more meetings were in range than one search reads.
    let truncated: Bool
}

struct MeetingDocument: Sendable, Equatable {
    let meta: MeetingMetaWithLocalState
    let title: String?
    /// The note without a transcript section embedded by older builds.
    let note: String?
    let transcript: [TranscriptSegment]?
}

/// The matching rules, apart from the store so they are tested on plain text.
enum MeetingTextSearch {
    static let maxTerms = 8
    static let segmentsPerMeeting = 3
    static let snippetRadius = 140
    static let segmentTextLimit = 500
    /// One search reads at most this many of the newest meetings in range.
    static let scanLimit = 400

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Words of the query, each cut to a stem so an inflected form still
    /// matches. A Cyrillic word of five or more letters loses its last two
    /// ("ценах" finds "цены"); one of four letters loses a final vowel
    /// ("цены" finds "ценах", "Егор" stays whole). Any other word of five or
    /// more letters loses its last one ("prices" finds "price"). Words with
    /// digits stay whole.
    static func needles(_ query: String) -> [String] {
        var seen: Set<String> = []
        return query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
            .map { word -> String in
                guard word.count >= 4, word.allSatisfy(\.isLetter) else { return word }
                let cyrillic = word.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
                if word.count >= 5 { return String(word.dropLast(cyrillic ? 2 : 1)) }
                guard cyrillic, let last = word.lowercased().last, "аеёиоуыэюяьй".contains(last) else { return word }
                return String(word.dropLast())
            }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(maxTerms)
            .map { $0 }
    }

    static func contains(_ needle: String, in text: String) -> Bool {
        text.range(of: needle, options: options) != nil
    }

    /// How many of the needles the text has.
    static func score(_ needles: [String], in text: String) -> Int {
        needles.reduce(0) { $0 + (contains($1, in: text) ? 1 : 0) }
    }

    /// The text around the earliest needle, on one line, or nil without a match.
    static func snippet(_ needles: [String], in text: String) -> String? {
        let first = needles.compactMap { text.range(of: $0, options: options) }.min { $0.lowerBound < $1.lowerBound }
        guard let first else { return nil }
        let start = text.index(first.lowerBound, offsetBy: -snippetRadius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first.upperBound, offsetBy: snippetRadius, limitedBy: text.endIndex) ?? text.endIndex
        let line = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + line + (end < text.endIndex ? "…" : "")
    }

    static func clipped(_ text: String, to limit: Int = segmentTextLimit) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// The note's first level-one heading, skipping the protocol marker line.
    static func heading(of markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true).prefix(8) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }
}

extension MeetingsStore {
    /// Newest first without a query; best match first with one. A meeting
    /// matches when every word of the query is in its title, note or
    /// transcript. Runs inside the store, never on the main thread.
    func search(_ request: MeetingSearchRequest) throws -> MeetingSearchResult {
        let inRange = try list().filter { row in
            (request.from.map { row.startedAt >= $0 } ?? true) && (request.to.map { row.startedAt < $0 } ?? true)
        }
        let rows = Array(inRange.prefix(MeetingTextSearch.scanLimit))
        let needles = MeetingTextSearch.needles(request.query)
        let limit = max(1, request.limit)

        var scored: [(hit: MeetingSearchHit, score: Int)] = []
        for row in rows {
            // Without a query only the listed page is read from disk.
            if needles.isEmpty, scored.count >= limit { break }
            let document = document(row)
            let title = document.title ?? ""
            let note = document.note ?? ""
            let segments = document.transcript ?? []
            var score = 0
            var noteSnippet: String?
            var segmentHits: [MeetingSegmentHit] = []
            if !needles.isEmpty {
                let ranked = segments.enumerated()
                    .map { (index: $0.offset, segment: $0.element, score: MeetingTextSearch.score(needles, in: $0.element.text)) }
                    .filter { $0.score > 0 }
                let everywhere = title + "\n" + note + "\n" + ranked.map(\.segment.text).joined(separator: "\n")
                guard MeetingTextSearch.score(needles, in: everywhere) == needles.count else { continue }
                noteSnippet = MeetingTextSearch.snippet(needles, in: note)
                segmentHits = ranked
                    .sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }
                    .prefix(MeetingTextSearch.segmentsPerMeeting)
                    .sorted { $0.index < $1.index }
                    .map { MeetingSegmentHit(index: $0.index, segment: $0.segment) }
                score = MeetingTextSearch.score(needles, in: title) * 8
                    + MeetingTextSearch.score(needles, in: note) * 3
                    + min(ranked.count, 20)
            }
            scored.append((MeetingSearchHit(
                meta: row, title: document.title, hasNote: document.note != nil, segmentCount: segments.count,
                noteSnippet: noteSnippet, segments: segmentHits), score))
        }
        // The sort is stable over rows that are already newest first.
        let ordered = needles.isEmpty ? scored : scored.enumerated()
            .sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }
            .map(\.element)
        return MeetingSearchResult(
            hits: ordered.prefix(limit).map(\.hit),
            total: needles.isEmpty ? inRange.count : ordered.count,
            truncated: inRange.count > rows.count)
    }

    /// One meeting's note and transcript in one actor turn.
    func document(id: UUID) throws -> MeetingDocument? {
        guard let row = try list().first(where: { $0.id == id }) else { return nil }
        return document(row)
    }

    /// An unreadable note or transcript reads as missing, so one damaged
    /// meeting does not fail a search over all of them.
    private func document(_ row: MeetingMetaWithLocalState) -> MeetingDocument {
        let note = (try? markdown(id: row.id)).map(NoteMarkdownStripper.stripTranscript)
        // A meeting whose note failed still has its kept transcript.
        let transcript = (try? transcript(id: row.id)) ?? (try? transcriptAwaitingNote(meetingId: row.id))
        let stored = row.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (stored?.isEmpty == false ? stored : nil) ?? note.flatMap(MeetingTextSearch.heading)
        return MeetingDocument(meta: row, title: title, note: note, transcript: transcript)
    }
}
