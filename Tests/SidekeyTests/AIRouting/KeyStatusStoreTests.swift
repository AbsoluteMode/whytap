import XCTest
@testable import Sidekey

@MainActor
final class KeyStatusStoreTests: XCTestCase {
    private let storageKey = "sidekey.aiRouting.keyStatus.v1"

    private func makeDefaults() -> UserDefaults {
        let suite = "KeyStatusStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func test_needs_check_after_a_day() {
        let store = KeyStatusStore(defaults: makeDefaults())
        let checked = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(store.needsCheck(.soniox, now: checked))
        store.set(.valid, for: .soniox, at: checked)
        XCTAssertFalse(store.needsCheck(.soniox, now: checked.addingTimeInterval(86_399)))
        XCTAssertTrue(store.needsCheck(.soniox, now: checked.addingTimeInterval(86_400)))
        XCTAssertTrue(store.needsCheck(.deepgram, now: checked))
    }

    func test_records_survive_relaunch() {
        let defaults = makeDefaults()
        let date = Date(timeIntervalSince1970: 2_000_000)
        let serverID = UUID()
        let first = KeyStatusStore(defaults: defaults)
        first.set(.rejected(.outOfCredit), for: .openRouter, at: date)
        first.set(.limited, for: .server(serverID), at: date)
        let second = KeyStatusStore(defaults: defaults)
        XCTAssertEqual(second.record(for: .openRouter), KeyCheckRecord(status: .rejected(.outOfCredit), checkedAt: date))
        XCTAssertEqual(second.record(for: .server(serverID))?.status, .limited)
        XCTAssertNil(second.record(for: .soniox))
    }

    func test_failed_checks_retry_soon_without_rechecking_healthy_keys() {
        let store = KeyStatusStore(defaults: makeDefaults())
        let checked = Date(timeIntervalSince1970: 1_000_000)
        for status in [KeyStatus.rejected(.outOfCredit), .rejected(.invalidKey)] {
            store.set(status, for: .openRouter, at: checked)
            XCTAssertFalse(store.needsCheck(.openRouter, now: checked.addingTimeInterval(299)))
            XCTAssertTrue(store.needsCheck(.openRouter, now: checked.addingTimeInterval(300)))
        }
        store.set(.unreachable, for: .openRouter, at: checked)
        XCTAssertFalse(store.needsCheck(.openRouter, now: checked.addingTimeInterval(59)))
        XCTAssertTrue(store.needsCheck(.openRouter, now: checked.addingTimeInterval(60)))
        store.set(.valid, for: .openRouter, at: checked)
        XCTAssertFalse(store.needsCheck(.openRouter, now: checked.addingTimeInterval(300)))
    }

    func test_forget_removes_the_record() {
        let defaults = makeDefaults()
        let store = KeyStatusStore(defaults: defaults)
        store.set(.valid, for: .deepgram, at: Date())
        store.forget(.deepgram)
        XCTAssertNil(store.record(for: .deepgram))
        XCTAssertNil(KeyStatusStore(defaults: defaults).record(for: .deepgram))
    }

    func test_store_never_contains_the_key() throws {
        let defaults = makeDefaults()
        let secret = "sk-very-secret-key-1234"
        let store = KeyStatusStore(defaults: defaults)
        store.set(.valid, for: .soniox, at: Date())
        store.set(.rejected(.invalidKey), for: .openRouter, at: Date())
        let data = try XCTUnwrap(defaults.data(forKey: storageKey))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
        XCTAssertTrue(json.contains("soniox"))
    }

    func test_garbage_in_defaults_reads_as_empty() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: storageKey)
        XCTAssertNil(KeyStatusStore(defaults: defaults).record(for: .soniox))
    }
}
