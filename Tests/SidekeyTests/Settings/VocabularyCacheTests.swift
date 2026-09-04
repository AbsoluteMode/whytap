import XCTest
@testable import Sidekey

final class VocabularyCacheTests: XCTestCase {
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: "vocab.test.\(UUID().uuidString)")! }

    func testDefaultsEmpty() {
        XCTAssertEqual(VocabularyCache(defaults: makeDefaults()).terms, [])
    }

    func testStoreAndRead() {
        let d = makeDefaults()
        let cache = VocabularyCache(defaults: d)
        cache.setTerms(["Whytap", "Doppler"])
        XCTAssertEqual(VocabularyCache(defaults: d).terms, ["Whytap", "Doppler"])
    }
}
