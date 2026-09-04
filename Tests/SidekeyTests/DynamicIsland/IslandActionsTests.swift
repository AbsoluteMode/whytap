import XCTest
@testable import Sidekey

/// Unit tests for `IslandActions` — the closure bundle the Dynamic
/// Island invokes from hover controls.
///
/// The hover reveal is purely visual and not covered here. These tests
/// pin the lightweight logic:
///
/// 1. The `.noOp` default fires every closure without crashing
///    (lets SwiftUI previews and unit tests construct the view
///    without dragging in `AppDelegate`).
/// 2. Custom action instances route each named slot to the correct
///    closure (no accidental copy-paste between `startDictate` and
///    `startVoiceAgent`).
@MainActor
final class IslandActionsTests: XCTestCase {

    func test_noOp_doesNotCrash() {
        let actions = IslandActions.noOp
        // Each closure exists and can be invoked. No assertions —
        // the test passes if the calls return without trap.
        actions.startDictate()
        actions.startVoiceAgent()
        actions.stopVoiceAgent()
        actions.openTextAgent()
        actions.openClipboard()
        actions.openUsefulLinks()
        actions.openMeetings()
        actions.openSettings()
        actions.openHelp()
        actions.openHotkeys()
        actions.quitApplication()
        actions.stopMeetingRecording()
        _ = actions.currentLanguage()
        actions.setLanguage(nil)
        _ = actions.currentTargetLanguage()
        actions.setTargetLanguage(nil)
        _ = actions.currentDropMode()
        _ = actions.toggleDropMode()
        _ = actions.vocabulary()
    }

    func test_noOpVocabularyDefaultsToSharedCache() {
        XCTAssertTrue(IslandActions.noOp.vocabulary() === VocabularyCache.shared)
    }

    func test_noOpDropModeDefaultsToFast() {
        let actions = IslandActions.noOp

        XCTAssertEqual(actions.currentDropMode(), .fast)
        XCTAssertEqual(actions.toggleDropMode(), .fast)
    }

    func test_eachClosureRoutesIndependently() {
        var fired: [String] = []
        let suiteName = "test.sidekey.island.actions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vocabulary = VocabularyCache(defaults: defaults)
        let actions = IslandActions(
            startDictate:    { fired.append("startDictate") },
            startVoiceAgent: { fired.append("startVoiceAgent") },
            stopVoiceAgent:  { fired.append("stopVoiceAgent") },
            openTextAgent:   { fired.append("openTextAgent") },
            openClipboard:   { fired.append("openClipboard") },
            openUsefulLinks: { fired.append("openUsefulLinks") },
            openMeetings:    { fired.append("openMeetings") },
            openSettings:    { fired.append("openSettings") },
            openHelp:        { fired.append("openHelp") },
            openHotkeys:     { fired.append("openHotkeys") },
            quitApplication: { fired.append("quitApplication") },
            stopMeetingRecording: { fired.append("stopMeetingRecording") },
            currentLanguage: { AppLanguage.find(code: "en") },
            setLanguage: { language in fired.append("setLanguage:\(language?.code ?? "auto")") },
            currentTargetLanguage: { nil },
            setTargetLanguage: { _ in },
            currentDropMode: { .smart },
            toggleDropMode:  {
                fired.append("toggleDropMode")
                return .fast
            },
            vocabulary: { vocabulary }
        )

        actions.startDictate()
        actions.startVoiceAgent()
        actions.stopVoiceAgent()
        actions.openTextAgent()
        actions.openClipboard()
        actions.openUsefulLinks()
        actions.openMeetings()
        actions.openSettings()
        actions.openHelp()
        actions.openHotkeys()
        actions.quitApplication()
        actions.stopMeetingRecording()
        XCTAssertEqual(actions.currentLanguage()?.code, "en")
        actions.setLanguage(AppLanguage.find(code: "ru"))
        XCTAssertEqual(actions.currentDropMode(), .smart)
        XCTAssertEqual(actions.toggleDropMode(), .fast)
        XCTAssertTrue(actions.vocabulary() === vocabulary)

        XCTAssertEqual(
            fired,
            [
                "startDictate",
                "startVoiceAgent",
                "stopVoiceAgent",
                "openTextAgent",
                "openClipboard",
                "openUsefulLinks",
                "openMeetings",
                "openSettings",
                "openHelp",
                "openHotkeys",
                "quitApplication",
                "stopMeetingRecording",
                "setLanguage:ru",
                "toggleDropMode"
            ]
        )
    }

    func test_invokingOneClosureDoesNotFireOthers() {
        var fired: [String] = []
        let actions = IslandActions(
            startDictate:    { fired.append("startDictate") },
            startVoiceAgent: { fired.append("startVoiceAgent") },
            stopVoiceAgent:  { fired.append("stopVoiceAgent") },
            openTextAgent:   { fired.append("openTextAgent") },
            openClipboard:   { fired.append("openClipboard") },
            openUsefulLinks: { fired.append("openUsefulLinks") },
            openMeetings:    { fired.append("openMeetings") },
            openSettings:    { fired.append("openSettings") },
            openHelp:        { fired.append("openHelp") },
            openHotkeys:     { fired.append("openHotkeys") },
            quitApplication: { fired.append("quitApplication") },
            stopMeetingRecording: { fired.append("stopMeetingRecording") },
            currentLanguage: { AppLanguage.find(code: "en") },
            setLanguage: { language in fired.append("setLanguage:\(language?.code ?? "auto")") },
            currentTargetLanguage: { nil },
            setTargetLanguage: { _ in },
            currentDropMode: { .smart },
            toggleDropMode:  {
                fired.append("toggleDropMode")
                return .fast
            }
        )

        actions.openMeetings()

        XCTAssertEqual(fired, ["openMeetings"])
    }
}
