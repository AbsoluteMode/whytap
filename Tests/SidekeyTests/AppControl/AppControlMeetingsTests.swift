import WhytapCaseKit
import XCTest
@testable import Sidekey

/// "Find the meeting where we discussed prices": what an allowed harness
/// reads through the meeting tools, over a real store in a temporary folder.
@MainActor
final class AppControlMeetingsTests: XCTestCase {
    private var root: URL!
    private var store: MeetingsStore!
    private var opened: [UUID] = []
    private var openResult = AppControlMeetings.OpenResult.shown
    private var tools: AppControlMeetings!

    private let pricing = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let hiring = UUID()
    private let deleted = UUID()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-meetings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try MeetingsStore(rootDirectory: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        tools = AppControlMeetings(
            source: { [store] in store },
            open: { [weak self] id in
                guard let self else { return .unavailable }
                if self.openResult == .shown { self.opened.append(id) }
                return self.openResult
            },
            calendar: calendar)

        try await store.insert(
            meta: meta(pricing, day: 10),
            markdown: "<!-- protocol:v1 -->\n# Тарифы на 2027\n\nРешили поднять цены на 15% с января.\n\n## Transcript\n\nстарая копия",
            transcript: [
                TranscriptSegment(speaker: "Speaker 1", start: 0, end: 4.25, text: "Привет, начнём."),
                TranscriptSegment(speaker: "Speaker 2", start: 4.25, end: 9.5, text: "По ценам: Егор предлагает плюс пятнадцать процентов."),
                TranscriptSegment(speaker: "Speaker 1", start: 9.5, end: 15, text: "Согласен, с января."),
                TranscriptSegment(speaker: nil, start: 15, end: 20, text: "Тогда фиксируем цену в договоре."),
            ])
        try await store.insert(
            meta: meta(hiring, day: 12, title: "Hiring sync"),
            markdown: "# Weekly\n\nWe need two iOS engineers.",
            transcript: [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 3, text: "Two iOS engineers by March.")])
        // A meeting the user deleted.
        try await store.insert(meta: meta(deleted, day: 14), markdown: "# Gone")
        try await store.delete(id: deleted)
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func meta(_ id: UUID, day: Int, title: String? = nil) -> MeetingMetaWithLocalState {
        let start = Date(timeIntervalSince1970: 1_793_491_200 + Double(day - 1) * 86_400 + 36_000) // Nov 2026, 10:00 UTC
        return MeetingMetaWithLocalState(
            id: id, startedAt: start, endedAt: start.addingTimeInterval(1800), durationSeconds: 1800,
            title: title, syncStatus: .new, serverVersion: 1, createdAt: start)
    }

    private func call(_ operation: String, _ args: [String: AppControlValue] = [:]) async -> AppControlResponse {
        await tools.handle(operation, args)
    }

    private func meetings(_ response: AppControlResponse) -> [[String: AppControlValue]] {
        response.data.object?["meetings"]?.array?.compactMap(\.object) ?? []
    }

    // MARK: Search

    func test_where_did_we_discuss_prices_is_answered_in_one_call() async {
        // "ценах" is another case of the word in the note and the replies.
        let response = await call("meetings_search", ["query": .string("ценах Егор")])
        XCTAssertTrue(response.ok)
        let hits = meetings(response)
        XCTAssertEqual(hits.count, 1)
        let hit = hits[0]
        XCTAssertEqual(hit["id"], .string(pricing.uuidString))
        XCTAssertEqual(hit["title"], .string("Тарифы на 2027"), "the note's heading when no title was set")
        XCTAssertEqual(hit["link"], .string("whytap://meeting/11111111222233334444555555555555"))
        XCTAssertEqual(hit["durationSeconds"], .int(1800))
        XCTAssertEqual(hit["transcriptSegments"], .int(4))
        XCTAssertTrue(hit["noteSnippet"]?.string?.contains("поднять цены") == true)
        let matches = hit["matches"]?.array?.compactMap(\.object) ?? []
        XCTAssertEqual(matches.first?["index"], .int(1), "the reply with both words leads")
        XCTAssertEqual(matches.first?["startMs"], .int(4250))
        XCTAssertEqual(matches.first?["endMs"], .int(9500))
        XCTAssertEqual(matches.first?["speaker"], .string("Speaker 2"))
        XCTAssertEqual(matches.map { $0["index"] }, [.int(1), .int(3)], "in the order they were said")
    }

