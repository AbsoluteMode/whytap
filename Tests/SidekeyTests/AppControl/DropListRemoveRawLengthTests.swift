import XCTest
import WhytapCaseKit
@testable import Sidekey

/// Build-queue probe 724: the remove tools' advertised maxLength counts code
/// points of the raw string; one over-long term in a batch removes nothing.
@MainActor
final class DropListRemoveRawLengthTests: XCTestCase {
    func testRawSchemaBoundaryIsAtomicForEachList() throws {
        for op in ["vocab_remove", "filler_remove"] {
            let tool = try XCTUnwrap(AppControlMCPServer.tools.first { $0.object?["name"]?.string == "whytap_" + op }?.object)
            let limit = try XCTUnwrap(tool["inputSchema"]?.object?["properties"]?.object?["terms"]?.object?["items"]?.object?["maxLength"]?.int)
            let samples = [String(repeating: " ", count: limit) + "x", String(repeating: "e\u{301}", count: limit / 2 + 1)]
            for sample in samples {
                let suite = "drop-remove-length-" + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let vocab = VocabularyCache(defaults: defaults)
                let filler = FillerTermsStore(defaults: defaults)
                vocab.setTerms(["Keep"])
                _ = filler.add("Keep")
                let lists = AppControlDropLists(vocabulary: { vocab }, fillers: { filler })
                XCTAssertGreaterThan(sample.unicodeScalars.count, limit)
                let response = lists.handle(op, ["terms": .array([.string("Keep"), .string(sample)])])
                XCTAssertFalse(response.ok, op)
                XCTAssertEqual(vocab.terms, ["Keep"], op)
                XCTAssertEqual(filler.terms(), ["Keep"], op)
            }
        }
    }

    /// At the limit, a padded term still matches its saved entry trimmed and
    /// in any letter case.
    func testAPaddedTermAtTheLimitStillRemoves() throws {
        let suite = "drop-remove-length-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vocab = VocabularyCache(defaults: defaults)
        let filler = FillerTermsStore(defaults: defaults)
        vocab.setTerms(["Keep", "Other"])
        _ = filler.add("Keep")
        _ = filler.add("Other")
        let lists = AppControlDropLists(vocabulary: { vocab }, fillers: { filler })
        let padded = String(repeating: " ", count: 46) + "keep"
        XCTAssertEqual(padded.unicodeScalars.count, 50)
        for op in ["vocab_remove", "filler_remove"] {
            XCTAssertTrue(lists.handle(op, ["terms": .array([.string(padded)])]).ok, op)
        }
        XCTAssertEqual(vocab.terms, ["Other"])
        XCTAssertEqual(filler.terms(), ["Other"])
    }
}
