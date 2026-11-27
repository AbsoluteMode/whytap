import XCTest
import WhytapCaseKit
@testable import Sidekey

@MainActor
final class AppControlDropListsScopeTests: XCTestCase {
    func testRemovalToolsAreExternalOnly() throws {
        let external = Set(AppControlMCPServer.tools.compactMap { $0.object?["name"]?.string })
        let definition = try JSONSerialization.data(withJSONObject: NativeAgentAppControl.definition())
        let advertised = String(decoding: definition, as: UTF8.self)
        for name in ["whytap_vocab_remove", "whytap_filler_remove"] {
            XCTAssertTrue(external.contains(name))
            XCTAssertNil(NativeAgentAppControl.tool(named: name), name)
            XCTAssertFalse(advertised.contains(name), name)
        }
        for name in ["whytap_vocab_add", "whytap_filler_add"] {
            XCTAssertNotNil(NativeAgentAppControl.tool(named: name), name)
        }
    }
    func testInvalidBatchPreservesBothStoresAtDeclaredLengthLimit() throws {
        let suite = "builder-722-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vocab = VocabularyCache(defaults: defaults)
        let filler = FillerTermsStore(defaults: defaults)
        let lists = AppControlDropLists(vocabulary: { vocab }, fillers: { filler })
        for op in ["vocab_remove", "filler_remove"] {
            let tool = try XCTUnwrap(AppControlMCPServer.tools.first { $0.object?["name"]?.string == "whytap_" + op }?.object)
            let limit = try XCTUnwrap(tool["inputSchema"]?.object?["properties"]?.object?["terms"]?.object?["items"]?.object?["maxLength"]?.int)
            vocab.setTerms(["Keep"]); _ = filler.add("Keep")
            let response = lists.handle(op, ["terms": .array([.string("Keep"), .string(String(repeating: "x", count: limit + 1))])])
            XCTAssertFalse(response.ok, op)
            XCTAssertEqual(vocab.terms, ["Keep"], op)
            XCTAssertEqual(filler.terms(), ["Keep"], op)
        }
    }
}
