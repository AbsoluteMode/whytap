import XCTest
@testable import Sidekey

final class IslandHistoryCardsTests: XCTestCase {
    /// Captures state mutated from inside the `@Sendable` fetch closure.
    /// `@unchecked Sendable` is safe here: the closure runs to completion
    /// before `await` returns, so the test thread only reads after the
    /// write — there is no concurrent access.
    private final class Probe: @unchecked Sendable {
        var ranOnMain = true
        var receivedMode: HistoryStripMode?
    }

    func testLoadReturnsFetchedCards() async {
        let cards = await IslandHistoryCards.load(mode: .clipboard) { _ in
            [.drop(.init(
                id: 7,
                createdAt: Date(timeIntervalSince1970: 1),
                formattedText: "hello",
                targetApp: "Notes"
            ))]
        }

        XCTAssertEqual(cards, [
            .drop(.init(
                id: 7,
                createdAt: Date(timeIntervalSince1970: 1),
                formattedText: "hello",
                targetApp: "Notes"
            ))
        ])
    }

    func testLoadPassesModeToFetch() async {
        let probe = Probe()

        _ = await IslandHistoryCards.load(mode: .agent) { mode in
            probe.receivedMode = mode
            return []
        }

        XCTAssertEqual(probe.receivedMode, .agent)
    }

    func testLoadRunsFetchOffTheMainThread() async {
        let probe = Probe()

        _ = await IslandHistoryCards.load(mode: .drop) { _ in
            probe.ranOnMain = Thread.isMainThread
            return []
        }

        XCTAssertFalse(
            probe.ranOnMain,
            "history fetch must run off the main thread so the SwiftUI body never blocks on a synchronous SQLite read"
        )
    }
}
