import XCTest
@testable import Sidekey

@MainActor
final class PrivacyPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.sidekey.privacy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - screenshotProtectionEnabled persistence

    func test_screenshot_protection_defaults_disabled() {
        // Off by default: the island stays visible in screen shares until the
        // user opts into protection from Settings -> Other.
        let prefs = PrivacyPreferences(defaults: defaults)
        XCTAssertFalse(prefs.screenshotProtectionEnabled)
    }

    func test_screenshot_protection_persists_true() {
        let prefs = PrivacyPreferences(defaults: defaults)
        prefs.screenshotProtectionEnabled = true

        // Recreate the wrapper to ensure the value came from UserDefaults,
        // not from in-memory state.
        let reloaded = PrivacyPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.screenshotProtectionEnabled)
    }

    func test_screenshot_protection_persists_false() {
        let prefs = PrivacyPreferences(defaults: defaults)
        prefs.screenshotProtectionEnabled = true
        prefs.screenshotProtectionEnabled = false

        let reloaded = PrivacyPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.screenshotProtectionEnabled)
    }

    // MARK: - selectedLanguage persistence

    func test_selected_language_default_nil() {
        let prefs = PrivacyPreferences(defaults: defaults)
        XCTAssertNil(prefs.selectedLanguage)
    }

    func test_selected_language_persists_known_code() {
        let prefs = PrivacyPreferences(defaults: defaults)
        prefs.selectedLanguage = AppLanguage.find(code: "en")

        let reloaded = PrivacyPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.selectedLanguage?.code, "en")
        XCTAssertEqual(reloaded.selectedLanguage?.englishName, "English")
    }

    func test_selected_language_persists_non_ascii_language() {
        let prefs = PrivacyPreferences(defaults: defaults)
        prefs.selectedLanguage = AppLanguage.find(code: "ru")

        let reloaded = PrivacyPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.selectedLanguage?.code, "ru")
        XCTAssertEqual(reloaded.selectedLanguage?.englishName, "Russian")
    }

    func test_selected_language_assigning_nil_clears_persisted_value() {
        let prefs = PrivacyPreferences(defaults: defaults)
        prefs.selectedLanguage = AppLanguage.find(code: "ru")
        prefs.selectedLanguage = nil

        let reloaded = PrivacyPreferences(defaults: defaults)
        XCTAssertNil(reloaded.selectedLanguage)
    }

    func test_selected_language_unknown_code_stored_returns_nil() {
        // Simulate a stale/unknown code landing in UserDefaults (future-proofing).
        defaults.set("xx", forKey: "sidekey.preferences.selectedLanguage")

        let prefs = PrivacyPreferences(defaults: defaults)
        XCTAssertNil(prefs.selectedLanguage)
    }

    // MARK: - targetLanguage (output language) persistence

    func test_target_language_default_nil() {
        let prefs = PrivacyPreferences(defaults: defaults)
        XCTAssertNil(prefs.targetLanguage)
    }

    func test_target_language_persists_known_code() {
        let prefs = PrivacyPreferences(defaults: defaults)
        prefs.targetLanguage = AppLanguage.find(code: "en")

        let reloaded = PrivacyPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.targetLanguage?.code, "en")
    }

    func test_target_language_assigning_nil_clears_persisted_value() {
        let prefs = PrivacyPreferences(defaults: defaults)
        prefs.targetLanguage = AppLanguage.find(code: "ru")
        prefs.targetLanguage = nil

        let reloaded = PrivacyPreferences(defaults: defaults)
        XCTAssertNil(reloaded.targetLanguage)
    }

    // MARK: - outputLanguage compat shim

    func test_output_language_compat_nil_when_no_selection() {
        let prefs = PrivacyPreferences(defaults: defaults)
        XCTAssertNil(prefs.outputLanguage)
    }

    func test_output_language_compat_returns_english_name() {
        let prefs = PrivacyPreferences(defaults: defaults)
        prefs.selectedLanguage = AppLanguage.find(code: "ru")
        XCTAssertEqual(prefs.outputLanguage, "Russian")
    }
}
