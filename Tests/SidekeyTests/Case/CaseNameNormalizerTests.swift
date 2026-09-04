import XCTest
@testable import Sidekey

final class CaseNameNormalizerTests: XCTestCase {
    func test_normalizes_spaces_hyphens_and_case_to_upper_snake() throws {
        XCTAssertEqual(try CaseNameNormalizer.normalizedName("open ai api key"), "OPEN_AI_API_KEY")
        XCTAssertEqual(try CaseNameNormalizer.normalizedName("OpenAI API Key"), "OPENAI_API_KEY")
        XCTAssertEqual(try CaseNameNormalizer.normalizedName("github-token"), "GITHUB_TOKEN")
        XCTAssertEqual(try CaseNameNormalizer.normalizedName("  stripe   prod "), "STRIPE_PROD")
    }

    func test_rejects_empty_or_symbol_only_names() {
        XCTAssertThrowsError(try CaseNameNormalizer.normalizedName(""))
        XCTAssertThrowsError(try CaseNameNormalizer.normalizedName(" - _ "))
    }

    func test_rejects_non_ascii_names_for_env_predictability() {
        XCTAssertThrowsError(try CaseNameNormalizer.normalizedName("опен аи ключ"))
        XCTAssertThrowsError(try CaseNameNormalizer.normalizedName("clé api"))
    }

    func test_enforces_raw_and_normalized_length_limits() {
        XCTAssertThrowsError(try CaseNameNormalizer.normalizedName(String(repeating: "a", count: 81)))
        XCTAssertThrowsError(try CaseNameNormalizer.normalizedName(String(repeating: "a", count: 65)))
        XCTAssertEqual(try CaseNameNormalizer.normalizedName(String(repeating: "a", count: 64)), String(repeating: "A", count: 64))
    }

    func test_duplicate_detection_uses_normalized_names() throws {
        let existing = ["OPENAI_API_KEY", "STRIPE_PROD"]

        XCTAssertTrue(try CaseNameNormalizer.isDuplicate("openai api key", existingNames: existing))
        XCTAssertTrue(try CaseNameNormalizer.isDuplicate("stripe-prod", existingNames: existing))
        XCTAssertFalse(try CaseNameNormalizer.isDuplicate("github token", existingNames: existing))
    }
}
