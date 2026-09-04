import XCTest
@testable import Sidekey

final class HistoryStoreTests: XCTestCase {
    private func makeStore() throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(path: ":memory:")
    }

    func testInsertAgentEntryAssignsIdAndIsReturnedByLatest() throws {
        let store = try makeStore()
        let id = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1_000),
            queryText: "hello",
            queryMode: .text,
            responseMarkdown: "world",
            toolNames: ["search.web"]
        )

        XCTAssertGreaterThan(id, 0)

        let entries = try store.latestAgentEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.queryText, "hello")
        XCTAssertEqual(entries.first?.queryMode, .text)
        XCTAssertEqual(entries.first?.responseMarkdown, "world")
        XCTAssertEqual(entries.first?.toolNames, ["search.web"])
        XCTAssertEqual(entries.first?.createdAt, Date(timeIntervalSince1970: 1_000))
    }

    func testLatestAgentEntriesSortsByCreatedAtDescending() throws {
        let store = try makeStore()
        _ = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1_000),
            queryText: "first",
            queryMode: .text,
            responseMarkdown: "r1",
            toolNames: []
        )
        _ = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 3_000),
            queryText: "third",
            queryMode: .voice,
            responseMarkdown: "r3",
            toolNames: ["a", "b"]
        )
        _ = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 2_000),
            queryText: "second",
            queryMode: .text,
            responseMarkdown: "r2",
            toolNames: []
        )

        let entries = try store.latestAgentEntries(limit: 10)

        XCTAssertEqual(entries.map(\.queryText), ["third", "second", "first"])
        XCTAssertEqual(entries[0].toolNames, ["a", "b"])
        XCTAssertEqual(entries[0].queryMode, .voice)
    }

    func testLatestAgentEntriesRespectsLimit() throws {
        let store = try makeStore()
        for i in 0..<5 {
            _ = try store.insertAgentEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                queryText: "q\(i)",
                queryMode: .text,
                responseMarkdown: "r\(i)",
                toolNames: []
            )
        }

        let entries = try store.latestAgentEntries(limit: 3)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.queryText), ["q4", "q3", "q2"])
    }

    func testInsertDropEntryAssignsIdAndIsReturnedByLatest() throws {
        let store = try makeStore()
        let id = try store.insertDropEntry(
            createdAt: Date(timeIntervalSince1970: 5_000),
            rawTranscript: "um hello",
            formattedText: "Hello.",
            targetApp: "TextEdit"
        )

        XCTAssertGreaterThan(id, 0)

        let entries = try store.latestDropEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.rawTranscript, "um hello")
        XCTAssertEqual(entries.first?.formattedText, "Hello.")
        XCTAssertEqual(entries.first?.targetApp, "TextEdit")
        XCTAssertEqual(entries.first?.createdAt, Date(timeIntervalSince1970: 5_000))
    }

    func testLatestDropEntriesSortsByCreatedAtDescending() throws {
        let store = try makeStore()
        _ = try store.insertDropEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            rawTranscript: "older",
            formattedText: "Older.",
            targetApp: nil
        )
        _ = try store.insertDropEntry(
            createdAt: Date(timeIntervalSince1970: 99),
            rawTranscript: "newer",
            formattedText: "Newer.",
            targetApp: "Mail"
        )

        let entries = try store.latestDropEntries(limit: 10)

        XCTAssertEqual(entries.map(\.rawTranscript), ["newer", "older"])
    }

    func testDropEntryNullableTargetAppRoundtrip() throws {
        let store = try makeStore()
        _ = try store.insertDropEntry(
            createdAt: Date(timeIntervalSince1970: 10),
            rawTranscript: "anywhere",
            formattedText: "Anywhere.",
            targetApp: nil
        )
        let entries = try store.latestDropEntries(limit: 1)
        XCTAssertNil(entries.first?.targetApp)
    }

    func testToolNamesEmptyArrayRoundtripsCleanly() throws {
        let store = try makeStore()
        _ = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            queryText: "no tools",
            queryMode: .text,
            responseMarkdown: "body",
            toolNames: []
        )
        let entries = try store.latestAgentEntries(limit: 1)
        XCTAssertEqual(entries.first?.toolNames, [])
    }

    func testEntriesPersistInFileBackedStoreAcrossInstances() throws {
        // Use a temp file path so we can re-open the same DB and confirm
        // entries persist beyond a single process lifetime.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sidekey-history-test-\(UUID().uuidString).sqlite"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let store = try SQLiteHistoryStore(path: tmp.path)
            _ = try store.insertAgentEntry(
                createdAt: Date(timeIntervalSince1970: 1),
                queryText: "persists",
                queryMode: .text,
                responseMarkdown: "yes",
                toolNames: ["t"]
            )
        }

        let reopened = try SQLiteHistoryStore(path: tmp.path)
        let entries = try reopened.latestAgentEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.queryText, "persists")
        XCTAssertEqual(entries.first?.toolNames, ["t"])
    }
}
