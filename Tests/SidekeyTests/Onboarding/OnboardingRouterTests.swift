import XCTest
@testable import Sidekey

final class OnboardingRouterTests: XCTestCase {
    func test_all_granted_completed_is_ready() {
        XCTAssertEqual(
            OnboardingRouter.route(needsPermissions: false, hasCompletedOnboarding: true, force: false),
            .ready)
    }
    func test_veteran_missing_permission_goes_to_repair() {
        XCTAssertEqual(
            OnboardingRouter.route(needsPermissions: true, hasCompletedOnboarding: true, force: false),
            .repair)
    }
    func test_newcomer_missing_permission_goes_to_onboarding() {
        XCTAssertEqual(
            OnboardingRouter.route(needsPermissions: true, hasCompletedOnboarding: false, force: false),
            .onboarding)
    }
    func test_newcomer_with_permissions_still_gets_onboarding() {
        XCTAssertEqual(
            OnboardingRouter.route(needsPermissions: false, hasCompletedOnboarding: false, force: false),
            .onboarding)
    }
    func test_force_opens_onboarding() {
        XCTAssertEqual(
            OnboardingRouter.route(needsPermissions: false, hasCompletedOnboarding: true, force: true),
            .onboarding)
    }
}
