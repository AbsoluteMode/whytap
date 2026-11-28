import XCTest
import WhytapCaseKit
@testable import Sidekey

/// `whytap_vocab_remove` / `whytap_filler_remove` for Claude Code and Codex:
/// only the named entries leave, matched as the editors match them.
/// WHY: .project-docs/decisions/2026-11-27-drop-list-removal-mcp.md
@MainActor
final class AppControlDropListsRemovalTests: XCTestCase {
    private var vocabulary: VocabularyCache!
    private var fillers: FillerTermsStore!
    private var lists: AppControlDropLists!

    override func setUp() async throws {
        let suite = "drop-list-removal-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        vocabulary = VocabularyCache(defaults: defaults)
        fillers = FillerTermsStore(defaults: defaults)
        let vocabulary = vocabulary!, fillers = fillers!
        lists = AppControlDropLists(vocabulary: { vocabulary }, fillers: { fillers })
    }

    private func remove(_ operation: String, _ terms: [AppControlValue]) -> AppControlResponse {
        lists.handle(operation, ["terms": .array(terms)])
    }

    private func rows(_ response: AppControlResponse) -> [[String: String]] {
        (response.data.object?["terms"]?.array ?? []).map { row in
            (row.object ?? [:]).compactMapValues(\.string)
        }
    }

    /// A line break that only trimming would hide is still not one line:
    /// the whole batch is refused and both lists stay exactly as they were,
    /// for removal and addition alike.
    func testATermEndingInALineBreakIsRefusedAndNothingChanges() {
        for operation in ["vocab_remove", "filler_remove", "vocab_add", "filler_add"] {
            vocabulary.setTerms(["Whytap", "Soniox"])
            for term in fillers.terms() { fillers.remove(term) }
            _ = fillers.add("um"); _ = fillers.add("uh")
            let second: AppControlValue = operation.hasSuffix("_add") ? .string("Deepgram\n") : .string(operation.hasPrefix("vocab") ? "Soniox\n" : "uh\n")
            let first: AppControlValue = operation.hasSuffix("_add") ? .string("Groq") : .string(operation.hasPrefix("vocab") ? "Whytap" : "um")
            let response = remove(operation, [first, second])
            XCTAssertFalse(response.ok, operation)
            XCTAssertEqual(response.data.object?["code"], .string("invalid_term"), operation)
            XCTAssertEqual(vocabulary.terms, ["Whytap", "Soniox"], operation)
            XCTAssertEqual(fillers.terms(), ["um", "uh"], operation)
        }
    }

    func testRemovesNamedVocabEntriesInAnyCaseAndReportsTheSavedSpelling() {
        vocabulary.setTerms(["Whytap", "Soniox", "Deepgram"])
        let response = remove("vocab_remove", [.string("  whytap "), .string("SONIOX")])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(rows(response), [["term": "Whytap", "result": "removed"], ["term": "Soniox", "result": "removed"]])
        XCTAssertEqual(vocabulary.terms, ["Deepgram"])
    }

    func testAMissingEntryChangesNothingAndIsNotAnError() {
        fillers.add("um")
        let response = remove("filler_remove", [.string("like"), .string("um")])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(rows(response), [["term": "like", "result": "missing"], ["term": "um", "result": "removed"]])
        XCTAssertEqual(fillers.terms(), [])
        // Retrying is safe.
        XCTAssertEqual(rows(remove("filler_remove", [.string("um")])), [["term": "um", "result": "missing"]])
    }

    func testOneInvalidTermRemovesNothing() {
        vocabulary.setTerms(["Whytap"])
        for bad: AppControlValue in [.string("   "), .string("two\nlines"), .int(3)] {
            let response = remove("vocab_remove", [.string("Whytap"), bad])
            XCTAssertFalse(response.ok, "\(bad)")
        }
        XCTAssertEqual(vocabulary.terms, ["Whytap"])
    }

    func testATermNamedTwiceIsOneRow() {
        vocabulary.setTerms(["Whytap"])
        let response = remove("vocab_remove", [.string("Whytap"), .string("WHYTAP")])
        XCTAssertEqual(rows(response), [["term": "Whytap", "result": "removed"]])
    }

