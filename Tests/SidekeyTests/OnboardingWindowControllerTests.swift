import XCTest

final class OnboardingWindowControllerTests: XCTestCase {
    func test_onboardingUsesSharedMainScreenCenteringAcrossOrdering() throws {
        let source = try onboardingSource()

        XCTAssertTrue(
            source.contains("SidekeyWindowChrome.centerOnMainScreen(window)"),
            "Onboarding should use the shared main-screen centering helper before and after ordering."
        )
    }

    func test_onboardingShowUsesRegularDockWindowOrdering() throws {
        let source = try onboardingSource()
        guard let showRange = source.range(of: "func show()") else {
            XCTFail("OnboardingWindowController should expose show().")
            return
        }
        let showSource = source[showRange.lowerBound...]

        guard let centerRange = showSource.range(of: "SidekeyWindowChrome.centerOnMainScreen(window)"),
              let activateRange = showSource.range(of: "NSApp.activate(ignoringOtherApps: true)"),
              let orderRange = showSource.range(of: "window.makeKeyAndOrderFront(nil)") else {
            XCTFail("show() should center, activate, and show onboarding as a regular Dock window.")
            return
        }

        XCTAssertLessThan(
            centerRange.lowerBound,
            activateRange.lowerBound,
            "Onboarding should center before activating the app."
        )
        XCTAssertLessThan(
            activateRange.lowerBound,
            orderRange.lowerBound,
            "Onboarding should activate before becoming the key regular window."
        )
        XCTAssertFalse(showSource.contains("window.orderFrontRegardless()"))
    }

    func test_onboardingUsesNormalDockWindowPolicy() throws {
        let source = try onboardingSource()

        XCTAssertTrue(source.contains("window.level = .normal"))
        XCTAssertTrue(source.contains("window.collectionBehavior = [.managed, .fullScreenNone]"))
        XCTAssertFalse(source.contains("window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]"))
    }

    func test_onboardingStepsAsideDuringExternalHandoff() throws {
        let source = try onboardingSource()
        guard let methodRange = source.range(of: "func stepAsideForExternalHandoff()") else {
            XCTFail("OnboardingWindowController should expose stepAsideForExternalHandoff().")
            return
        }
        let methodSource = source[methodRange.lowerBound...]

        XCTAssertTrue(
            methodSource.contains("window.orderBack(nil)"),
            "External handoff should keep onboarding visible behind System Settings instead of making it disappear."
        )
        XCTAssertTrue(
            methodSource.contains("window.level = .normal"),
            "External handoff should demote onboarding so system-owned surfaces can sit above it."
        )
        XCTAssertFalse(
            source.contains("window.orderOut(nil)"),
            "External handoff should not hide onboarding entirely; users need to see it after opening System Settings."
        )
    }

    func test_onboardingWindowUsesNormalLevelAndKeyOrdering() throws {
        let source = try onboardingSource()

        XCTAssertTrue(source.contains("window.level = .normal"))
        XCTAssertTrue(source.contains("window.makeKeyAndOrderFront(nil)"))
        XCTAssertFalse(source.contains("orderFrontRegardless()"))
    }

    func test_onboardingWindowDoesNotJoinFullscreenSpaces() throws {
        let source = try onboardingSource()

        XCTAssertTrue(
            source.contains("window.collectionBehavior = [.managed, .fullScreenNone]"),
            "Dock-visible onboarding should be a normal desktop window, not an overlay attached to the active full-screen Space."
        )
        XCTAssertFalse(source.contains(".fullScreenAuxiliary"))
    }