    func test_every_word_must_be_somewhere_in_the_meeting() async {
        let none = await call("meetings_search", ["query": .string("цены engineers")])
        XCTAssertEqual(meetings(none).count, 0)
        XCTAssertEqual(none.data.object?["total"], .int(0))
        // A word only in the title still finds the meeting.
        let titled = await call("meetings_search", ["query": .string("hiring")])
        XCTAssertEqual(meetings(titled).map { $0["id"] }, [.string(hiring.uuidString)])
    }

    func test_the_old_embedded_transcript_copy_is_not_part_of_the_note() async {
        let response = await call("meetings_search", ["query": .string("старая копия")])
        XCTAssertEqual(meetings(response).count, 0)
    }

    func test_without_a_query_the_newest_meetings_are_listed() async {
        let response = await call("meetings_search", ["limit": .int(1)])
        XCTAssertEqual(meetings(response).map { $0["id"] }, [.string(hiring.uuidString)])
        XCTAssertEqual(response.data.object?["total"], .int(2))
        XCTAssertEqual(meetings(response)[0]["matches"], .array([]))
    }

    func test_dates_limit_the_search_by_local_day() async {
        let day = await call("meetings_search", ["from": .string("2026-11-10"), "to": .string("2026-11-10")])
        XCTAssertEqual(meetings(day).map { $0["id"] }, [.string(pricing.uuidString)])
        let later = await call("meetings_search", ["from": .string("2026-11-11T00:00:00Z")])
        XCTAssertEqual(meetings(later).map { $0["id"] }, [.string(hiring.uuidString)])
        let before = await call("meetings_search", ["to": .string("2026-11-09")])
        XCTAssertEqual(meetings(before).count, 0)
        let fractional = await call("meetings_search", ["from": .string("2026-11-11T00:00:00.000Z")])
        XCTAssertEqual(meetings(fractional).map { $0["id"] }, [.string(hiring.uuidString)])
    }

    func test_malformed_requests_are_refused_whole() async {
        let bad: [[String: AppControlValue]] = [
            ["query": .int(1)], ["limit": .int(0)], ["limit": .int(26)], ["from": .string("yesterday")],
            ["to": .string("2026-13-40")], ["speaker": .string("x")], ["query": .string(String(repeating: "a", count: 257))],
        ]
        for args in bad {
            let response = await call("meetings_search", args)
            XCTAssertEqual(response.data.object?["code"], .string("invalid_arguments"), "\(args)")
        }
    }

    // MARK: Note

    func test_the_note_is_read_by_either_form_of_the_id() async {
        for id in [pricing.uuidString, "11111111222233334444555555555555", pricing.uuidString.lowercased()] {
            let response = await call("meeting_get", ["id": .string(id)])
            let note = response.data.object?["note"]?.string
            XCTAssertTrue(note?.contains("Решили поднять цены") == true, id)
            XCTAssertFalse(note?.contains("старая копия") == true)
            XCTAssertEqual(response.data.object?["noteTruncated"], .bool(false))
        }
    }

    func test_a_long_note_is_cut_at_a_whole_character() async throws {
        let long = UUID()
        try await store.insert(meta: meta(long, day: 20), markdown: "# Долгая\n\n" + String(repeating: "ы", count: 5000))
        let response = await call("meeting_get", ["id": .string(long.uuidString), "maxBytes": .int(1001)])
        let note = try XCTUnwrap(response.data.object?["note"]?.string)
        XCTAssertLessThanOrEqual(note.utf8.count, 1001)
        XCTAssertEqual(note.utf8.count, 1000, "an odd budget never splits a two-byte letter")
        XCTAssertEqual(response.data.object?["noteTruncated"], .bool(true))
    }

