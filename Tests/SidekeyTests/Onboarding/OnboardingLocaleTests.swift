import XCTest
@testable import Sidekey

@MainActor
final class OnboardingLocaleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.onboarding.locale.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_defaultLanguageIsEnglish_whenNothingPersisted() {
        let locale = OnboardingLocale(defaults: defaults)
        XCTAssertEqual(locale.language, .en, "default UI language must always be English")
    }

    func test_settingLanguagePersistsToDefaults() {
        let locale = OnboardingLocale(defaults: defaults)
        locale.language = .ru
        XCTAssertEqual(
            defaults.string(forKey: OnboardingLocale.defaultsKey),
            OnboardingUILanguage.ru.rawValue,
            "selecting Russian must persist the raw code under the onboarding UI-language key"
        )
    }

    func test_persistedRussianResumesOnReload() {
        defaults.set(OnboardingUILanguage.ru.rawValue, forKey: OnboardingLocale.defaultsKey)
        let locale = OnboardingLocale(defaults: defaults)
        XCTAssertEqual(locale.language, .ru, "a previously chosen Russian must be restored on next launch")
    }

    func test_unknownPersistedValueFallsBackToEnglish() {
        defaults.set("zz", forKey: OnboardingLocale.defaultsKey)
        let locale = OnboardingLocale(defaults: defaults)
        XCTAssertEqual(locale.language, .en, "an unrecognised persisted code falls back to English, never crashes")
    }

    func test_switchingBackToEnglishPersists() {
        let locale = OnboardingLocale(defaults: defaults)
        locale.language = .ru
        locale.language = .en
        XCTAssertEqual(
            defaults.string(forKey: OnboardingLocale.defaultsKey),
            OnboardingUILanguage.en.rawValue,
            "switching back to English must persist English, not leave the stale Russian value"
        )
        let reloaded = OnboardingLocale(defaults: defaults)
        XCTAssertEqual(reloaded.language, .en)
    }
}
