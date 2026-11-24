import XCTest
@testable import Sidekey

/// The feature catalog judged from a newcomer's three jobs (set up dictation,
/// turn on meeting notes, find out what the Agent does) and from the edges:
/// a fresh install without keys, a downloaded local model, permissions not
/// given, an Intel Mac, a rebound key and a feature that is off.
final class FeatureCatalogTests: XCTestCase {
    /// A Mac where everything Drop needs is in place, on the local model.
    private func readyDrop() -> FeatureSetupSnapshot {
        FeatureSetupSnapshot(
            models: [.dropFast: .ok], selectableModels: [.dropFast],
            onDevice: .available(.ready), keyboardReady: true, microphoneGranted: true,
            screenRecordingGranted: true, dropShortcut: .ready)
    }

    /// First launch on Apple Silicon: no key, no model, nothing allowed.
    private func freshInstall() -> FeatureSetupSnapshot {
        FeatureSetupSnapshot(onDevice: .available(.notDownloaded), dropShortcut: .accessibilityRequired)
    }

    private func actions(_ status: FeatureStatus) -> [FeatureSetupAction?] { status.missing.map(\.action) }

    // MARK: - Fresh install

    func testFreshInstallDropNeedsSetupAndOffersTheFreeModelFirst() {
        let status = FeatureCatalog.status(for: .drop, snapshot: freshInstall())
        guard case .needsSetup(let missing) = status else { return XCTFail("Drop is always on: \(status)") }
        XCTAssertEqual(missing.map(\.requirement.id), ["model.dropFast", "permission.keyboard", "permission.microphone"])
        XCTAssertEqual(missing.first?.action, .downloadOnDeviceModel(.dropFast))
        XCTAssertEqual(status.reason, "No speech-to-text model +2")
        XCTAssertEqual(FeatureCatalog.consequence(of: missing[0], for: .drop),
                       "Drop can’t type what you say until it has a speech-to-text model.")
    }

    func testFreshInstallShowsOnlyDropAsNeedingSetup() {
        let snapshot = freshInstall()
        let statuses = AppFeature.allCases.map { FeatureCatalog.status(for: $0, snapshot: snapshot) }
        XCTAssertEqual(statuses.map(\.word),
                       ["Needs setup", "Off", "Off", "Off", "Not set up", "Not set up"])
        XCTAssertEqual(FeatureCatalog.summary(statuses), "0 ready · 1 needs setup")
    }

    func testShortcutWaitingForKeyboardControlIsNotCountedTwice() {
        let checks = FeatureCatalog.checks(for: .drop, snapshot: freshInstall())
        let shortcut = checks.first { $0.requirement.kind == .dropShortcut }
        XCTAssertEqual(shortcut?.state, .waiting(reason: "Waits for Keyboard control"))
        XCTAssertEqual(shortcut?.isBlocking, false)
    }

    // MARK: - Local model

    func testDownloadedLocalModelNotYetChosenOffersToUseIt() {
        var snapshot = readyDrop()
        snapshot.models = [:]
        let status = FeatureCatalog.status(for: .drop, snapshot: snapshot)
        XCTAssertEqual(actions(status), [.useOnDeviceModel(.dropFast)])
    }

    func testLocalModelAndPermissionsMakeDropReady() {
        XCTAssertEqual(FeatureCatalog.status(for: .drop, snapshot: readyDrop()), .ready(note: nil))
    }

    func testRunningDownloadOffersNoSecondAction() {
        var snapshot = freshInstall()
        snapshot.onDevice = .available(.downloading(0.4))
        let model = FeatureCatalog.checks(for: .drop, snapshot: snapshot)[0]
        XCTAssertEqual(model.state, .unmet(reason: "No speech-to-text model", action: nil))
    }

    func testFailedDownloadOffersTheDownloadAgain() {
        var snapshot = freshInstall()
        snapshot.onDevice = .available(.failed)
        XCTAssertEqual(FeatureCatalog.checks(for: .drop, snapshot: snapshot)[0].action, .downloadOnDeviceModel(.dropFast))
    }

    func testLocalModelIsNeverOfferedForATextModel() {
        var snapshot = readyDrop()
        snapshot.dropMode = .smart
        snapshot.models = [.dropSmart: .ok]
        let status = FeatureCatalog.status(for: .drop, snapshot: snapshot)
        XCTAssertEqual(status.missing.map(\.requirement.id), ["model.dropSmartCleanup"])
        XCTAssertEqual(actions(status), [.addKey(.dropSmartCleanup)])
    }

