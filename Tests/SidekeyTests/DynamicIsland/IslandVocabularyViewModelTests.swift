import XCTest
@testable import Sidekey

@MainActor
final class IslandVocabularyViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var vocabulary: VocabularyCache!
    private var viewModel: IslandVocabularyViewModel!

    override func setUp() {
        super.setUp()
        // Isolated UserDefaults suite (UUID-namespaced) so the persist path
        // never touches the runner's real `.standard` defaults.
        suiteName = "test.sidekey.island.vocab.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        vocabulary = VocabularyCache(defaults: defaults)
        viewModel = IslandVocabularyViewModel(vocabulary: vocabulary)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        viewModel = nil
        vocabulary = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_loadReadsVocabularyAndShowsLatestTermsFirst() async {
        vocabulary.setTerms(["Sidekey", "Notion", "Soniox"])

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.terms, ["Sidekey", "Notion", "Soniox"])
        XCTAssertEqual(viewModel.visibleTerms, ["Soniox", "Notion", "Sidekey"])
    }

    func test_queryFiltersTermsCaseInsensitively() async {
        vocabulary.setTerms(["Sidekey", "Linear", "Soniox"])
        await viewModel.loadIfNeeded()

        viewModel.query = "si"

        XCTAssertEqual(viewModel.visibleTerms, ["Sidekey"])
    }

    func test_submitCurrentQueryAddsTrimmedTermClearsQueryAndPersists() async {
        vocabulary.setTerms(["Sidekey"])
        await viewModel.loadIfNeeded()

        viewModel.query = "  Rootwise  "
        await viewModel.submitCurrentQuery()

        XCTAssertEqual(viewModel.query, "")
        XCTAssertEqual(viewModel.terms, ["Sidekey", "Rootwise"])
        XCTAssertEqual(viewModel.state, .loaded)
        // Persisted straight into the local store, no server round-trip.
        XCTAssertEqual(vocabulary.terms, ["Sidekey", "Rootwise"])
    }

    func test_submitDuplicateShowsExistingTermAndDoesNotPersist() async {
        vocabulary.setTerms(["Sidekey"])
        await viewModel.loadIfNeeded()

        viewModel.query = "sidekey"
        await viewModel.submitCurrentQuery()

        XCTAssertEqual(viewModel.query, "sidekey")
        XCTAssertEqual(viewModel.terms, ["Sidekey"])
        XCTAssertEqual(viewModel.visibleTerms, ["Sidekey"])
        XCTAssertEqual(viewModel.lastRejection, .duplicate)
        XCTAssertEqual(vocabulary.terms, ["Sidekey"])
    }

    func test_editingQueryClearsLastRejection() async {
        vocabulary.setTerms(["Sidekey"])
        await viewModel.loadIfNeeded()
        viewModel.query = "sidekey"
        await viewModel.submitCurrentQuery()
        XCTAssertEqual(viewModel.lastRejection, .duplicate)

        viewModel.query = "sidekey2"

        XCTAssertNil(viewModel.lastRejection)
    }

    func test_removeTermDeletesAndPersists() async {
        vocabulary.setTerms(["Sidekey", "Rootwise"])
        await viewModel.loadIfNeeded()

        await viewModel.removeTerm("Sidekey")

        XCTAssertEqual(viewModel.terms, ["Rootwise"])
        XCTAssertEqual(vocabulary.terms, ["Rootwise"])
    }

    func test_submitBeforeLoadHydratesStoredTermsFirst() async {
        // The hover panel can submit before an explicit load: the view model
        // must read the stored terms first so the add does not clobber them.
        vocabulary.setTerms(["Alpha"])

        viewModel.query = "Beta"
        await viewModel.submitCurrentQuery()

        XCTAssertEqual(viewModel.terms, ["Alpha", "Beta"])
        XCTAssertEqual(vocabulary.terms, ["Alpha", "Beta"])
    }
}