    func test_onboardingRestoreAfterExternalHandoffRestoresRegularWindow() throws {
        let source = try onboardingSource()
        guard let methodRange = source.range(of: "func restoreAfterExternalHandoff()") else {
            XCTFail("OnboardingWindowController should restore after an external handoff.")
            return
        }
        let methodSource = source[methodRange.lowerBound...]

        XCTAssertTrue(methodSource.contains("window.level = .normal"))
        XCTAssertTrue(methodSource.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(methodSource.contains("window.makeKeyAndOrderFront(nil)"))
    }

    func test_onboardingTracksExternalHandoffBeforeRestoringDemotedWindow() throws {
        let source = try onboardingSource()

        XCTAssertTrue(
            source.contains("private var isSteppedAsideForExternalHandoff = false"),
            "The controller should know whether a demoted onboarding window belongs to an external handoff."
        )
        XCTAssertTrue(source.contains("func stepAsideForExternalHandoff()"))
        XCTAssertTrue(source.contains("func restoreAfterExternalHandoffIfNeeded()"))
        XCTAssertTrue(
            source.contains("guard isSteppedAsideForExternalHandoff else { return }"),
            "App activation should not randomly pull onboarding forward unless we intentionally stepped it aside for a permissions handoff."
        )
    }

    func test_permissionsContinuationActivatesNormalOnboardingWindow() throws {
        let source = try appDelegateSource()

        XCTAssertTrue(
            source.contains("showOnboardingIfNeeded { [weak self] in"),
            "Continuing setup should activate the normal onboarding window so macOS leaves fullscreen instead of attaching to it."
        )
        XCTAssertFalse(
            source.contains("showOnboardingIfNeeded(activate: false)"),
            "The non-activating path leaves onboarding behind fullscreen apps."
        )
    }

    func test_initialLaunchOnboardingActivatesNormalWindow() throws {
        let source = try appDelegateSource()
        guard let methodRange = source.range(of: "func applicationDidFinishLaunching") else {
            XCTFail("AppDelegate should own launch-time onboarding.")
            return
        }
        let methodSource = source[methodRange.lowerBound...]

        XCTAssertTrue(
            methodSource.contains("showOnboardingIfNeeded {\n            self.continueLaunchAfterPermissions()"),
            "Launch-time onboarding should activate a normal app window; macOS will leave fullscreen instead of making it a companion window."
        )
        XCTAssertFalse(
            methodSource.contains("showOnboardingIfNeeded(activate: false)")
        )
    }

    func test_appDelegatePromotesDockIconForEntireOnboardingFlow() throws {
        let source = try appDelegateSource()
        guard let showRange = source.range(of: "private func showOnboardingIfNeeded") else {
            XCTFail("AppDelegate should own onboarding presentation.")
            return
        }
        let methodSource = source[showRange.lowerBound...]

        guard let beginRange = methodSource.range(of: "beginOnboardingDockActivation()"),
              let showWindowRange = methodSource.range(of: "onboardingWindowController?.show()") else {
            XCTFail("Showing onboarding should promote Whytap to a regular Dock app before presenting the window.")
            return
        }

        XCTAssertLessThan(
            beginRange.lowerBound,
            showWindowRange.lowerBound,
            "The Dock icon must appear before onboarding orders its window."
        )
        XCTAssertTrue(source.contains("private func beginOnboardingDockActivation()"))
        XCTAssertTrue(source.contains("NSApp.setActivationPolicy(.regular)"))
        XCTAssertTrue(source.contains("NSApp.activate(ignoringOtherApps: true)"))
    }

    func test_appDelegateRestoresAccessoryAfterOnboardingCloses() throws {
        let appDelegateSource = try appDelegateSource()
        let controllerSource = try onboardingSource()

        XCTAssertTrue(
            controllerSource.contains("onClosed: @escaping () -> Void"),
            "The window controller should notify AppDelegate when the user closes onboarding with the traffic-light button."
        )
        XCTAssertTrue(
            appDelegateSource.contains("endOnboardingDockActivation()"),
            "AppDelegate should centralise the return from Dock-visible onboarding to accessory mode."
        )
        XCTAssertTrue(
            appDelegateSource.contains("NSApp.setActivationPolicy(.accessory)"),
            "After onboarding closes or finishes, Whytap should go back to menu-bar/accessory mode."
        )
    }

    func test_appDelegateReopenRestoresVisibleSurface() throws {
        let source = try appDelegateSource()
        guard let methodRange = source.range(of: "func applicationShouldHandleReopen") else {
            XCTFail("AppDelegate should handle reopen events from a second app-icon click.")
            return
        }
        let methodTail = source[methodRange.lowerBound...]
        guard let helperRange = methodTail.range(of: "private func showRuntimeSurfaceAfterReopen") else {
            XCTFail("AppDelegate should centralise runtime surface restoration for reopen events.")
            return
        }
        let methodSource = methodTail[..<helperRange.lowerBound]
        let helperSource = methodTail[helperRange.lowerBound...]

        XCTAssertTrue(methodSource.contains("beginOnboardingDockActivation()"))
        XCTAssertTrue(methodSource.contains("onboardingWindowController?.show()"))
        XCTAssertTrue(methodSource.contains("showOnboardingIfNeeded { }"))
        XCTAssertTrue(methodSource.contains("PermissionsHelper.allRequiredPermissionsGranted()"))
        XCTAssertTrue(methodSource.contains("showRuntimeSurfaceAfterReopen()"))
        XCTAssertTrue(helperSource.contains("IslandPanel.shared.show()"))
    }

    func test_tryRuntimeDoesNotOwnActivationPolicy() throws {
        let source = try appDelegateSource()
        guard let prepareRange = source.range(of: "private func prepareOnboardingTryRuntime()"),
              let stopRange = source.range(of: "private func stopOnboardingTryRuntime()") else {
            XCTFail("AppDelegate should expose try runtime lifecycle methods.")
            return
        }
        let prepareSource = source[prepareRange.lowerBound..<stopRange.lowerBound]
        let stopSource = source[stopRange.lowerBound...]

        XCTAssertFalse(
            prepareSource.contains("setActivationPolicy(.regular)"),
            "The whole onboarding flow owns Dock promotion now; try screens should only wire hotkeys and island actions."
        )
        XCTAssertFalse(
            stopSource.contains("setActivationPolicy(.accessory)"),
            "Leaving a try screen must not hide the Dock icon while the user is still inside onboarding."
        )
    }

    func test_onboardingPersistsResumeStepAcrossPermissionRelaunch() throws {
        let flowSource = try onboardingFlowSource()
        let appDelegateSource = try appDelegateSource()
        let resumeSource = try onboardingResumeStoreSource()
        let permissionsSource = try realOnboardingPermissionsSurfaceSource()

        XCTAssertTrue(resumeSource.contains("enum OnboardingResumeStore"))
        XCTAssertTrue(resumeSource.contains("onboarding.resumeStep"))
        XCTAssertTrue(flowSource.contains("OnboardingResumeStore.resolvedInitialStep"))
        XCTAssertTrue(flowSource.contains("OnboardingResumeStore.save(next)"))
        XCTAssertTrue(
            permissionsSource.contains("OnboardingResumeStore.save(.permissions)"),
            "Opening Accessibility can relaunch the app; persist the permissions step before handing off to System Settings."
        )
        XCTAssertTrue(
            appDelegateSource.contains("initialStep: initialOnboardingStep(needsPermissions: needsPermissions)"),
            "Relaunch while permissions are missing should restore the onboarding step instead of dropping back to the generic welcome gate."
        )
    }

    func test_permissionsHandoffDemotesOnboardingBeforeSystemSurfaces() throws {
        let permissionsSource = try realOnboardingPermissionsSurfaceSource()
        let controllerSource = try onboardingSource()
        let appDelegateSource = try appDelegateSource()

        XCTAssertTrue(permissionsSource.contains("onExternalPermissionHandoff()"))
        XCTAssertTrue(permissionsSource.contains("onExternalPermissionReturn()"))

        guard let micRange = permissionsSource.range(of: "func requestMic()"),
              let accessibilityRange = permissionsSource.range(of: "func requestAccessibility()") else {
            XCTFail("Real permissions surface should expose mic/accessibility requests.")
            return
        }
        let micSource = permissionsSource[micRange.lowerBound..<accessibilityRange.lowerBound]
        let accessibilitySource = permissionsSource[accessibilityRange.lowerBound...]

        guard let micHandoffRange = micSource.range(of: "onExternalPermissionHandoff()"),
              let nativeMicRange = micSource.range(of: "await PermissionsHelper.requestMicrophone()"),
              let settingsMicRange = micSource.range(of: "PermissionsHelper.openMicrophoneSettings()"),
              let accessibilityHandoffRange = accessibilitySource.range(of: "onExternalPermissionHandoff()"),
              let accessibilityRequestRange = accessibilitySource.range(of: "PermissionsHelper.requestAccessibility()") else {
            XCTFail("Permission requests should bracket system handoff calls.")
            return
        }

        XCTAssertLessThan(micHandoffRange.lowerBound, nativeMicRange.lowerBound)
        XCTAssertLessThan(micHandoffRange.lowerBound, settingsMicRange.lowerBound)
        XCTAssertLessThan(accessibilityHandoffRange.lowerBound, accessibilityRequestRange.lowerBound)
        XCTAssertTrue(controllerSource.contains("stepAsideForExternalHandoff()"))
        XCTAssertTrue(
            appDelegateSource.contains("func applicationDidBecomeActive")
                && appDelegateSource.contains("restoreAfterExternalHandoffIfNeeded()"),
            "Returning from System Settings should bring back onboarding if it was stepped aside for a permission handoff."
        )
    }

    func test_onboardingResumeCannotBypassMissingPermissions() throws {
        let resumeSource = try onboardingResumeStoreSource()
        guard let methodRange = resumeSource.range(of: "static func resolvedInitialStep") else {
            XCTFail("OnboardingResumeStore should resolve initial step.")
            return
        }
        let methodSource = resumeSource[methodRange.lowerBound...]

        guard let permissionsRange = methodSource.range(of: "guard !needsPermissions else { return .permissions }"),
              let loadRange = methodSource.range(of: "load(defaults: defaults)") else {
            XCTFail("resolvedInitialStep should check permissions and saved resume state.")
            return
        }

        XCTAssertLessThan(
            permissionsRange.lowerBound,
            loadRange.lowerBound,
            "Missing permissions must win over saved try steps; otherwise onboarding can resume into tryDrop without Accessibility."
        )
    }

    func test_tryDropScreenAutofocusesTextEditorForPasteTarget() throws {
        let source = try onboardingTryDropScreenSource()

        XCTAssertTrue(
            source.contains("tryFocused = true"),
            "Try Drop should focus its text editor on entry so the first transcript has a paste target instead of causing the system beep."
        )
    }

    func test_tryDropPasteTargetUsesAppKitFirstResponderEditor() throws {
        let source = try onboardingTryDropScreenSource()

        XCTAssertTrue(
            source.contains("NSViewRepresentable"),
            "Try Drop should not rely on SwiftUI TextEditor focus for synthetic Cmd+V."
        )
        XCTAssertTrue(
            source.contains("window.makeFirstResponder"),
            "Try Drop should explicitly make its editor first responder once attached to the onboarding window."
        )
        XCTAssertFalse(
            source.contains("TextEditor(text: $text)"),
            "SwiftUI TextEditor focus is too flaky for the onboarding paste target."
        )
    }

    func test_tryDropReceivesOnboardingTranscriptWithoutGlobalAutopaste() throws {
        let dropSource = try onboardingTryDropScreenSource()
        let appDelegateSource = try appDelegateSource()
        let flowSource = try onboardingFlowSource()
        let controllerSource = try onboardingSource()

        XCTAssertTrue(dropSource.contains(".sidekeyOnboardingDropTranscript"))
        XCTAssertTrue(dropSource.contains("private func receiveDropTranscript"))
        XCTAssertTrue(dropSource.contains("tryText = normalized"))

        XCTAssertTrue(appDelegateSource.contains("private func deliverDropTranscript"))
        XCTAssertTrue(appDelegateSource.contains("currentStep == .tryDrop"))
        XCTAssertTrue(appDelegateSource.contains("NotificationCenter.default.post("))
        XCTAssertTrue(appDelegateSource.contains("name: .sidekeyOnboardingDropTranscript"))
        XCTAssertTrue(
            appDelegateSource.contains("await deliverDropTranscript("),
            "Drop finalization should route through the onboarding-aware delivery helper."
        )

        XCTAssertTrue(flowSource.contains("onStepChanged(next)"))
        XCTAssertTrue(controllerSource.contains("private(set) var currentStep"))
    }

    func test_accessibilityRequestSeedsCurrentProcessInTCC() throws {
        let permissionsHelperSource = try permissionsHelperSource()
        let onboardingPermissionsSource = try realOnboardingPermissionsSurfaceSource()
        let settingsPermissionsSource = try onboardingPermissionsViewModelSource()

        XCTAssertTrue(permissionsHelperSource.contains("static func requestAccessibility()"))
        XCTAssertTrue(
            permissionsHelperSource.contains("return AXIsProcessTrusted()"),
            "Check-only Accessibility reads should use the plain AX trust API so they do not disturb or re-prompt TCC state."
        )
        XCTAssertTrue(
            permissionsHelperSource.contains("accessibilityGranted(prompt: true)"),
            "Accessibility should use the AX prompt so TCC registers the currently running bundle, not whichever old Whytap entry is already visible."
        )
        XCTAssertTrue(onboardingPermissionsSource.contains("PermissionsHelper.requestAccessibility()"))
        XCTAssertTrue(settingsPermissionsSource.contains("PermissionsHelper.requestAccessibility()"))
    }

    func test_onboardingFlowStopsDemoAudioBeforeChangingScreens() throws {
        let source = try onboardingFlowSource()
        guard let methodRange = source.range(of: "private func advance(to next: OnboardingFlowStep)") else {
            XCTFail("OnboardingFlowView should own step advancement.")
            return
        }
        let methodSource = source[methodRange.lowerBound...]

        guard let stopRange = methodSource.range(of: "stopDemoAudio()"),
              let saveRange = methodSource.range(of: "OnboardingResumeStore.save(next)") else {
            XCTFail("advance(to:) should stop demo audio before saving and switching steps.")
            return
        }

        XCTAssertLessThan(
            stopRange.lowerBound,
            saveRange.lowerBound,
            "Agent/welcome audio must stop synchronously when the user switches screens, not wait for SwiftUI onDisappear."
        )
    }

    func test_onboardingLanguageStepDoesNotPrefillPersistedLanguage() throws {
        let source = try onboardingFlowSource()

        XCTAssertTrue(
            source.contains("@State private var selectedLanguage: AppLanguage? = nil"),
            "The onboarding language step should start from Auto/no selection instead of showing a stale saved language."
        )
        XCTAssertFalse(
            source.contains("@State private var selectedLanguage: AppLanguage? = PrivacyPreferences.shared.selectedLanguage")
        )
        XCTAssertTrue(source.contains("onContinue: continueFromLanguage"))
        XCTAssertTrue(source.contains("private func continueFromLanguage()"))
        XCTAssertTrue(source.contains("PrivacyPreferences.shared.selectedLanguage = selectedLanguage"))
    }

    func test_permissionActionButtonsShareHoverableGeometry() throws {
        let source = try onboardingPermissionsScreenSource()

        XCTAssertTrue(source.contains("private struct PermissionActionButton"))
        XCTAssertTrue(source.contains("@State private var isHovering"))
        XCTAssertTrue(source.contains(".onHover { isHovering = $0 }"))
        XCTAssertFalse(source.contains("PermissionActionButton(title: \"Open Settings\""))
        // Both permission rows must use the SAME single label source so they
        // read as the same control. ROO-261 made the label localized
        // (`enableLabel`, sourced once from the EN/RU copy provider) instead
        // of a hardcoded "Enable", so both rows now pass `title: enableLabel`.
        XCTAssertTrue(source.contains("case .denied:\n            PermissionActionButton(title: enableLabel, tone: .primary"))
        XCTAssertTrue(source.contains("case .pending:\n            PermissionActionButton(title: enableLabel, tone: .primary"))
        XCTAssertTrue(
            source.contains(".frame(width: 126, height: 32)"),
            "Permission actions should use one stable size and one stable label so both permission rows read as the same control."
        )
    }

    func test_tryStepsShowWhytapSurfaceFromFlowLifecycle() throws {
        let flowSource = try onboardingFlowSource()
        let appDelegateSource = try appDelegateSource()
        let dropSource = try onboardingTryDropScreenSource()

        XCTAssertTrue(
            flowSource.contains("syncWhytapSurface(for: step)"),
            "Restored onboarding should show Whytap immediately when it resumes into a try step."
        )
        XCTAssertTrue(
            flowSource.contains("syncWhytapSurface(for: next)"),
            "Advancing into or out of try steps should update the real Whytap surface."
        )
        XCTAssertTrue(
            appDelegateSource.contains("IslandPanel.shared.show()"),
            "The try steps should bring up the real Whytap surface through AppDelegate so final onboarding close cannot race-hide the app runtime."
        )
        XCTAssertTrue(
            appDelegateSource.contains("IslandPanel.shared.hide()"),
            "Leaving the try steps or closing onboarding should clean up the temporary Whytap surface through AppDelegate."
        )
        XCTAssertFalse(
            flowSource.contains("IslandPanel.shared"),
            "SwiftUI onboarding screens should not directly own the production island window; late onDisappear events can otherwise hide it after startReady shows it."
        )
        XCTAssertTrue(
            flowSource.contains("var isTryStep: Bool"),
            "The lifecycle should be keyed off the step model, not duplicated in individual screens."
        )
        XCTAssertFalse(dropSource.contains("IslandPanel.shared"))
    }

    func test_tryStepsPrepareInteractiveRuntimeForHotkeysAndIslandButtons() throws {
        let appDelegateSource = try appDelegateSource()
        let controllerSource = try onboardingSource()
        let flowSource = try onboardingFlowSource()

        XCTAssertTrue(
            flowSource.contains("onTryStepRuntimeRequired()"),
            "Showing Whytap on a try step is not enough: the flow must also ask AppDelegate to wire actions and hotkeys."
        )
        XCTAssertTrue(
            controllerSource.contains("onTryStepRuntimeRequired:"),
            "The onboarding window should pass the try-step runtime request from SwiftUI back to AppDelegate."
        )
        XCTAssertTrue(
            appDelegateSource.contains("prepareOnboardingTryRuntime()"),
            "AppDelegate should expose a narrow runtime prep path for onboarding try screens."
        )
        XCTAssertTrue(
            appDelegateSource.contains("IslandPanel.shared.actions = makeIslandActions()")
                && appDelegateSource.contains("registerHotkey()")
                && appDelegateSource.contains("startAgentIfEnabled()"),
            "Try runtime prep should wire island buttons, Drop hotkey, and Agent hotkeys before the user tests them."
        )
    }

    func test_leavingTryStepsStopsTemporaryInteractiveRuntime() throws {
        let appDelegateSource = try appDelegateSource()
        let controllerSource = try onboardingSource()
        let flowSource = try onboardingFlowSource()

        XCTAssertTrue(
            flowSource.contains("onTryStepRuntimeNoLongerRequired()"),
            "Leaving try steps should notify the host so temporary hotkeys do not keep firing on other onboarding screens."
        )
        XCTAssertTrue(
            controllerSource.contains("onTryStepRuntimeNoLongerRequired:"),
            "The onboarding window should bridge try-runtime teardown back to AppDelegate."
        )
        XCTAssertTrue(
            appDelegateSource.contains("stopOnboardingTryRuntime()"),
            "AppDelegate should tear down the temporary try runtime while the full app startup has not completed."
        )
        XCTAssertTrue(
            appDelegateSource.contains("onboardingTryRuntimePrepared"),
            "Teardown should only stop runtime that onboarding started, not an already-ready app opened from the menu."
        )
    }

    func test_tryRuntimeWiresIslandActionsBeforePermissionGatedHotkeys() throws {
        let appDelegateSource = try appDelegateSource()
        guard let methodRange = appDelegateSource.range(of: "private func prepareOnboardingTryRuntime()") else {
            XCTFail("AppDelegate should expose onboarding try runtime prep.")
            return
        }
        let methodSource = appDelegateSource[methodRange.lowerBound...]

        guard let actionsRange = methodSource.range(of: "IslandPanel.shared.actions = makeIslandActions()"),
              let permissionRange = methodSource.range(of: "PermissionsHelper.allRequiredPermissionsGranted()") else {
            XCTFail("Try runtime should wire actions and separately check permissions for hotkeys.")
            return
        }

        XCTAssertLessThan(
            actionsRange.lowerBound,
            permissionRange.lowerBound,
            "Island buttons like Quit/Settings must be real even if TCC has not granted hotkey permissions yet."
        )
    }

    func test_onboardingPackagingCopiesAudioResources() throws {
        let devRunSource = try scriptSource("dev-run.sh")
        let buildDMGSource = try scriptSource("build-dmg.sh")

        for source in [devRunSource, buildDMGSource] {
            XCTAssertTrue(source.contains("Resources/OnboardingAudio"))
            XCTAssertTrue(source.contains("${APP_BUNDLE}/Contents/Resources/OnboardingAudio"))
        }
    }

    func test_devRunUsesNormalLaunchForFullscreenTransition() throws {
        let devRunSource = try scriptSource("dev-run.sh")

        XCTAssertTrue(
            devRunSource.contains("open \"${APP_BUNDLE}\""),
            "Local verification should launch the bundled app through LaunchServices."
        )
        XCTAssertTrue(
            devRunSource.contains("Stopping existing ${BUNDLE_DISPLAY_NAME} dev process"),
            "Local verification should relaunch the dev bundle instead of reusing a stale process."
        )
        XCTAssertTrue(
            devRunSource.contains("CFBundleIdentifier") && devRunSource.contains("[ \"${bundle_id}\" = \"${BUNDLE_ID}\" ]"),
            "Local verification should also stop stale beta installs with the same bundle id so macOS cannot relaunch the old app after a permission toggle."
        )
        XCTAssertFalse(
            devRunSource.contains("open -g \"${APP_BUNDLE}\"")
        )
    }

    func test_devRunUsesFileTokenStoreToAvoidKeychainPromptsDuringOnboarding() throws {
        let devRunSource = try scriptSource("dev-run.sh")
        let keychainStoreSource = try keychainStoreSource()

        XCTAssertTrue(
            devRunSource.contains("-Xswiftc -DSIDEKEY_FILE_TOKEN_STORE"),
            "The local dev app should opt into the file-backed token store to avoid Keychain prompts during onboarding."
        )
        XCTAssertTrue(
            keychainStoreSource.contains("SIDEKEY_FILE_TOKEN_STORE"),
            "KeychainStore should expose a compile flag for dev-run to opt out of SecItem prompts."
        )
        XCTAssertTrue(
            keychainStoreSource.contains("#if DEBUG && SIDEKEY_FILE_TOKEN_STORE"),
            "Only dev-onboarding (DEBUG + SIDEKEY_FILE_TOKEN_STORE) uses FileTokenStore; release, beta, and plain swift test all go to the login keychain."
        )
    }

    func test_onboardingFlowUsesBundledAudioAndMuteButtonForDemoScreens() throws {
        let source = try onboardingFlowSource()

        XCTAssertTrue(source.contains("OnboardingAudioResources.welcomeVoiceURL()"))
        XCTAssertTrue(source.contains("OnboardingAudioResources.url(forSample:)"))
        XCTAssertTrue(
            source.contains("OnboardingMuteButton"),
            "The real onboarding flow should show the same speaker/mute affordance as the preview."
        )
        XCTAssertTrue(source.contains("dropOrb.isMuted = next"))
        XCTAssertTrue(source.contains("agentOrb.isMuted = next"))
    }

    func test_onboardingWindowCloseStopsDemoAudio() throws {
        let controllerSource = try onboardingSource()
        let flowSource = try onboardingFlowSource()

        XCTAssertTrue(controllerSource.contains("private let lifecycleEvents = OnboardingLifecycleEvents()"))
        XCTAssertTrue(controllerSource.contains("lifecycleEvents.stopAudio()"))
        XCTAssertTrue(controllerSource.contains("override func close()"))
        XCTAssertTrue(controllerSource.contains("window.delegate = self"))
        XCTAssertTrue(controllerSource.contains("func windowWillClose"))

        XCTAssertTrue(flowSource.contains("final class OnboardingLifecycleEvents"))
        XCTAssertTrue(flowSource.contains(".onChange(of: lifecycleEvents.stopAudioRequest)"))
        XCTAssertTrue(flowSource.contains(".onDisappear"))
        XCTAssertTrue(flowSource.contains("private func stopDemoAudio()"))
        XCTAssertTrue(flowSource.contains("dropOrb.stop()"))
        XCTAssertTrue(flowSource.contains("agentOrb.stop()"))
    }

    func test_onboardingAudioResourcesResolveWelcomeAndAgentSamples() throws {
        let source = try onboardingAudioResourcesSource()

        XCTAssertTrue(source.contains("Bundle.main"))
        XCTAssertTrue(source.contains("OnboardingAudio"))
        XCTAssertTrue(source.contains("welcome-voice"))
        XCTAssertTrue(source.contains("func url(forSample name: String"))
    }

    func test_appPackagingDoesNotPutSwiftPMResourceBundleInAppRoot() throws {
        let devRunSource = try scriptSource("dev-run.sh")
        let buildDMGSource = try scriptSource("build-dmg.sh")

        for source in [devRunSource, buildDMGSource] {
            XCTAssertFalse(
                source.contains("${APP_BUNDLE}/Sidekey_Sidekey.bundle"),
                "Extra files at the .app root break code signing with unsealed contents."
            )
        }
    }

    private func onboardingSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("OnboardingWindowController.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func appDelegateSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("AppDelegate.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func onboardingFlowSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Onboarding")
            .appendingPathComponent("OnboardingFlowView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func onboardingPermissionsScreenSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Onboarding")
            .appendingPathComponent("OnboardingPermissionsScreen.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func onboardingTryDropScreenSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Onboarding")
            .appendingPathComponent("OnboardingTryDropScreen.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func onboardingAudioResourcesSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Onboarding")
            .appendingPathComponent("OnboardingAudioResources.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func keychainStoreSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Auth")
            .appendingPathComponent("KeychainStore.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func onboardingResumeStoreSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Onboarding")
            .appendingPathComponent("OnboardingResumeStore.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func realOnboardingPermissionsSurfaceSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Onboarding")
            .appendingPathComponent("RealOnboardingPermissionsSurface.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func permissionsHelperSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("PermissionsHelper.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func onboardingPermissionsViewModelSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("OnboardingPermissionsViewModel.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func packageSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root.appendingPathComponent("Package.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func scriptSource(_ filename: String) throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("scripts")
            .appendingPathComponent(filename)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "OnboardingWindowControllerTests", code: 1)
    }
}
