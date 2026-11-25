import XCTest
@testable import Sidekey

final class DeepgramLanguagePolicyTests: XCTestCase {
    func testNova3AutoCoverageIsExactlyThePublishedTenLanguages() throws {
        let expected = ["en", "es", "fr", "de", "hi", "ru", "pt", "ja", "it", "nl"]
        for model in ["nova-3", "nova-3-general", "nova-3-medical"] {
            XCTAssertEqual(DeepgramLanguagePolicy.automaticLanguageCodes(for: model), expected)
            XCTAssertEqual(try DeepgramLanguagePolicy.queryLanguage(model: model, language: nil), "multi")
        }
        let description = DeepgramLanguagePolicy.automaticLanguageDescription(for: "nova-3")
        XCTAssertTrue(description.contains("10 languages"))
        XCTAssertTrue(description.contains("Russian"))
        XCTAssertFalse(description.contains("Ukrainian"))
    }

    func testNova2AutoHasOnlyEnglishAndSpanish() throws {
        for model in ["nova-2", "nova-2-general"] {
            XCTAssertEqual(DeepgramLanguagePolicy.automaticLanguageCodes(for: model), ["en", "es"])
            XCTAssertEqual(try DeepgramLanguagePolicy.queryLanguage(model: model, language: nil), "multi")
            XCTAssertEqual(try DeepgramLanguagePolicy.queryLanguage(model: model, language: "ru"), "ru")
        }
    }

    func testKnownExplicitLanguagesDoNotBecomeMultilingual() throws {
        for language in ["ru", "en", "uk", "ar", "zh-HK"] {
            XCTAssertEqual(try DeepgramLanguagePolicy.queryLanguage(model: "nova-3", language: language), language)
        }
    }

    func testSonioxOnlyPickerLanguagesAreRejectedByNova3() {
        for language in ["az", "cy", "gl", "ml", "sw"] {
            XCTAssertThrowsError(try DeepgramLanguagePolicy.queryLanguage(model: "nova-3", language: language)) {
                XCTAssertEqual($0 as? DeepgramLanguageConfigurationError, .unsupportedLanguage)
            }
        }
    }

    func testNova2AndMedicalUseTheirOwnExplicitCapabilities() throws {
        XCTAssertThrowsError(try DeepgramLanguagePolicy.queryLanguage(model: "nova-2", language: "ar"))
        XCTAssertThrowsError(try DeepgramLanguagePolicy.queryLanguage(model: "nova-3-medical", language: "ru"))
        XCTAssertEqual(try DeepgramLanguagePolicy.queryLanguage(model: "nova-3-medical", language: "en"), "en")
        XCTAssertTrue(DeepgramLanguagePolicy.automaticLanguageDescription(for: "nova-2").contains("2 languages"))
    }

    /// The texts show on a feature's row in Keys & models, which has no
    /// language menu and no Save button.
    func testErrorTextsPointAtTheModelOrTheInputLanguage() {
        XCTAssertEqual(
            DeepgramLanguageConfigurationError.automaticLanguageUnavailable.localizedDescription,
            "Auto language isn't available for this Deepgram model. Pick nova-3 or choose an input language."
        )
        XCTAssertEqual(
            DeepgramLanguageConfigurationError.unsupportedLanguage.localizedDescription,
            "This Deepgram model doesn't support the current input language. Pick another model or input language."
        )
    }

    func testUnknownModelsRequireExplicitLanguageWithoutSubstitution() throws {
        for model in ["custom-model", "nova-3-pharma", "flux-general-multi"] {
            XCTAssertNil(DeepgramLanguagePolicy.automaticLanguageCodes(for: model))
            XCTAssertThrowsError(try DeepgramLanguagePolicy.queryLanguage(model: model, language: nil)) {
                XCTAssertEqual($0 as? DeepgramLanguageConfigurationError, .automaticLanguageUnavailable)
            }
            XCTAssertEqual(try DeepgramLanguagePolicy.queryLanguage(model: model, language: "ru"), "ru")
        }
    }
}
