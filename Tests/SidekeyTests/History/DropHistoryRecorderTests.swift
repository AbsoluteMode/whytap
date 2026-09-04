import XCTest
@testable import Sidekey

final class DropHistoryRecorderTests: XCTestCase {
    func testRecordWritesDropEntryToStore() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let recorder = DropHistoryRecorder(
            store: store,
            clock: { Date(timeIntervalSince1970: 100) }
        )

        recorder.record(
            rawTranscript: "um hello world",
            formattedText: "Hello, world.",
            targetApp: "Mail"
        )

        let entries = try store.latestDropEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.rawTranscript, "um hello world")
        XCTAssertEqual(entries.first?.formattedText, "Hello, world.")
        XCTAssertEqual(entries.first?.targetApp, "Mail")
        XCTAssertEqual(entries.first?.createdAt, Date(timeIntervalSince1970: 100))
    }

    func testRecordSwallowsStoreErrors() {
        let recorder = DropHistoryRecorder(store: ThrowingHistoryStore(), clock: Date.init)
        // Must not throw — best-effort.
        recorder.record(
            rawTranscript: "raw",
            formattedText: "Formatted.",
            targetApp: nil
        )
    }
}

private final class ThrowingHistoryStore: HistoryStore, @unchecked Sendable {
    func insertAgentEntry(
        createdAt: Date,
        queryText: String,
        queryMode: HistoryQueryMode,
        responseMarkdown: String,
        toolNames: [String]
    ) throws -> Int64 {
        throw NSError(domain: "test", code: 1)
    }

    func insertDropEntry(
        createdAt: Date,
        rawTranscript: String,
        formattedText: String,
        targetApp: String?
    ) throws -> Int64 {
        throw NSError(domain: "test", code: 1)
    }

    func latestAgentEntries(limit: Int) throws -> [AgentHistoryEntry] { [] }
    func latestDropEntries(limit: Int) throws -> [DropHistoryEntry] { [] }
}