    // MARK: - Intel

    func testIntelMacIsSentToAKeyNotToADownload() {
        var snapshot = freshInstall()
        snapshot.onDevice = .unsupported
        XCTAssertEqual(FeatureCatalog.checks(for: .drop, snapshot: snapshot)[0].action, .addKey(.dropFast))
        snapshot.selectableModels = [.dropFast]
        XCTAssertEqual(FeatureCatalog.checks(for: .drop, snapshot: snapshot)[0].action, .chooseModel(.dropFast))
    }

    // MARK: - Permissions

    func testMissingPermissionsEachNameTheirOwnStep() {
        var snapshot = readyDrop()
        snapshot.keyboardReady = false
        snapshot.microphoneGranted = false
        snapshot.dropShortcut = .accessibilityRequired
        let status = FeatureCatalog.status(for: .drop, snapshot: snapshot)
        XCTAssertEqual(actions(status), [.allow(.keyboard), .allow(.microphone)])
        XCTAssertEqual(status.reason, "Allow Keyboard control +1")
    }

    func testGrantMadeAfterLaunchAsksForARestart() {
        var snapshot = readyDrop()
        snapshot.keyboardNeedsRestart = true
        let status = FeatureCatalog.status(for: .drop, snapshot: snapshot)
        XCTAssertEqual(actions(status), [.restartWhytap])
        XCTAssertEqual(FeatureCatalog.consequence(of: status.missing[0], for: .drop),
                       "Keyboard control is allowed. Restart Whytap to make it work.")
    }

    func testReadyNeedsTheShortcutToBeHeard() {
        var snapshot = readyDrop()
        snapshot.dropShortcut = .inputMonitoringRequired
        var status = FeatureCatalog.status(for: .drop, snapshot: snapshot)
        XCTAssertEqual(actions(status), [.openInputMonitoring])
        XCTAssertEqual(status.reason, "Allow Input Monitoring")

        snapshot.dropShortcut = .shortcutInUse
        status = FeatureCatalog.status(for: .drop, snapshot: snapshot)
        XCTAssertEqual(status.reason, "Shortcut is in use")
        XCTAssertEqual(actions(status), [.retryShortcut])

        // Keyboard control reads as allowed, yet the tap was refused (a stale
        // entry after an update): still not Ready.
        snapshot.dropShortcut = .accessibilityRequired
        XCTAssertEqual(FeatureCatalog.status(for: .drop, snapshot: snapshot).reason, "Shortcut isn't heard")
    }

    func testSystemAudioIsNeverShownAsAllowedOrMissing() {
        var snapshot = readyDrop()
        snapshot.meetingsOn = true
        snapshot.models[.meetings] = .ok
        snapshot.models[.meetingNotes] = .ok
        let audio = FeatureCatalog.checks(for: .meetings, snapshot: snapshot).last
        XCTAssertEqual(audio?.state, .askedLater(note: "macOS asks at the first recording"))
        XCTAssertEqual(FeatureCatalog.status(for: .meetings, snapshot: snapshot), .ready(note: nil))
    }

    // MARK: - Drop modes

    func testSmartModeRequiresItsOwnSpeechModelAndATextModel() {
        var snapshot = readyDrop()
        snapshot.dropMode = .smart
        let checks = FeatureCatalog.checks(for: .drop, snapshot: snapshot)
        XCTAssertEqual(checks.prefix(3).map(\.requirement.id),
                       ["model.dropSmart", "model.dropSmartCleanup", "model.dropFast"])
        XCTAssertTrue(checks[2].requirement.optional, "Fast's model is not needed while Smart is on")
        let status = FeatureCatalog.status(for: .drop, snapshot: snapshot)
        XCTAssertEqual(status.missing.map(\.requirement.id), ["model.dropSmart", "model.dropSmartCleanup"])
        XCTAssertEqual(FeatureCatalog.consequence(of: status.missing[1], for: .drop),
                       "Smart mode can’t tidy your text until it has a text model. Switch to Fast to dictate now.")
    }

    func testBrokenKeyOnASetModelIsNotReady() {
        var snapshot = readyDrop()
        snapshot.models[.dropFast] = .keyProblem
        let status = FeatureCatalog.status(for: .drop, snapshot: snapshot)
        XCTAssertEqual(status.reason, "Its provider key isn't working")
        XCTAssertEqual(actions(status), [.chooseModel(.dropFast)])
        XCTAssertEqual(FeatureCatalog.consequence(of: status.missing[0], for: .drop),
                       "Drop can’t type what you say: its provider key isn't working.")
    }