    func test_an_unknown_or_deleted_meeting_is_named_as_such() async {
        for operation in ["meeting_get", "meeting_transcript", "meeting_open"] {
            let gone = await call(operation, ["id": .string(deleted.uuidString)])
            XCTAssertEqual(gone.data.object?["code"], .string("unknown_meeting"), operation)
            let garbage = await call(operation, ["id": .string("../../etc/passwd")])
            XCTAssertEqual(garbage.data.object?["code"], .string("invalid_arguments"), operation)
        }
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: Transcript

    func test_the_transcript_is_read_around_a_moment_from_the_search() async {
        let response = await call("meeting_transcript", ["id": .string(pricing.uuidString), "aroundMs": .int(16_000)])
        let segments = response.data.object?["segments"]?.array?.compactMap(\.object) ?? []
        XCTAssertEqual(segments.map { $0["index"] }, [.int(0), .int(1), .int(2), .int(3)], "three replies of lead-in")
        XCTAssertEqual(segments.last?["speaker"], .null)
        XCTAssertEqual(response.data.object?["total"], .int(4))
        XCTAssertEqual(response.data.object?["nextIndex"], .null)
    }

    func test_a_long_transcript_is_paged_until_next_index_is_null() async {
        var seen: [Int] = []
        var from = 0
        while true {
            let page = await call("meeting_transcript",
                ["id": .string(pricing.uuidString), "fromIndex": .int(from), "limit": .int(3)])
            seen += page.data.object?["segments"]?.array?.compactMap { $0.object?["index"]?.int } ?? []
            guard let next = page.data.object?["nextIndex"]?.int else { break }
            XCTAssertGreaterThan(next, from)
            from = next
        }
        XCTAssertEqual(seen, [0, 1, 2, 3])
    }

    func test_the_byte_budget_ends_a_page_but_never_returns_an_empty_one() async {
        let page = await call("meeting_transcript", ["id": .string(pricing.uuidString), "maxBytes": .int(1000), "limit": .int(500)])
        XCTAssertEqual(page.data.object?["segments"]?.array?.count, 4)

        let long = UUID()
        try? await store.insert(meta: meta(long, day: 21), markdown: "# L", transcript: (0..<3).map {
            TranscriptSegment(speaker: nil, start: Double($0), end: Double($0) + 1, text: String(repeating: "x", count: 900))
        })
        let first = await call("meeting_transcript", ["id": .string(long.uuidString), "maxBytes": .int(1000)])
        XCTAssertEqual(first.data.object?["segments"]?.array?.count, 1)
        XCTAssertEqual(first.data.object?["nextIndex"], .int(1))
    }

    /// Some providers return a whole meeting as one reply.
    func test_one_very_long_reply_is_read_in_parts_that_join_back_exactly() async throws {
        let whole = UUID()
        let text = (0..<1000).map { "слово\($0)" }.joined(separator: " ")
        try await store.insert(meta: meta(whole, day: 23), markdown: "# One", transcript: [
            TranscriptSegment(speaker: nil, start: 0, end: 1800, text: text),
            TranscriptSegment(speaker: nil, start: 1800, end: 1801, text: "конец"),
        ])
        var joined = ""
        var args: [String: AppControlValue] = ["id": .string(whole.uuidString), "maxBytes": .int(1000)]
        var calls = 0
        while true {
            calls += 1
            let page = await call("meeting_transcript", args)
            XCTAssertTrue(page.ok)
            let segments = page.data.object?["segments"]?.array?.compactMap(\.object) ?? []
            for segment in segments where segment["index"] == .int(0) {
                let part = try XCTUnwrap(segment["text"]?.string)
                XCTAssertLessThanOrEqual(part.utf8.count, 1000)
                XCTAssertEqual(segment["offset"]?.int ?? 0, joined.count)
                joined += part
            }
            guard let next = page.data.object?["nextIndex"]?.int else { break }
            args["fromIndex"] = .int(next)
            args["fromOffset"] = page.data.object?["nextOffset"] ?? .int(0)
            if args["fromOffset"] == .null { args["fromOffset"] = nil }
            XCTAssertLessThan(calls, 100)
        }
        XCTAssertEqual(joined, text)
        XCTAssertGreaterThan(calls, 5)
        let offsetOnly = await call("meeting_transcript", ["id": .string(whole.uuidString), "fromOffset": .int(5)])
        XCTAssertEqual(offsetOnly.data.object?["code"], .string("invalid_arguments"))
    }

    func test_reading_past_the_end_and_conflicting_starts() async {
        let past = await call("meeting_transcript", ["id": .string(pricing.uuidString), "fromIndex": .int(99)])
        XCTAssertEqual(past.data.object?["segments"], .array([]))
        XCTAssertEqual(past.data.object?["nextIndex"], .null)
        let both = await call("meeting_transcript",
            ["id": .string(pricing.uuidString), "fromIndex": .int(1), "aroundMs": .int(5)])
        XCTAssertEqual(both.data.object?["code"], .string("invalid_arguments"))
        let negative = await call("meeting_transcript", ["id": .string(pricing.uuidString), "fromIndex": .int(-1)])
        XCTAssertEqual(negative.data.object?["code"], .string("invalid_arguments"))
    }

    func test_a_meeting_without_a_transcript_reads_as_empty() async {
        let bare = UUID()
        try? await store.insert(meta: meta(bare, day: 22), markdown: "# Bare")
        let response = await call("meeting_transcript", ["id": .string(bare.uuidString)])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.data.object?["total"], .int(0))
    }

