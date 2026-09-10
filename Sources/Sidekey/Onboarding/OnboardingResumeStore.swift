import Foundation

enum OnboardingResumeStore {
    static let resumeDefaultsKey = "sidekey.b2b.onboarding.resumeStep"
    static let completedDefaultsKey = "sidekey.b2b.onboarding.hasCompleted"

    static func load(defaults: UserDefaults = .standard) -> OnboardingFlowStep? {
        guard let raw = defaults.string(forKey: resumeDefaultsKey) else {
            return nil
        }
        return OnboardingFlowStep(rawValue: raw)
    }

    static func save(_ step: OnboardingFlowStep) {
        UserDefaults.standard.set(step.rawValue, forKey: resumeDefaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: resumeDefaultsKey)
    }

    static func hasCompletedOnboarding(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedDefaultsKey)
    }

    static func markOnboardingCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedDefaultsKey)
    }

    static func resolvedInitialStep(
        fallback: OnboardingFlowStep,
        needsPermissions: Bool,
        defaults: UserDefaults = .standard
    ) -> OnboardingFlowStep {
        guard !needsPermissions else { return .permissions }
        if let saved = load(defaults: defaults), saved.canResumeAfterRelaunch {
            return saved
        }
        return fallback
    }
}

private extension OnboardingFlowStep {
    var canResumeAfterRelaunch: Bool {
        switch self {
        case .agent, .permissions, .models, .language, .drop, .tryDrop, .tryAgent, .skills, .helpers:
            return true
        }
    }
}
