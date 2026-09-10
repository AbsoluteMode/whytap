import XCTest
@testable import Sidekey

final class OnboardingResumeStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.onboarding.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_completion_flag_defaults_false_and_can_be_marked() {
        XCTAssertFalse(OnboardingResumeStore.hasCompletedOnboarding(defaults: defaults))
        OnboardingResumeStore.markOnboardingCompleted(defaults: defaults)
        XCTAssertTrue(OnboardingResumeStore.hasCompletedOnboarding(defaults: defaults))
    }

    func test_resolvedInitialStep_usesFallbackWithoutSavedStep() {
        let resolved = OnboardingResumeStore.resolvedInitialStep(
            fallback: .language, needsPermissions: false, defaults: defaults)
        XCTAssertEqual(resolved, .language)
    }

    func test_resolvedInitialStep_restoresSavedStep() {
        defaults.set(OnboardingFlowStep.skills.rawValue, forKey: OnboardingResumeStore.resumeDefaultsKey)
        let resolved = OnboardingResumeStore.resolvedInitialStep(
            fallback: .permissions, needsPermissions: false, defaults: defaults)
        XCTAssertEqual(resolved, .skills)
    }

    func test_modelsSetupResumesWithoutArmingTryRuntime() {
        defaults.set(OnboardingFlowStep.models.rawValue, forKey: OnboardingResumeStore.resumeDefaultsKey)
        XCTAssertEqual(OnboardingResumeStore.resolvedInitialStep(
            fallback: .permissions, needsPermissions: false, defaults: defaults), .models)
        XCTAssertFalse(OnboardingFlowStep.models.isTryStep)
        XCTAssertEqual(OnboardingResumeStore.resolvedInitialStep(
            fallback: .models, needsPermissions: true, defaults: defaults), .permissions)
    }

    func test_resolvedInitialStep_missingPermissionsWinOverSavedStep() {
        defaults.set(OnboardingFlowStep.tryDrop.rawValue, forKey: OnboardingResumeStore.resumeDefaultsKey)
        let resolved = OnboardingResumeStore.resolvedInitialStep(
            fallback: .language, needsPermissions: true, defaults: defaults)
        XCTAssertEqual(resolved, .permissions)
    }

    func test_resolvedInitialStep_fallsBackFromRetiredStoredStep() {
        // Older installs could have persisted a step this build no longer has
        // (the sign-in screen). It must not decode, so the flow resumes from
        // the fallback instead of crashing or landing on a phantom step.
        defaults.set("auth", forKey: OnboardingResumeStore.resumeDefaultsKey)
        XCTAssertNil(OnboardingResumeStore.load(defaults: defaults))
        let resolved = OnboardingResumeStore.resolvedInitialStep(
            fallback: .permissions, needsPermissions: false, defaults: defaults)
        XCTAssertEqual(resolved, .permissions)
    }
}
