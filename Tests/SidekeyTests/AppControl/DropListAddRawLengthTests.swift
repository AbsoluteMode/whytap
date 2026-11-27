import XCTest
import WhytapCaseKit
@testable import Sidekey

/// The add tools advertise maxLength 50 on each submitted string. JSON Schema
/// counts code points of the raw string, so the limit is checked before
/// trimming, and one over-long term in a batch adds nothing.
@MainActor
final class DropListAddRawLengthTests: XCTestCase {
    private func makeLists() throws -> (AppControlDropLists, VocabularyCache, FillerTermsStore, String) {
        let suite = "drop-add-length-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let vocab = VocabularyCache(defaults: defaults)
        let filler = FillerTermsStore(defaults: defaults)
        vocab.setTerms(["Keep"])
        _ = filler.add("Keep")
        return (AppControlDropLists(vocabulary: { vocab }, fillers: { filler }), vocab, filler, suite)
    }

    func testTheAdvertisedLimitIsTheStoreLimit() throws {
        for op in ["vocab_add", "filler_add"] {
            let tool = try XCTUnwrap(AppControlMCPServer.tools.first { $0.object?["name"]?.string == "whytap_" + op }?.object)
            let limit = try XCTUnwrap(tool["inputSchema"]?.object?["properties"]?.object?["terms"]?.object?["items"]?.object?["maxLength"]?.int)
            XCTAssertEqual(limit, VocabularyCache.maxTermLength, op)
            XCTAssertEqual(limit, FillerTermsStore.maxTermLength, op)
        }
    }

    func testARawTermOverTheLimitAddsNothingFromTheBatch() throws {
        let limit = VocabularyCache.maxTermLength
        let samples = [
            String(repeating: " ", count: limit) + "x",           // trims to 1 character
            String(repeating: "e\u{301}", count: limit / 2 + 1),  // renders as 26 characters
            "  " + String(repeating: "a", count: limit - 1),      // 49 letters plus padding
        ]
        for op in ["vocab_add", "filler_add"] {
            for sample in samples {
                let (lists, vocab, filler, suite) = try makeLists()
                defer { UserDefaults().removePersistentDomain(forName: suite) }
                XCTAssertGreaterThan(sample.unicodeScalars.count, limit)
                // The valid term comes first: the batch is checked before any write.
                let response = lists.handle(op, ["terms": .array([.string("Fresh"), .string(sample)])])
                XCTAssertFalse(response.ok, op)
                XCTAssertEqual(vocab.terms, ["Keep"], op)
                XCTAssertEqual(filler.terms(), ["Keep"], op)
            }
        }
    }

    func testAPaddedTermOfExactlyTheLimitIsAddedTrimmed() throws {
        let padded = String(repeating: " ", count: 45) + "Fresh"
        XCTAssertEqual(padded.unicodeScalars.count, 50)
        let (lists, vocab, filler, suite) = try makeLists()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertTrue(lists.handle("vocab_add", ["terms": .array([.string(padded)])]).ok)
        XCTAssertTrue(lists.handle("filler_add", ["terms": .array([.string(padded)])]).ok)
        XCTAssertEqual(vocab.terms, ["Keep", "Fresh"])
        XCTAssertEqual(filler.terms(), ["Keep", "Fresh"])
    }

    func testFiftyCodePointsOfCombiningMarksAreAccepted() throws {
        let accented = String(repeating: "e\u{301}", count: 25)
        XCTAssertEqual(accented.unicodeScalars.count, 50)
        let (lists, vocab, _, suite) = try makeLists()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertTrue(lists.handle("vocab_add", ["terms": .array([.string(accented)])]).ok)
        XCTAssertEqual(vocab.terms.count, 2)
    }
}
