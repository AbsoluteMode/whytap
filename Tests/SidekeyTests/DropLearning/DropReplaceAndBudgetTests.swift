import XCTest
@testable import Sidekey

@MainActor
final class DropReplaceAndBudgetTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "replace.\(UUID().uuidString)")! }

    // MARK: - Replace filter

    func testReplaceIsOnePassWithoutCascades() {
        let rules = [DropReplacement(heard: "клод", wanted: "Claude"), DropReplacement(heard: "Claude", wanted: "Opus")]
        let result = DropReplaceFilter.apply("спроси клод", rules: rules)
        XCTAssertEqual(result.text, "спроси Claude")
        XCTAssertEqual(result.fired, [rules[0]])
    }

    func testWordBoundariesUseLettersNotRegexWordChars() {
        let rules = [DropReplacement(heard: "Сева", wanted: "Seva"), DropReplacement(heard: "си плюс плюс", wanted: "C++"),
                     DropReplacement(heard: "C++", wanted: "cpp")]
        XCTAssertEqual(DropReplaceFilter.apply("Севастополь и сева", rules: rules).text, "Севастополь и Seva")
        XCTAssertEqual(DropReplaceFilter.apply("пишу на си плюс плюс", rules: rules).text, "пишу на C++")
        XCTAssertEqual(DropReplaceFilter.apply("код на C++, ок", rules: rules).text, "код на cpp, ок")
    }

    func testLinksCodeAndAddressesStayLiteral() {
        let rules = [DropReplacement(heard: "docs", wanted: "документы")]
        let text = "docs: https://example.com/docs and `docs` and docs@example.com"
        XCTAssertEqual(DropReplaceFilter.apply(text, rules: rules).text,
                       "документы: https://example.com/docs and `docs` and docs@example.com")
    }

    func testSentenceInitialCapitalIsKeptForALowercaseRule() {
        let rules = [DropReplacement(heard: "ватсап", wanted: "whatsapp")]
        XCTAssertEqual(DropReplaceFilter.apply("Ватсап. Потом ватсап", rules: rules).text, "Whatsapp. Потом whatsapp")
    }

    func testStoreUsesItsOwnKeyAndRoundTrips() {
        let d = defaults()
        let store = DropReplacementStore(defaults: d)
        XCTAssertEqual(store.add(DropReplacement(heard: " клоду ", wanted: "Claude")), .added)
        XCTAssertEqual(store.add(DropReplacement(heard: "Клоду", wanted: "Claudia")), .rejected(.duplicate))
        XCTAssertEqual(store.add(DropReplacement(heard: "x", wanted: "x")), .rejected(.identical))
        XCTAssertEqual(store.replacements(), [DropReplacement(heard: "клоду", wanted: "Claude")])
        XCTAssertNil(d.stringArray(forKey: "sidekey.replace.terms"), "the Filler list keeps its legacy key")
        XCTAssertEqual(ConfigBackupRegistry.entries[DropReplacementStore.key]?.section, .vocabulary)
        store.remove(heard: "КЛОДУ")
        XCTAssertEqual(store.replacements(), [])
    }

    // MARK: - Output order

    func testReplaceRunsBeforeFillerInBothModes() async throws {
        let rules = [DropReplacement(heard: "клоду", wanted: "Claude")]
        let fast = try await DropOutputPolicy(mode: .fast).prepareDetailed(
            rawText: "типа позвони клоду", fillerTerms: ["типа"], replacements: rules
        ) { XCTFail("Fast never cleans up"); return "" }
        XCTAssertEqual(fast.text, "Позвони Claude")
        XCTAssertEqual(fast.firedReplacements, rules)
        XCTAssertEqual(fast.firedFillers, ["типа"])
        let smart = try await DropOutputPolicy(mode: .smart).prepareDetailed(
            rawText: "raw", fillerTerms: [], replacements: rules, preservingMarkdown: { true }
        ) { "Позвони клоду, `клоду` остаётся" }
        XCTAssertEqual(smart.text, "Позвони Claude, `клоду` остаётся")
    }

    func testARuleCannotBringBackACutFiller() async throws {
        let rules = [DropReplacement(heard: "тип", wanted: "типа")]
        let text = try await DropOutputPolicy(mode: .fast).prepare(
            rawText: "это тип отчёт", fillerTerms: ["типа"], replacements: rules
        ) { "" }
        XCTAssertEqual(text, "это отчёт")
    }

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

    // MARK: - Diff

    func testDiffFindsThePastedTextInsideAFieldWithOtherText() throws {
        let diff = try XCTUnwrap(DropEditDiff.diff(
            pasted: "Позвони клоду завтра", field: "Привет! Позвони Claude завтра. Пока"
        ))
        XCTAssertEqual(diff.hunks.map { ($0.removed.map(\.text), $0.inserted.map(\.text)) }.count, 1)
        XCTAssertEqual(diff.hunks.first?.removed.map(\.text), ["клоду"])
        XCTAssertEqual(diff.hunks.first?.inserted.map(\.text), ["Claude"])
    }

    func testCaseOnlyChangesAreNotEdits() throws {
        XCTAssertEqual(try XCTUnwrap(DropEditDiff.diff(pasted: "позвони клоду", field: "Позвони Клоду")).hunks, [])
    }
}
