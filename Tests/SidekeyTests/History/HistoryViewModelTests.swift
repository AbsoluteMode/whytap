import XCTest
@testable import Sidekey

@MainActor
final class HistoryViewModelTests: XCTestCase {
    func testRefreshLoadsEntriesFromStoreNewestFirst() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        _ = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 100),
            queryText: "older",
            queryMode: .text,
            responseMarkdown: "old body",
            toolNames: []
        )
        _ = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 200),
            queryText: "newer",
            queryMode: .voice,
            responseMarkdown: "new body",
            toolNames: ["search"]
        )
        _ = try store.insertDropEntry(
            createdAt: Date(timeIntervalSince1970: 150),
            rawTranscript: "raw",
            formattedText: "Formatted.",
            targetApp: "Mail"
        )

        let viewModel = HistoryViewModel(store: store)
        viewModel.refresh()

        XCTAssertEqual(viewModel.agentEntries.count, 2)
        XCTAssertEqual(viewModel.agentEntries.first?.queryText, "newer")
        XCTAssertEqual(viewModel.agentEntries.first?.queryMode, .voice)
        XCTAssertEqual(viewModel.dropEntries.count, 1)
        XCTAssertEqual(viewModel.dropEntries.first?.targetApp, "Mail")
    }

    func testRefreshShowsEmptyArraysWhenStoreEmpty() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let viewModel = HistoryViewModel(store: store)

        viewModel.refresh()

        XCTAssertTrue(viewModel.agentEntries.isEmpty)
        XCTAssertTrue(viewModel.dropEntries.isEmpty)
    }

    func testRefreshPicksUpRowsAddedAfterInit() throws {
        let store = try SQLiteHistoryStore(path: ":memory:")
        let viewModel = HistoryViewModel(store: store)
        viewModel.refresh()
        XCTAssertTrue(viewModel.agentEntries.isEmpty)

        _ = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 9),
            queryText: "after",
            queryMode: .text,
            responseMarkdown: "body",
            toolNames: []
        )
        viewModel.refresh()

        XCTAssertEqual(viewModel.agentEntries.count, 1)
        XCTAssertEqual(viewModel.agentEntries.first?.queryText, "after")
    }
}
