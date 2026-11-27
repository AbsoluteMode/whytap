import XCTest
@testable import Sidekey

/// A new user left the input language on Auto and ElevenLabs kept Russian
/// fillers in every dictation; setting the language fixed it. The app now
/// offers the language once, after a few dictations in it.
// WHY: .project-docs/decisions/2026-11-20-input-language-suggestion.md
@MainActor
final class InputLanguageSuggestionTests: XCTestCase {
    private let russian = "Короче, смотри, сейчас надо будет нам с тобой сделать одну вещь."
    private let english = "Okay, look, we need to do one more thing together right now."

    private func defaults() -> UserDefaults {
        let name = "InputLanguageSuggestionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - The user's scenario

    func test_three_auto_dictations_in_one_language_offer_it_once() async {
        let defaults = defaults()
        let rule = InputLanguageSuggestion(defaults: defaults)
        var cards: [LocalNotificationEvent] = []
        let show: (LocalNotificationEvent) async -> Bool = { cards.append($0); return true }
        var first = await rule.offer(transcript: russian, selectedLanguage: nil, deliver: show)
        XCTAssertNil(first)
        first = await rule.offer(transcript: russian, selectedLanguage: nil, deliver: show)
        XCTAssertNil(first)
        let third = await rule.offer(transcript: russian, selectedLanguage: nil, deliver: show)
        XCTAssertEqual(third?.code, "ru")
        XCTAssertEqual(cards.map(\.inputLanguageCode), ["ru"])
        // Ignored: Auto stays and the same language is never offered again,
        // also after a relaunch (a fresh rule over the same defaults).
        for _ in 0..<6 {
            let again = await InputLanguageSuggestion(defaults: defaults)
                .offer(transcript: russian, selectedLanguage: nil, deliver: show)
            XCTAssertNil(again)
        }
        XCTAssertEqual(cards.count, 1)
    }

    /// Found in review: a card that could not be saved (Notify history write
    /// failed) marked the language as offered, so it was never offered at all.
    func test_an_offer_that_could_not_be_shown_is_made_again_by_the_next_take() async {
        let defaults = defaults()
        let rule = InputLanguageSuggestion(defaults: defaults)
        var attempts = 0
        var working = false
        let show: (LocalNotificationEvent) async -> Bool = { _ in attempts += 1; return working }
        for _ in 0..<3 { await rule.offer(transcript: russian, selectedLanguage: nil, deliver: show) }
        XCTAssertEqual(attempts, 1, "the third take tried to show the card")
        XCTAssertNil(defaults.stringArray(forKey: "inputLanguageSuggestion.offeredCodes"))
        // Notify recovers; a relaunch in between changes nothing.
        working = true
        let offered = await InputLanguageSuggestion(defaults: defaults)
            .offer(transcript: russian, selectedLanguage: nil, deliver: show)
        XCTAssertEqual(offered?.code, "ru")
        XCTAssertEqual(defaults.stringArray(forKey: "inputLanguageSuggestion.offeredCodes"), ["ru"])
        let after = await rule.offer(transcript: russian, selectedLanguage: nil, deliver: show)
        XCTAssertNil(after)
        XCTAssertEqual(attempts, 2)
    }

    /// Found in review: a take whose paste failed was counted, and a raw
    /// partial that was pasted after recovery was not.
    func test_only_takes_that_reached_the_user_are_counted() throws {
        let source = try source("Sources/Sidekey/AppDelegate.swift")
        XCTAssertTrue(source.contains("if pasted { noteDeliveredDropForLanguageOffer(rawTranscript) }"))
        let raw = try XCTUnwrap(source.range(of: "rawOutcome.value = outcome"))
        let tail = source[raw.upperBound...].prefix(260)
        XCTAssertTrue(tail.contains("self.noteDeliveredDropForLanguageOffer(raw)"))
        // A refused paste counts only once its Retry actually pasted.
        XCTAssertTrue(source.contains("if pasted { self.noteDeliveredDropForLanguageOffer(pending.rawTranscript) }"))
        XCTAssertEqual(source.components(separatedBy: "noteDeliveredDropForLanguageOffer(").count - 1, 4,
                       "the definition and exactly the three delivered paths")
    }

    func test_a_chosen_input_language_is_never_second_guessed() {
        let rule = InputLanguageSuggestion(defaults: defaults())
        let chosen = AppLanguage.find(code: "en")
        for _ in 0..<5 { XCTAssertNil(rule.record(transcript: russian, selectedLanguage: chosen)) }
        // Those takes did not count towards an Auto streak either.
        XCTAssertNil(rule.record(transcript: russian, selectedLanguage: nil))
    }

    func test_a_bilingual_speaker_is_not_offered_a_language() {
        let rule = InputLanguageSuggestion(defaults: defaults())
        for _ in 0..<4 {
            XCTAssertNil(rule.record(transcript: russian, selectedLanguage: nil))
            XCTAssertNil(rule.record(transcript: russian, selectedLanguage: nil))
            XCTAssertNil(rule.record(transcript: english, selectedLanguage: nil), "another language restarts the count")
        }
    }

    func test_a_second_language_can_be_offered_after_the_first_was_ignored() {
        let rule = InputLanguageSuggestion(defaults: defaults())
        for _ in 0..<3 {
            if let language = rule.record(transcript: russian, selectedLanguage: nil) { rule.markOffered(language) }
        }
        XCTAssertNil(rule.record(transcript: english, selectedLanguage: nil))
        XCTAssertNil(rule.record(transcript: english, selectedLanguage: nil))
        XCTAssertEqual(rule.record(transcript: english, selectedLanguage: nil)?.code, "en")
    }

    // MARK: - Unclear input

    func test_short_empty_and_unclear_takes_change_nothing() {
        let rule = InputLanguageSuggestion(defaults: defaults())
        _ = rule.record(transcript: russian, selectedLanguage: nil)
        _ = rule.record(transcript: russian, selectedLanguage: nil)
        for unclear in ["", "   ", "Ок", "Да, давай", "1234567890 1234567890 1234567890", String(repeating: "🙂", count: 30)] {
            XCTAssertNil(rule.record(transcript: unclear, selectedLanguage: nil), unclear)
        }
        // The streak survived them: the next clear take completes it.
        XCTAssertEqual(rule.record(transcript: russian, selectedLanguage: nil)?.code, "ru")
    }

    func test_a_language_outside_the_menu_is_not_offered() {
        let rule = InputLanguageSuggestion(defaults: defaults(), detect: { _ in "xx" })
        for _ in 0..<5 { XCTAssertNil(rule.record(transcript: russian, selectedLanguage: nil)) }
    }

    func test_the_system_recognizer_names_the_languages_of_the_menu() {
        XCTAssertEqual(InputLanguageSuggestion.detect(russian), "ru")
        XCTAssertEqual(InputLanguageSuggestion.detect(english), "en")
        XCTAssertNil(InputLanguageSuggestion.detect("Привет"))
        XCTAssertNotNil(AppLanguage.all.first { $0.code == "ru" })
    }

    func test_only_the_language_code_and_a_count_are_stored() {
        let name = "InputLanguageSuggestionTests.stored.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let rule = InputLanguageSuggestion(defaults: defaults)
        for _ in 0..<3 {
            if let language = rule.record(transcript: russian, selectedLanguage: nil) { rule.markOffered(language) }
        }
        let stored = defaults.persistentDomain(forName: name) ?? [:]
        XCTAssertEqual(Set(stored.keys), [
            "inputLanguageSuggestion.streakCode", "inputLanguageSuggestion.streakCount",
            "inputLanguageSuggestion.offeredCodes",
        ])
        XCTAssertFalse(String(describing: stored).contains("смотри"), "the dictated text is never kept")
    }

    // MARK: - The card

    func test_the_card_names_the_language_and_carries_the_internal_action() throws {
        let card = InputLanguageSuggestion.notification(for: try XCTUnwrap(AppLanguage.find(code: "ru")))
        XCTAssertEqual(card.title, "Dictating in Russian?")
        XCTAssertTrue(card.body.contains("Auto stays"))
        XCTAssertEqual(card.inputLanguageCode, "ru")
        XCTAssertTrue(card.canActivate)
        XCTAssertNil(card.link)
        XCTAssertEqual(card.id, "builtin.input-language:ru", "one card per language, deduplicated by the hub")
    }

    func test_clicking_the_card_sets_the_language_and_opens_nothing() throws {
        let hub = LocalNotificationHub(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("InputLanguageSuggestionTests-\(UUID().uuidString)"))
        var set: [String] = []
        var opened: [UUID] = []
        var links: [URL] = []
        hub.setInputLanguage = { set.append($0) }
        hub.openMeeting = { opened.append($0) }
        hub.activate(InputLanguageSuggestion.notification(for: try XCTUnwrap(AppLanguage.find(code: "ru"))),
                     openLink: { links.append($0) })
        XCTAssertEqual(set, ["ru"])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(links.isEmpty)
    }

    /// A script's JSON line cannot set the user's language: the field is not
    /// part of what scripts emit.
    func test_scripts_cannot_supply_the_action() throws {
        let source = try source("Sources/Sidekey/Notifications/ScriptNotification.swift")
        let payload = try XCTUnwrap(source.range(of: "struct NotifyPayload"))
        let event = try XCTUnwrap(source.range(of: "struct LocalNotificationEvent"))
        XCTAssertFalse(source[payload.lowerBound..<event.lowerBound].contains("inputLanguage"))
        let make = try XCTUnwrap(source.range(of: "static func make(_ payload: NotifyPayload"))
        XCTAssertFalse(source[make.lowerBound...].contains("inputLanguageCode:"))
    }

    /// An offer clicked later from history must not replace a language the
    /// user chose in the meantime.
    func test_the_app_accepts_the_offer_only_while_the_language_is_auto() throws {
        let source = try source("Sources/Sidekey/AppDelegate.swift")
        let start = try XCTUnwrap(source.range(of: "LocalNotificationHub.shared.setInputLanguage = { code in"))
        XCTAssertTrue(source[start.upperBound...].prefix(300)
            .contains("guard PrivacyPreferences.shared.selectedLanguage == nil"))
    }

    func test_old_notification_history_without_the_field_still_decodes() throws {
        let old = #"{"id":"a","source":"s","sourceName":"S","title":"T","body":"B","timestamp":0,"read":false}"#
        let event = try JSONDecoder().decode(LocalNotificationEvent.self, from: Data(old.utf8))
        XCTAssertNil(event.inputLanguageCode)
        XCTAssertFalse(event.canActivate)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
