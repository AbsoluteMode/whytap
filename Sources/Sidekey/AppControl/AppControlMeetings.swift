import Foundation
import WhytapCaseKit

/// What the meeting tools read. `MeetingsStore` answers inside its own actor.
protocol AppControlMeetingsReading: Sendable {
    func search(_ request: MeetingSearchRequest) async throws -> MeetingSearchResult
    func document(id: UUID) async throws -> MeetingDocument?
}

extension MeetingsStore: AppControlMeetingsReading {}

/// The meeting tools of the application controls. They return the user's
/// notes and transcripts, so the broker lets them through only for a harness
/// the user allowed (`HarnessAccessGate.gatedOperations`).
// WHY: .project-docs/decisions/2026-11-20-harness-access.md
@MainActor
struct AppControlMeetings {
    static let operations: Set<String> = ["meetings_search", "meeting_get", "meeting_transcript", "meeting_open"]
    static let searchLimit = 1...25
    static let noteBytes = 1_000...200_000
    static let transcriptBytes = 1_000...200_000
    static let transcriptSegments = 1...500
    /// Replies shown before the moment `aroundMs` asks for.
    static let leadSegments = 3

    /// `nil` while the meetings store could not be opened.
    let source: () -> AppControlMeetingsReading?
    enum OpenResult: Equatable { case shown, editing, unavailable }
    /// Shows one note in Whytap.
    let open: @MainActor (UUID) -> OpenResult
    var calendar = Calendar.current

    func handle(_ operation: String, _ args: [String: AppControlValue]) async -> AppControlResponse {
        guard let source = source() else {
            return .failure("unavailable", "Whytap could not open its meetings. Check the Meetings window, then retry.")
        }
        do {
            switch operation {
            case "meetings_search": return try await search(args, source)
            case "meeting_get": return try await note(args, source)
            case "meeting_transcript": return try await transcript(args, source)
            case "meeting_open": return try await show(args, source)
            default: return .failure("unknown_operation", "Unknown application-control operation.")
            }
        } catch {
            return .failure("read_failed", "Whytap could not read its meetings.")
        }
    }

    // MARK: Operations

    private func search(_ args: [String: AppControlValue], _ source: AppControlMeetingsReading) async throws -> AppControlResponse {
        guard only(args, ["query", "from", "to", "limit"]),
              args["query"] == nil || args["query"]?.string != nil,
              args["limit"] == nil || args["limit"]?.int != nil else { return Self.invalid }
        let query = args["query"]?.string ?? ""
        let limit = args["limit"]?.int ?? 10
        guard query.count <= 256, Self.searchLimit.contains(limit) else { return Self.invalid }
        var request = MeetingSearchRequest(query: query, limit: limit)
        if let from = args["from"] {
            guard let date = from.string.flatMap({ moment($0, endOfDay: false) }) else { return Self.invalid }
            request.from = date
        }
        if let to = args["to"] {
            guard let date = to.string.flatMap({ moment($0, endOfDay: true) }) else { return Self.invalid }
            request.to = date
        }
        let result = try await source.search(request)
        let meetings = result.hits.map { hit -> AppControlValue in
            var entry = Self.summary(hit.meta, title: hit.title)
            entry["hasNote"] = .bool(hit.hasNote)
            entry["transcriptSegments"] = .int(hit.segmentCount)
            entry["noteSnippet"] = hit.noteSnippet.map(AppControlValue.string) ?? .null
            entry["matches"] = .array(hit.segments.map {
                Self.segment($0.index, $0.segment, text: MeetingTextSearch.clipped($0.segment.text), offset: 0)
            })
            return .object(entry)
        }
        return .success(.object(["meetings": .array(meetings), "total": .int(result.total),
                                 "truncated": .bool(result.truncated)]))
    }