    func testModelStatesThatStillRunCountAsSet() {
        for running in [ModelRowStatus.notVerified, .deprecatedAlias(of: "x"), .expiring(Date())] {
            var snapshot = readyDrop()
            snapshot.models[.dropFast] = running
            XCTAssertTrue(FeatureCatalog.status(for: .drop, snapshot: snapshot).isReady, "\(running)")
        }
    }

    // MARK: - Switches

    func testAFeatureThatIsOffNeverNeedsSetup() {
        let snapshot = freshInstall()
        for feature in [AppFeature.agent, .meetings, .googleSearch] {
            XCTAssertEqual(FeatureCatalog.status(for: feature, snapshot: snapshot), .off, feature.rawValue)
        }
    }

    func testTurningMeetingNotesOnWithoutModelsNeedsSetup() {
        var snapshot = readyDrop()
        snapshot.meetingsOn = true
        let status = FeatureCatalog.status(for: .meetings, snapshot: snapshot)
        guard case .needsSetup(let missing) = status else { return XCTFail("\(status)") }
        XCTAssertEqual(missing.map(\.requirement.id), ["model.meetings", "model.meetingNotes"])
        // The local model can write down a call; the note needs a text model.
        XCTAssertEqual(missing.map(\.action), [.useOnDeviceModel(.meetings), .addKey(.meetingNotes)])
    }

    func testAgentOnWithoutAModelNeedsSetup() {
        var snapshot = readyDrop()
        snapshot.agentOn = true
        let status = FeatureCatalog.status(for: .agent, snapshot: snapshot)
        XCTAssertEqual(status.word, "Needs setup")
        XCTAssertEqual(status.reason, "No text model")
        snapshot.models[.agent] = .ok
        XCTAssertEqual(FeatureCatalog.status(for: .agent, snapshot: snapshot), .ready(note: nil),
                       "Voice, microphone and screen are optional for the Agent")
    }

    func testGoogleSearchWithoutAVoiceModelIsReadyForTypingOnly() {
        var snapshot = readyDrop()
        snapshot.googleOn = true
        XCTAssertEqual(FeatureCatalog.status(for: .googleSearch, snapshot: snapshot), .ready(note: "typing only"))
        snapshot.models[.voiceSearch] = .ok
        XCTAssertEqual(FeatureCatalog.status(for: .googleSearch, snapshot: snapshot), .ready(note: nil))
    }

    func testOnlyFeaturesWithARealSwitchCanBeOff() {
        XCTAssertEqual(FeatureCatalog.all.filter(\.hasSwitch).map(\.feature), [.agent, .meetings, .googleSearch])
        let nothing = FeatureSetupSnapshot()
        for feature in [AppFeature.drop, .translateSubtitles, .screenshots] {
            XCTAssertNotEqual(FeatureCatalog.status(for: feature, snapshot: nothing), .off, feature.rawValue)
        }
    }

    func testIslandToolsAreQuietUntilSetUp() {
        var snapshot = FeatureSetupSnapshot()
        XCTAssertEqual(FeatureCatalog.status(for: .screenshots, snapshot: snapshot).word, "Not set up")
        XCTAssertEqual(FeatureCatalog.status(for: .screenshots, snapshot: snapshot).reason, "Allow Screen Recording")
        snapshot.screenRecordingGranted = true
        XCTAssertEqual(FeatureCatalog.status(for: .screenshots, snapshot: snapshot), .ready(note: nil))
        // Translate works without the Subtitles key; that part is optional.
        snapshot.models[.translation] = .ok
        XCTAssertEqual(FeatureCatalog.status(for: .translateSubtitles, snapshot: snapshot), .ready(note: nil))
    }

    func testSummaryCountsOnlyReadyAndNeedsSetup() {
        XCTAssertEqual(FeatureCatalog.summary([.ready(note: nil), .ready(note: "typing only"), .off, .notSetUp([])]),
                       "2 ready")
        let check = FeatureCatalog.checks(for: .drop, snapshot: freshInstall())[0]
        XCTAssertEqual(FeatureCatalog.summary([.needsSetup([check]), .needsSetup([check]), .off]),
                       "0 ready · 2 need setup")
    }

    // MARK: - Hotkeys

