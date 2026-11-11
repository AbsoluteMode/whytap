import XCTest
@testable import Sidekey

@MainActor
final class DropOutputPolicyTests: XCTestCase {
    func testFastNeverCallsCleanupEvenWhenItWouldFail() async throws {
        var calls = 0
        let result = try await DropOutputPolicy(mode: .fast).prepare(
            rawText: "well hello", fillerTerms: ["well"]
        ) {
            calls += 1
            throw OpenRouterLLMError.missingKey
        }
        XCTAssertEqual(result, "Hello")
        XCTAssertEqual(calls, 0)
    }

    func testSmartDeliversCleanupAndAppliesFillerRules() async throws {
        var calls = 0
        let result = try await DropOutputPolicy(mode: .smart).prepare(
            rawText: "uh actually send Friday", fillerTerms: ["uh"]
        ) {
            calls += 1
            return "uh Send it on Friday."
        }
        XCTAssertEqual(result, "Send it on Friday.")
        XCTAssertEqual(calls, 1)
    }

    func testSmartPropagatesFailureWithoutReturningRawText() async {
        for error in [OpenRouterLLMError.notConfigured, .missingKey, .unexpectedStatus(503, "private body")] {
            do {
                _ = try await DropOutputPolicy(mode: .smart).prepare(rawText: "raw dictation", fillerTerms: []) {
                    throw error
                }
                XCTFail("Smart must not silently return Fast output")
            } catch let actual as OpenRouterLLMError {
                XCTAssertEqual(actual, error)
            } catch { XCTFail("Unexpected error type") }
        }
    }

    func testSmartRejectsEmptyCleanupIncludingAfterFillerRemoval() async {
        for output in ["", " \n\t", "uh"] {
            do {
                _ = try await DropOutputPolicy(mode: .smart).prepare(rawText: "real dictation", fillerTerms: ["uh"]) {
                    output
                }
                XCTFail("An empty cleanup must remain retryable")
            } catch let error as OpenRouterLLMError {
                XCTAssertEqual(error, .emptyContent)
            } catch { XCTFail("Unexpected error type") }
        }
    }

    func testModeChangesDuringCleanupCannotDowngradeTheTake() async throws {
        let defaults = UserDefaults(suiteName: "drop.mode.\(UUID().uuidString)")!
        let preferences = UserPreferencesCache(defaults: defaults)
        preferences.setMode(.smart)
        let policy = DropOutputPolicy(mode: preferences.currentMode)
        let result = try await policy.prepare(rawText: "raw", fillerTerms: []) {
            preferences.setMode(.fast)
            await Task.yield()
            return "Processed."
        }
        XCTAssertEqual(result, "Processed.")
        XCTAssertEqual(preferences.currentMode, .fast)
    }

    func testRetryKeepsSmartAfterPreferenceChanges() async throws {
        let defaults = UserDefaults(suiteName: "drop.retry.\(UUID().uuidString)")!
        let preferences = UserPreferencesCache(defaults: defaults)
        preferences.setMode(.smart)
        let retry = DropProcessingRetry(rawText: "raw", targetApp: "Notes", targetPID: 123, mode: preferences.currentMode)
        preferences.setMode(.fast)
        var calls = 0
        let result = try await DropOutputPolicy(mode: retry.mode).prepare(rawText: retry.rawText, fillerTerms: []) {
            calls += 1
            return "Retried."
        }
        XCTAssertEqual(result, "Retried.")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(retry.targetPID, 123)
    }

    func testFastRemovesSpaceTheProviderLeftBeforePunctuation() async throws {
        let result = try await DropOutputPolicy(mode: .fast).prepare(
            rawText: "Объявить их истёкшими ?", fillerTerms: []
        ) {
            XCTFail("Fast must not contact the LLM")
            return "unused"
        }
        XCTAssertEqual(result, "Объявить их истёкшими?")
    }

    func testSmartRemovesSpaceBeforePunctuationButKeepsCodeSpans() async throws {
        let result = try await DropOutputPolicy(mode: .smart).prepare(
            rawText: "raw", fillerTerms: [], preservingMarkdown: { true }
        ) { "Запусти `ls . ` и скажи , что вышло ." }
        XCTAssertEqual(result, "Запусти `ls . ` и скажи, что вышло.")
    }