    // MARK: Open, store

    func test_open_shows_exactly_that_note() async {
        let response = await call("meeting_open", ["id": .string(pricing.uuidString)])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(opened, [pricing])
        openResult = .unavailable
        let refused = await call("meeting_open", ["id": .string(pricing.uuidString)])
        XCTAssertEqual(refused.data.object?["code"], .string("unavailable"))
        // The user is in the middle of editing a note: it is not replaced.
        openResult = .editing
        let busy = await call("meeting_open", ["id": .string(pricing.uuidString)])
        XCTAssertEqual(busy.data.object?["code"], .string("busy"))
        XCTAssertEqual(opened, [pricing])
    }

    func test_without_a_meetings_store_every_tool_says_unavailable() async {
        let broken = AppControlMeetings(source: { nil }, open: { _ in .shown })
        for operation in AppControlMeetings.operations {
            let response = await broken.handle(operation, ["id": .string(pricing.uuidString)])
            XCTAssertEqual(response.data.object?["code"], .string("unavailable"), operation)
        }
    }

    func test_the_controller_offers_meeting_tools_only_when_wired_behind_the_gate() async {
        let bare = AppControlController()
        let response = await bare.handle(AppControlRequest("meetings_search"))
        XCTAssertEqual(response.data.object?["code"], .string("unavailable"))
        let wired = AppControlController(meetings: tools)
        let listed = await wired.handle(AppControlRequest("meetings_search"))
        XCTAssertEqual(meetings(listed).count, 2)
    }

    // MARK: Matching rules

    func test_query_words_become_stems_and_duplicates_collapse() {
        XCTAssertEqual(MeetingTextSearch.needles("Цены, ценах и ЦЕНЫ!"), ["Цен"])
        XCTAssertEqual(MeetingTextSearch.needles("Егор Маша цена"), ["Егор", "Маш", "цен"])
        XCTAssertEqual(MeetingTextSearch.needles("iOS 17 pricing"), ["iOS", "17", "pricin"])
        XCTAssertEqual(MeetingTextSearch.needles("a  -- "), [])
        XCTAssertEqual(MeetingTextSearch.needles((1...20).map { "w\($0)x" }.joined(separator: " ")).count, MeetingTextSearch.maxTerms)
        XCTAssertTrue(MeetingTextSearch.contains("елка", in: "Новогодняя ЁЛКА"))
        XCTAssertNil(MeetingTextSearch.snippet(["нет"], in: "ничего похожего"))
        XCTAssertEqual(MeetingTextSearch.heading(of: "<!-- protocol:v1 -->\n\n#  Title \nbody"), "Title")
        XCTAssertNil(MeetingTextSearch.heading(of: "## Only a subheading"))
    }
}
