import XCTest
@testable import Sidekey

/// The Vocab list is one saved list; each request takes the part its route
/// accepts. Kept when Drop learning was shelved: it is manual Vocab behaviour.
/// WHY: .project-docs/decisions/2026-11-23-vocabulary-route-budget.md
@MainActor
final class VocabularyBudgetTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "vocab-budget.\(UUID().uuidString)")! }

    // MARK: - Vocab budget per route

    func testElevenLabsRealtimeSendsFiftyShortTermsInListOrder() {
        let list = ["a-very-long-term-over-twenty"] + (1...60).map { "term\($0)" }
        let sent = VocabularyBudget.terms(list, for: .elevenLabsRealtime)
        XCTAssertEqual(sent.count, 50)
        XCTAssertEqual(sent.first, "term1")
        XCTAssertEqual(VocabularyBudget.usage(list, on: .elevenLabsRealtime), .init(used: 50, limit: 50, unit: .terms))
    }

    func testDeepgramStopsAtItsTokenBudgetWithCyrillicCountedConservatively() {
        let list = (1...400).map { "Севастополь\($0)" }
        let sent = VocabularyBudget.terms(list, for: .deepgram)
        let tokens = sent.map(VocabularyBudget.estimatedTokens).reduce(0, +)
        XCTAssertLessThanOrEqual(tokens, VocabularyBudget.deepgramTokenBudget)
        XCTAssertLessThan(sent.count, 400)
        XCTAssertGreaterThan(sent.count, 30)
        let url = try! DeepgramRealtimeURL.make(model: "nova-3", language: "ru", terms: list)
        let keyterms = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.filter { $0.name == "keyterm" }
        XCTAssertEqual(keyterms.map(\.value), sent)
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count, VocabularyBudget.queryByteBudget + 500)
    }

    func testOtherRoutes() {
        let list = (1...2_000).map { "Term\($0)" }
        XCTAssertEqual(VocabularyBudget.terms(list, for: .none), [])
        XCTAssertLessThanOrEqual(
            VocabularyBudget.terms(list, for: .soniox).map(VocabularyBudget.estimatedTokens).reduce(0, +),
            VocabularyBudget.sonioxTokenBudget)
        let prompt = VocabularyBudget.terms(list, for: .openAIPrompt)
        XCTAssertLessThanOrEqual(VocabularyBudget.usage(prompt, on: .openAIPrompt)!.used, VocabularyBudget.openAIPromptTokenBudget)
        XCTAssertEqual(VocabularyBudget.terms(list, for: .elevenLabsBatch).count, 1_000)
        XCTAssertEqual(VocabularyBudget.terms(["Whytap", "whytap", " ", "Line\nbreak"], for: .soniox), ["Whytap"])
    }

    func testAcceptsTellsWhetherANewTermWouldBeSent() {
        let full = (1...50).map { "t\($0)" }
        XCTAssertFalse(VocabularyBudget.accepts("Claude", appendedTo: full, on: .elevenLabsRealtime))
        XCTAssertTrue(VocabularyBudget.accepts("Claude", appendedTo: full, on: .deepgram))
        XCTAssertFalse(VocabularyBudget.accepts("Claude", appendedTo: [], on: .none))
    }

    func testRealtimeTransportFollowsTheAccount() {
        XCTAssertEqual(VocabularyTransport.realtime(for: .deepgram), .deepgram)
        XCTAssertEqual(VocabularyTransport.realtime(for: .elevenLabs), .elevenLabsRealtime)
        XCTAssertEqual(VocabularyTransport.realtime(for: .soniox), .soniox)
        XCTAssertEqual(VocabularyTransport.realtime(for: .server(UUID())), .openAIPrompt)
        XCTAssertEqual(VocabularyTransport.realtime(for: .thisMac), .none)
    }

    // MARK: - The saved list is no longer capped at 50 x 20

    func testVocabularyAcceptsMoreThanFiftyAndLongerTerms() {
        let cache = VocabularyCache(defaults: defaults())
        cache.setTerms((1...50).map { "t\($0)" })
        XCTAssertEqual(cache.add("Twenty-one characters"), .added)
        XCTAssertEqual(cache.terms.count, 51)
        XCTAssertEqual(cache.add(String(repeating: "x", count: 51)), .rejected(.tooLong))
        cache.remove("T1")
        XCTAssertFalse(cache.terms.contains("t1"))
    }

}
