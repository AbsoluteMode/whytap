import XCTest
@testable import Sidekey

final class FillerTermsStoreTests: XCTestCase {
    private func makeStore() -> (FillerTermsStore, UserDefaults) {
        let suite = "test.filler.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (FillerTermsStore(defaults: defaults), defaults)
    }

    func testStartsEmpty() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.terms(), [])
    }

    func testAddPersistsAndRoundTrips() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.add("мм"), .added)
        XCTAssertEqual(store.terms(), ["мм"])
    }

    func testRejectsEmpty() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.add("   "), .rejected(.empty))
        XCTAssertEqual(store.terms(), [])
    }

    func testRejectsTooLong() {
        let (store, _) = makeStore()
        let long = String(repeating: "a", count: FillerTermsStore.maxTermLength + 1)
        XCTAssertEqual(store.add(long), .rejected(.tooLong))
    }

    func testRejectsDuplicateCaseInsensitive() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.add("Мм"), .added)
        XCTAssertEqual(store.add("мм"), .rejected(.duplicate))
        XCTAssertEqual(store.terms(), ["Мм"])
    }

    func testRejectsWhenFull() {
        let (store, _) = makeStore()
        for i in 0..<FillerTermsStore.maxTermCount {
            XCTAssertEqual(store.add("term\(i)"), .added)
        }
        XCTAssertEqual(store.add("overflow"), .rejected(.tooMany))
    }

    func testRemoveIsCaseInsensitive() {
        let (store, _) = makeStore()
        store.add("Мм")
        store.remove("мм")
        XCTAssertEqual(store.terms(), [])
    }

    func testTrimsBeforeStoring() {
        let (store, _) = makeStore()
        store.add("  ага  ")
        XCTAssertEqual(store.terms(), ["ага"])
    }
}