    private func note(_ args: [String: AppControlValue], _ source: AppControlMeetingsReading) async throws -> AppControlResponse {
        guard only(args, ["id", "maxBytes"]), let id = args["id"]?.string.flatMap(Self.meetingID),
              args["maxBytes"] == nil || args["maxBytes"]?.int != nil else { return Self.invalid }
        let maxBytes = args["maxBytes"]?.int ?? 60_000
        guard Self.noteBytes.contains(maxBytes) else { return Self.invalid }
        guard let document = try await source.document(id: id) else { return Self.unknownMeeting }
        var entry = Self.summary(document.meta, title: document.title)
        let note = document.note.map { Self.prefix($0, bytes: maxBytes) }
        entry["note"] = note.map { AppControlValue.string($0.text) } ?? .null
        entry["noteTruncated"] = .bool(note?.truncated ?? false)
        entry["transcriptSegments"] = .int(document.transcript?.count ?? 0)
        return .success(.object(entry))
    }

    private func transcript(_ args: [String: AppControlValue], _ source: AppControlMeetingsReading) async throws -> AppControlResponse {
        guard only(args, ["id", "fromIndex", "fromOffset", "aroundMs", "limit", "maxBytes"]),
              let id = args["id"]?.string.flatMap(Self.meetingID),
              ["fromIndex", "fromOffset", "aroundMs", "limit", "maxBytes"].allSatisfy({ args[$0] == nil || args[$0]?.int != nil }),
              args["aroundMs"] == nil || (args["fromIndex"] == nil && args["fromOffset"] == nil),
              args["fromOffset"] == nil || args["fromIndex"] != nil else { return Self.invalid }
        let limit = args["limit"]?.int ?? 200
        let maxBytes = args["maxBytes"]?.int ?? 40_000
        guard Self.transcriptSegments.contains(limit), Self.transcriptBytes.contains(maxBytes),
              (args["fromIndex"]?.int ?? 0) >= 0, (args["fromOffset"]?.int ?? 0) >= 0,
              (args["aroundMs"]?.int ?? 0) >= 0 else { return Self.invalid }
        guard let document = try await source.document(id: id) else { return Self.unknownMeeting }
        let segments = document.transcript ?? []
        var start = min(args["fromIndex"]?.int ?? 0, segments.count)
        if let around = args["aroundMs"]?.int {
            let hit = segments.firstIndex { Self.milliseconds($0.end) >= around } ?? segments.count
            start = max(0, hit - Self.leadSegments)
        }
        var page: [AppControlValue] = []
        var bytes = 0
        var index = start
        // Characters already read of the reply at `index`: some providers
        // return a whole meeting as one reply, far larger than a page.
        var offset = args["fromOffset"]?.int ?? 0
        while index < segments.count, page.count < limit {
            let segment = segments[index]
            let rest = String(segment.text.dropFirst(offset))
            let cost = rest.utf8.count + Self.segmentOverhead
            if bytes + cost <= maxBytes {
                page.append(Self.segment(index, segment, text: rest, offset: offset))
                bytes += cost
                index += 1
                offset = 0
                continue
            }
            // Only a reply that would not fit an empty page is split.
            guard page.isEmpty else { break }
            let part = Self.prefix(rest, bytes: max(maxBytes - Self.segmentOverhead, 1)).text
            guard !part.isEmpty else { break }
            page.append(Self.segment(index, segment, text: part, offset: offset))
            offset += part.count
            break
        }
        var entry = Self.summary(document.meta, title: document.title)
        entry["segments"] = .array(page)
        entry["total"] = .int(segments.count)
        entry["nextIndex"] = index < segments.count ? .int(index) : .null
        entry["nextOffset"] = index < segments.count && offset > 0 ? .int(offset) : .null
        return .success(.object(entry))
    }

