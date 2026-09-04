import Foundation

/// Pure launch-time routing decision. No side effects, no system calls —
/// every input is explicit so the decision is fully unit-testable.
enum OnboardingRouter {
    enum Destination: Equatable {
        case ready          // everything in place — continue the launch
        case repair         // returning user missing a permission — narrow repair screen
        case onboarding     // first run / forced — full tour
    }

    static func route(
        needsPermissions: Bool,
        hasCompletedOnboarding: Bool,
        force: Bool
    ) -> Destination {
        if force { return .onboarding }
        // A newcomer always gets the tour, even when the permission grants
        // survived a reinstall; a veteran only comes back for missing grants.
        if !hasCompletedOnboarding { return .onboarding }
        return needsPermissions ? .repair : .ready
    }
}