    /// Smart into a Markdown field: the code span is masked while filters
    /// run, and the mark right after it must still lose its space.
    func testSmartRemovesSpaceRightAfterInlineCodeAndLinksKeepingTheirBytes() async throws {
        let cases: [(String, String)] = [
            ("Run `ls` ?", "Run `ls`?"),
            ("Сначала `git  status . ` , потом `ls -la` .", "Сначала `git  status . `, потом `ls -la`."),
            ("Открой https://example.com/a?b=1 , потом напиши .", "Открой https://example.com/a?b=1 , потом напиши."),
            ("```\nls . ?\n```\nГотово .", "```\nls . ?\n```\nГотово."),
        ]
        for (cleaned, expected) in cases {
            let result = try await DropOutputPolicy(mode: .smart).prepare(
                rawText: "raw", fillerTerms: [], preservingMarkdown: { true }
            ) { cleaned }
            XCTAssertEqual(result, expected, cleaned)
        }
        XCTAssertEqual(DropPunctuationSpacing.apply("Run `ls` ?"), "Run `ls`?")
    }

    /// Attaching a mark to a link changes where it points: every detector
    /// reads "…b=1?" as a different address. The destination must survive
    /// Fast, Smart and Smart-Markdown output.
    func testPunctuationNeverChangesALinkDestination() async throws {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        func destinations(_ text: String) -> [String] {
            detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                .compactMap { $0.url?.absoluteString }
        }
        let links = ["https://example.com/a?b=1", "http://example.com/path", "www.example.com/a?b=1",
                     "[docs](https://example.com/a?b=1)",
                     // Scheme-less and quoted links are links too.
                     "example.com/a?b=1", "example.com", "mail@example.com",
                     "«www.example.com/a?b=1", "\"example.com/a?b=1", "(example.com/a?b=1"]
        for link in links {
            for mark in ["?", ":", "!", ";", ",", ".", "?!", "?»", "?\"", "?)"] {
                let spoken = "Открой \(link) \(mark) потом напиши ."
                let expected = destinations(spoken)
                XCTAssertFalse(expected.isEmpty, link)

                XCTAssertEqual(destinations(DropPunctuationSpacing.apply(spoken)), expected, spoken)
                let fast = try await DropOutputPolicy(mode: .fast).prepare(rawText: spoken, fillerTerms: []) { "" }
                XCTAssertEqual(destinations(fast), expected, spoken)
                for markdown in [false, true] {
                    let smart = try await DropOutputPolicy(mode: .smart).prepare(
                        rawText: "raw", fillerTerms: [], preservingMarkdown: { markdown }
                    ) { spoken }
                    XCTAssertEqual(destinations(smart), expected, spoken)
                    XCTAssertTrue(smart.hasSuffix("напиши."), "ordinary words are still tightened")
                }
            }
        }
    }

    func testPunctuationSpacingLeavesLegitimateTextAlone() {
        let cases: [(String, String)] = [
            ("Привет , мир !", "Привет, мир!"),
            ("Что ?! Серьёзно ...", "Что?! Серьёзно..."),
            ("первая строка .\nвторая ;", "первая строка.\nвторая;"),
            ("он сказал « да » и ушёл", "он сказал « да » и ушёл"),
            ("открой .env и .gitignore", "открой .env и .gitignore"),
            ("улыбка :) и ...потом", "улыбка :) и ...потом"),
            ("Vraiment\u{00A0}? Oui\u{202F}!", "Vraiment\u{00A0}? Oui\u{202F}!"),
            ("- пункт\n- . точка", "- пункт\n- . точка"),
            ("", ""),
            ("  ?", "  ?"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DropPunctuationSpacing.apply(input), expected, input)
        }
    }

    func testFastPreservesSpeechWhenFillerRulesWouldRemoveEverything() async throws {
        let result = try await DropOutputPolicy(mode: .fast).prepare(rawText: "uh", fillerTerms: ["uh"]) {
            XCTFail("Fast must not contact the LLM")
            return "unused"
        }
        XCTAssertEqual(result, "uh")
    }

    func testConfigurationErrorsOpenModelsButTransientFailuresRemainRetryable() {
        XCTAssertTrue(DropOutputPolicy.requiresConfiguration(for: OpenRouterLLMError.missingKey))
        XCTAssertTrue(DropOutputPolicy.requiresConfiguration(for: OpenRouterLLMError.unexpectedStatus(404, nil)))
        XCTAssertFalse(DropOutputPolicy.requiresConfiguration(for: OpenRouterLLMError.unexpectedStatus(503, nil)))
        XCTAssertFalse(DropOutputPolicy.requiresConfiguration(for: OpenRouterLLMError.emptyContent))
    }

    func testFailureCopyExcludesProviderBodiesAndEndpointValues() {
        XCTAssertEqual(DropOutputPolicy.failureMessage(for: OpenRouterLLMError.unexpectedStatus(401, "private response")), "Smart failed (401)")
        XCTAssertEqual(DropOutputPolicy.failureMessage(for: OpenRouterLLMError.invalidBaseURL("private endpoint")), "Set up Smart in API & Models")
    }
}
