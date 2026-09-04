import XCTest
@testable import Sidekey

@MainActor
final class IslandFillerViewModelTests: XCTestCase {
    private func makeViewModel() -> IslandFillerViewModel {
        let suite = "test.filler.vm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return IslandFillerViewModel(store: FillerTermsStore(defaults: defaults))
    }

    func testSubmitAddsTermAndClearsQuery() {
        let vm = makeViewModel()
        vm.query = "мм"
        vm.submitCurrentQuery()
        XCTAssertEqual(vm.terms, ["мм"])
        XCTAssertEqual(vm.query, "")
        XCTAssertNil(vm.lastRejection)
    }

    func testSubmitDuplicateSetsRejection() {
        let vm = makeViewModel()
        vm.query = "мм"; vm.submitCurrentQuery()
        vm.query = "Мм"; vm.submitCurrentQuery()
        XCTAssertEqual(vm.terms, ["мм"])
        XCTAssertEqual(vm.lastRejection, .duplicate)
    }

    func testRemoveUpdatesTerms() {
        let vm = makeViewModel()
        vm.query = "мм"; vm.submitCurrentQuery()
        vm.removeTerm("мм")
        XCTAssertEqual(vm.terms, [])
    }

    func testChangingQueryClearsRejection() {
        let vm = makeViewModel()
        vm.query = "  "; vm.submitCurrentQuery()
        XCTAssertEqual(vm.lastRejection, .empty)
        vm.query = "ok"
        XCTAssertNil(vm.lastRejection)
    }
}
