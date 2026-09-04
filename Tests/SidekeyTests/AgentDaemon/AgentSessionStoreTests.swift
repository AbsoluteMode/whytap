import XCTest
@testable import Sidekey

@MainActor
final class AgentSessionStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-agent-sessions-\(UUID().uuidString).json")
    }

    func testPersistsProviderSessionsIndependently() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = AgentSessionStore(fileURL: url)
        XCTAssertNil(store.sessionID(for: .claude))
        XCTAssertNil(store.sessionID(for: .codex))

        store.setSessionID("claude-session", for: .claude)
        store.setSessionID("codex-thread", for: .codex)

        let reloaded = AgentSessionStore(fileURL: url)
        XCTAssertEqual(reloaded.sessionID(for: .claude), "claude-session")
        XCTAssertEqual(reloaded.sessionID(for: .codex), "codex-thread")
    }

    func testClearingOneProviderKeepsTheOtherSession() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = AgentSessionStore(fileURL: url)
        store.setSessionID("claude-session", for: .claude)
        store.setSessionID("codex-thread", for: .codex)
        store.setSessionID(nil, for: .claude)

        let reloaded = AgentSessionStore(fileURL: url)
        XCTAssertNil(reloaded.sessionID(for: .claude))
        XCTAssertEqual(reloaded.sessionID(for: .codex), "codex-thread")
    }

    // MARK: - Resume window (sessions go stale after 15 minutes of silence)

    func testSessionOlderThanResumeWindowIsNotReturned() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = AgentSessionStore(fileURL: url, now: { now })
        store.setSessionID("codex-thread", for: .codex)

        now = now.addingTimeInterval(AgentSessionStore.resumeWindow - 1)
        XCTAssertEqual(store.sessionID(for: .codex), "codex-thread")

        now = now.addingTimeInterval(2)
        XCTAssertNil(store.sessionID(for: .codex), "a turn after the window must start a fresh session")
    }

    func testEachTurnSlidesTheWindowForward() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = AgentSessionStore(fileURL: url, now: { now })
        store.setSessionID("codex-thread", for: .codex)

        // 10 minutes later the same session is refreshed by another turn.
        now = now.addingTimeInterval(10 * 60)
        store.setSessionID("codex-thread", for: .codex)

        // 10 more minutes: 20 from the first turn, 10 from the last -> alive.
        now = now.addingTimeInterval(10 * 60)
        XCTAssertEqual(store.sessionID(for: .codex), "codex-thread")
    }

    func testWindowSurvivesReload() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var now = Date(timeIntervalSince1970: 1_000_000)
        AgentSessionStore(fileURL: url, now: { now }).setSessionID("claude-session", for: .claude)

        let fresh = AgentSessionStore(fileURL: url, now: { now })
        XCTAssertEqual(fresh.sessionID(for: .claude), "claude-session")

        now = now.addingTimeInterval(AgentSessionStore.resumeWindow + 1)
        let stale = AgentSessionStore(fileURL: url, now: { now })
        XCTAssertNil(stale.sessionID(for: .claude))
    }

    func testLegacySnapshotWithoutTimestampIsTreatedAsStale() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // A sessions.json written by builds that predate the resume window —
        // no timestamps. Must not resume a session of unknown age.
        try Data(#"{"claude":"old-claude","codex":"old-codex"}"#.utf8).write(to: url)

        let store = AgentSessionStore(fileURL: url)
        XCTAssertNil(store.sessionID(for: .claude))
        XCTAssertNil(store.sessionID(for: .codex))
    }
}