    @MainActor
    func testHotkeysFollowAReboundKey() {
        var configuration = HotkeyConfiguration.defaults
        XCTAssertEqual(FeatureHotkey.dropVoice.shortcut(in: configuration), .holdSpace)
        XCTAssertEqual(FeatureHotkey.dropVoice.gesture(in: configuration), .hold)

        configuration.setDropShortcut(.modifier(.rightOption))
        configuration.dropVoiceGesture = .tap
        XCTAssertEqual(FeatureHotkey.dropVoice.shortcut(in: configuration), .modifier(.rightOption))
        XCTAssertEqual(FeatureHotkey.dropVoice.gesture(in: configuration), .tap)
        XCTAssertNil(FeatureHotkey.tool(.translate).shortcut(in: configuration), "A tool without a shortcut shows none")
    }

    @MainActor
    func testSpaceStaysHoldEvenWithAStaleToggleStored() {
        var configuration = HotkeyConfiguration.defaults
        configuration.dropVoiceGesture = .tap
        XCTAssertEqual(FeatureHotkey.dropVoice.gesture(in: configuration), .hold)
    }

    func testEveryCoreShortcutBelongsToAFeature() {
        let listed = Set(FeatureCatalog.all.flatMap(\.hotkeys))
        for hotkey in [FeatureHotkey.dropVoice, .agentText, .agentVoice, .agentClose,
                       .googleText, .googleVoice, .meetingRecord] {
            XCTAssertTrue(listed.contains(hotkey), "\(hotkey)")
        }
        XCTAssertEqual(FeatureCatalog.info(for: .drop).hotkeys, [.dropVoice])
    }

    // MARK: - Copy

    /// Shortcuts are remappable, so no catalog text may name a key.
    func testNoCatalogTextNamesAKey() {
        var texts: [String] = [FeatureCatalog.dropAbout(gesture: .hold), FeatureCatalog.dropAbout(gesture: .tap)]
        var everything = FeatureSetupSnapshot()
        everything.dropMode = .smart
        for info in FeatureCatalog.all {
            texts += [info.name, info.kind, info.line] + info.hotkeys.map(\.label)
            for snapshot in [FeatureSetupSnapshot(), everything] {
                for check in FeatureCatalog.checks(for: info.feature, snapshot: snapshot) {
                    texts += [check.requirement.title, check.requirement.detail, check.reason ?? "",
                              check.action?.title ?? "", FeatureCatalog.consequence(of: check, for: info.feature)]
                }
            }
        }
        let keyNames = ["Space", "Command", "Option", "Control", "Shift", "⌘", "⌥", "⌃", "⇧", "Right ", "Fn"]
        for text in texts {
            for key in keyNames {
                XCTAssertFalse(text.contains(key), "“\(text)” names the key \(key)")
            }
        }
    }

    func testDropAboutFollowsTheGesture() {
        XCTAssertTrue(FeatureCatalog.dropAbout(gesture: .hold).contains("Hold the shortcut"))
        XCTAssertTrue(FeatureCatalog.dropAbout(gesture: .tap).contains("Press the shortcut"))
    }

    // MARK: - Shape of the catalog

    func testCatalogListsEveryFeatureOnceInOrder() {
        XCTAssertEqual(FeatureCatalog.all.map(\.feature), AppFeature.allCases)
        XCTAssertEqual(FeatureCatalog.all.map(\.name),
                       ["Drop", "Agent", "Meeting Notes", "Google search", "Translate & Subtitles", "Screenshots"])
    }

    func testClipsAreTheOnesThatExist() {
        XCTAssertNil(FeatureCatalog.info(for: .drop).video, "No Drop clip yet: the screen shows no placeholder")
        XCTAssertEqual(FeatureCatalog.info(for: .agent).video, .agent)
        XCTAssertEqual(FeatureCatalog.info(for: .meetings).video, .meetings)
        XCTAssertEqual(FeatureCatalog.info(for: .googleSearch).video, .googleSearch)
    }

    func testFeaturesWithoutAScreenPointAtTheirPresentPlace() {
        XCTAssertEqual(FeatureCatalog.info(for: .drop).place, .tab(.other))
        XCTAssertEqual(FeatureCatalog.info(for: .agent).place, .tab(.agentMode))
        XCTAssertEqual(FeatureCatalog.info(for: .meetings).place, .tab(.other))
        XCTAssertEqual(FeatureCatalog.info(for: .googleSearch).place, .tab(.other))
        XCTAssertEqual(FeatureCatalog.info(for: .translateSubtitles).place, .tool(.translate))
        XCTAssertEqual(FeatureCatalog.info(for: .screenshots).place, .tool(.screenshot))
    }
}
