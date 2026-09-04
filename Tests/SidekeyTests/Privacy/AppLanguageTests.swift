import XCTest
@testable import Sidekey

/// ROO-262: the STT language menus must advertise only languages that our
/// subscription STT provider (Soniox `stt-rt-v4`) actually recognises, so the
/// onboarding grid and the Island picker stop offering languages that would
/// silently fail. The source of truth is Soniox's published realtime language
/// table (60 languages):
/// https://soniox.com/docs/stt/concepts/supported-languages
final class AppLanguageTests: XCTestCase {
    /// The subset of Soniox's 60 realtime languages that we already model in
    /// `AppLanguage` — the two Soniox languages we never listed (Albanian `sq`,
    /// Basque `eu`) are intentionally NOT added here; ROO-262 only trims the
    /// menu, it does not grow it.
    private static let expectedSupportedCodes: Set<String> = [
        "ar", "be", "bg", "bn", "bs", "ca", "cs", "da", "de", "el",
        "en", "es", "et", "fa", "fi", "fr", "gu", "he", "hi", "hr",
        "hu", "id", "it", "ja", "kn", "ko", "lt", "lv", "mk", "ml",
        "mr", "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl",
        "sr", "sv", "ta", "te", "th", "tl", "tr", "uk", "ur", "vi",
        "zh", "af", "az", "cy", "gl", "kk", "pa", "sw",
    ]

    /// Languages that used to appear (the broader ElevenLabs Scribe set) but
    /// that Soniox realtime does NOT support — they must be gone from the menu.
    private static let expectedRemovedCodes: [String] = [
        "am", "as", "ast", "ceb", "ff", "ga", "ha", "ig", "is", "jv",
        "ka", "kea", "km", "ku", "ky", "lb", "lg", "ln", "lo", "luo",
        "mi", "mn", "mt", "my", "ne", "nso", "ny", "oc", "or", "ps",
        "sd", "sn", "so", "tg", "umb", "uz", "wo", "xh", "yo", "yue", "zu",
    ]

    func testAllContainsExactlySonioxSupportedLanguages() {
        let codes = Set(AppLanguage.all.map(\.code))
        XCTAssertEqual(
            codes, Self.expectedSupportedCodes,
            "AppLanguage.all must list exactly the Soniox-supported languages we model"
        )
    }

    func testAllExcludesNonSonioxLanguages() {
        let codes = Set(AppLanguage.all.map(\.code))
        for removed in Self.expectedRemovedCodes {
            XCTAssertFalse(
                codes.contains(removed),
                "\(removed) is not supported by Soniox realtime and must not appear in the picker"
            )
        }
    }

    func testCommonIsASubsetOfSupported() {
        let all = Set(AppLanguage.all.map(\.code))
        for lang in AppLanguage.common {
            XCTAssertTrue(
                all.contains(lang.code),
                "common language \(lang.code) must be within the supported set"
            )
        }
    }

    func testFindStillResolvesStoredNonSonioxCode() {
        // Migration guarantee: a user who previously selected a now-unlisted
        // language (e.g. Georgian) must not lose that stored selection —
        // `find(code:)` still resolves it even though it is off the menu.
        let georgian = AppLanguage.find(code: "ka")
        XCTAssertNotNil(georgian, "stored long-tail codes must still resolve so selections survive")
        XCTAssertEqual(georgian?.englishName, "Georgian")
    }

    func testFindStillResolvesSupportedCode() {
        XCTAssertEqual(AppLanguage.find(code: "ru")?.englishName, "Russian")
    }
}
