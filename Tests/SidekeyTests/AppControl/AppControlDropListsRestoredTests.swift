import XCTest
import WhytapCaseKit
@testable import Sidekey

@MainActor
final class AppControlDropListsRestoredTests: XCTestCase {
    func testRemoveFindsNamedWordsRestoredWithSpaces() throws {
        let suite = "builder-722-restore-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = ["  Fixture  ", "Other"]
        try ConfigBackupRegistry.apply([
            "sidekey.preferences.vocabularyTerms": .strings(saved),
            "sidekey.replace.terms": .strings(saved)
        ], sections: [.vocabulary], to: defaults)
        let vocab = VocabularyCache(defaults: defaults)
        let filler = FillerTermsStore(defaults: defaults)
        XCTAssertEqual(vocab.terms, saved)
        XCTAssertEqual(filler.terms(), saved)
        let lists = AppControlDropLists(vocabulary: { vocab }, fillers: { filler })
        for op in ["vocab_remove", "filler_remove"] {
            let response = lists.handle(op, ["terms": .array([.string("fixture")])])
            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.data.object?["terms"]?.array?.first?.object?["result"], .string("removed"), op)
            XCTAssertEqual(op == "vocab_remove" ? vocab.terms : filler.terms(), ["Other"], op)
        }
    }
}