    func testArgumentsAreCheckedLikeAdding() {
        XCTAssertEqual(lists.handle("vocab_remove", [:]).data.object?["code"], .string("invalid_arguments"))
        XCTAssertEqual(remove("vocab_remove", []).data.object?["code"], .string("invalid_arguments"))
        XCTAssertEqual(remove("vocab_remove", Array(repeating: .string("x"), count: 21)).data.object?["code"],
                       .string("invalid_arguments"))
        XCTAssertEqual(lists.handle("filler_remove", ["terms": .array([.string("um")]), "all": .bool(true)])
            .data.object?["code"], .string("invalid_arguments"), "no remove-all")
    }

    func testRemovalNeverTouchesTheOtherList() {
        vocabulary.setTerms(["um"])
        fillers.add("um")
        _ = remove("filler_remove", [.string("um")])
        XCTAssertEqual(vocabulary.terms, ["um"])
        XCTAssertEqual(fillers.terms(), [])
    }

    // MARK: Length limit, restored spacing, repeats (build-queue probe 722)

    func testFiftyCharactersIsTheLimitForBothListsAndALongerTermRemovesNothing() {
        let fifty = String(repeating: "a", count: 50)
        for op in ["vocab_remove", "filler_remove"] {
            vocabulary.setTerms(["Keep", fifty])
            fillers.remove("Keep"); fillers.remove(fifty)
            _ = fillers.add("Keep"); _ = fillers.add(fifty)
            let atLimit = remove(op, [.string(fifty)])
            XCTAssertTrue(atLimit.ok, op)
            XCTAssertEqual(rows(atLimit), [["term": fifty, "result": "removed"]], op)
            let over = remove(op, [.string("Keep"), .string(fifty + "a")])
            XCTAssertFalse(over.ok, op)
            XCTAssertEqual(over.data.object?["code"], .string("invalid_term"), op)
            XCTAssertEqual(op == "vocab_remove" ? vocabulary.terms : fillers.terms(), ["Keep"], op)
            let overFirst = remove(op, [.string(fifty + "a"), .string("Keep")])
            XCTAssertFalse(overFirst.ok, op)
            XCTAssertEqual(op == "vocab_remove" ? vocabulary.terms : fillers.terms(), ["Keep"], op)
        }
    }

    func testRestoredEntriesWithSpacesAreFoundAndOnlyTheyLeave() {
        vocabulary.setTerms(["  Fixture  ", "Other", " fixture"])
        let response = remove("vocab_remove", [.string("FIXTURE"), .string("fixture "), .string("absent")])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(rows(response), [["term": "Fixture", "result": "removed"], ["term": "absent", "result": "missing"]])
        XCTAssertEqual(vocabulary.terms, ["Other"])
        // Retrying the same request is safe: now missing, nothing changes.
        let again = remove("vocab_remove", [.string("fixture")])
        XCTAssertEqual(rows(again), [["term": "fixture", "result": "missing"]])
        XCTAssertEqual(vocabulary.terms, ["Other"])
    }

    func testRemovalAfterARestoreFindsTheWordAgain() throws {
        for op in ["vocab_remove", "filler_remove"] {
            let restore = { (list: [String]) in
                if op == "vocab_remove" { self.vocabulary.setTerms(list) } else {
                    for entry in self.fillers.terms() { self.fillers.remove(entry) }
                    for entry in list { _ = self.fillers.add(entry) }
                }
            }
            restore(["Fixture", "Other"])
            XCTAssertEqual(rows(remove(op, [.string("fixture")])), [["term": "Fixture", "result": "removed"]], op)
            restore(["Fixture", "Other"])
            XCTAssertEqual(rows(remove(op, [.string("fixture")])), [["term": "Fixture", "result": "removed"]], op)
            XCTAssertEqual(op == "vocab_remove" ? vocabulary.terms : fillers.terms(), ["Other"], op)
        }
    }
}