    private func show(_ args: [String: AppControlValue], _ source: AppControlMeetingsReading) async throws -> AppControlResponse {
        guard only(args, ["id"]), let id = args["id"]?.string.flatMap(Self.meetingID) else { return Self.invalid }
        guard let document = try await source.document(id: id) else { return Self.unknownMeeting }
        // A client that left must not move the user's window.
        guard !Task.isCancelled else { return .failure("cancelled", "Request cancelled.") }
        // Access may have been turned off while the meeting was looked up.
        // Nothing suspends between this check and the window.
        if let stillAllowed = HarnessConsent.stillAllowed, !stillAllowed() {
            return .failure("access_denied", "The user has turned this tool's access to Whytap off. Do not retry.")
        }
        switch open(id) {
        case .shown: return .success(.object(Self.summary(document.meta, title: document.title)))
        case .editing:
            return .failure("busy", "The user is editing a note in Whytap. Give them the meeting's link instead of opening it now.")
        case .unavailable: return .failure("unavailable", "Whytap could not show this meeting.")
        }
    }

    // MARK: Values

    /// `2026-11-20` is that local day (through its end for `to`); a full
    /// ISO 8601 timestamp is that moment.
    private func moment(_ text: String, endOfDay: Bool) -> Date? {
        let parts = text.split(separator: "-").map { Int($0) }
        if text.count == 10, parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2],
           let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
           calendar.dateComponents([.year, .month, .day], from: start) == DateComponents(year: year, month: month, day: day) {
            return endOfDay ? calendar.date(byAdding: .day, value: 1, to: start) : start
        }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    nonisolated static func meetingID(_ text: String) -> UUID? {
        if let id = UUID(uuidString: text) { return id }
        guard text.count == 32, text.allSatisfy(\.isHexDigit) else { return nil }
        var dashed = ""
        for (offset, character) in text.enumerated() {
            if [8, 12, 16, 20].contains(offset) { dashed.append("-") }
            dashed.append(character)
        }
        return UUID(uuidString: dashed)
    }

    /// `whytap://meeting/<id>` shows the note; the id has no dashes there.
    nonisolated static func link(_ id: UUID) -> String {
        "whytap://meeting/" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func summary(_ meta: MeetingMetaWithLocalState, title: String?) -> [String: AppControlValue] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return ["id": .string(meta.id.uuidString), "title": title.map(AppControlValue.string) ?? .null,
                "startedAt": .string(formatter.string(from: meta.startedAt)),
                "durationSeconds": .int(meta.durationSeconds), "status": .string(meta.progressStatus.rawValue),
                "link": .string(link(meta.id))]
    }

    /// Times are whole milliseconds: the protocol has no fractional numbers.
    private static func segment(_ index: Int, _ segment: TranscriptSegment, text: String, offset: Int) -> AppControlValue {
        var entry: [String: AppControlValue] = [
            "index": .int(index), "startMs": .int(milliseconds(segment.start)),
            "endMs": .int(milliseconds(segment.end)),
            "speaker": segment.speaker.map(AppControlValue.string) ?? .null, "text": .string(text)]
        // Present only on a part of a reply that continues from `offset`.
        if offset > 0 { entry["offset"] = .int(offset) }
        return .object(entry)
    }

    /// Budgeted per reply for its fields besides the text.
    static let segmentOverhead = 80

    private static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds * 1000, Double(Int32.max)).rounded())
    }

    private static func prefix(_ text: String, bytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var end = text.startIndex
        var used = 0
        for index in text.indices {
            let size = text[index].utf8.count
            if used + size > bytes { break }
            used += size
            end = text.index(after: index)
        }
        return (String(text[..<end]), true)
    }

    private func only(_ args: [String: AppControlValue], _ keys: Set<String>) -> Bool { Set(args.keys).isSubset(of: keys) }

    private static let invalid = AppControlResponse.failure(
        "invalid_arguments", "Use the documented argument names and types; unknown fields are rejected.")
    private static let unknownMeeting = AppControlResponse.failure(
        "unknown_meeting", "No meeting has this id. Find ids with whytap_meetings_search.")
}
