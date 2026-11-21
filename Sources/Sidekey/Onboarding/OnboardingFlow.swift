import Foundation

/// The pages of the first-launch onboarding, in their only order.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
enum OnboardingPage: String, CaseIterable, Equatable {
    /// Where speech is recognized: On this Mac, or the user's own key.
    case speech
    /// Microphone and Keyboard control, until the Drop shortcut is installed.
    case permissions
    /// Hold the Drop shortcut and dictate into a real field.
    case tryDrop
    /// Google, Meetings and Agent: one switch each, then Done.
    case features
}

/// What decides which pages a person sees. Read when the window opens; a
/// page that is already done is never shown.
struct OnboardingConditions: Equatable {
    /// The speech route of the current Drop mode resolves right now.
    var dropSpeechReady: Bool
    /// Microphone and Keyboard control are granted and the Drop shortcut is
    /// installed (`PermissionsSettingsViewModel.allRequiredGranted`).
    var permissionsReady: Bool
}

enum OnboardingFlow {
    static func pages(for conditions: OnboardingConditions) -> [OnboardingPage] {
        var pages: [OnboardingPage] = []
        if !conditions.dropSpeechReady { pages.append(.speech) }
        if !conditions.permissionsReady { pages.append(.permissions) }
        pages.append(contentsOf: [.tryDrop, .features])
        return pages
    }

    /// The page after `page`, or `nil` after the last one. Without any speech
    /// on the way (the user chose Set up later and nothing downloads) the try
    /// page has nothing to dictate with, so it is passed over.
    static func next(after page: OnboardingPage, in pages: [OnboardingPage], speechExpected: Bool) -> OnboardingPage? {
        guard let index = pages.firstIndex(of: page) else { return nil }
        return pages[(index + 1)...].first { $0 != .tryDrop || speechExpected }
    }

    /// Pages with a permissions page added before the try page, for a Drop
    /// press that found a permission missing after that page was hidden.
    static func addingPermissions(to pages: [OnboardingPage]) -> [OnboardingPage] {
        guard !pages.contains(.permissions) else { return pages }
        var result = pages
        let index = result.firstIndex(of: .tryDrop) ?? result.endIndex
        result.insert(.permissions, at: index)
        return result
    }
}

/// Whether the onboarding opens at launch. It replaces the former one-time
/// Settings -> Permissions presentation on a new Mac.
///
/// Both markers are installation state of this Mac: they are not in
/// `ConfigBackupRegistry.entries`, so backups and settings sync never carry
/// them to another Mac.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
enum OnboardingLaunch {
    /// Set by every launch since 2026-10-26 (the former first-launch
    /// Permissions screen). A Mac that has it has run Whytap before: an
    /// update never shows the onboarding.
    static let presentedKey = "sidekey.permissions.firstLaunchPresented.v1"
    /// Set while an onboarding was shown and not yet finished (Done or the
    /// window closed). A quit in between brings it back on the next launch.
    static let pendingKey = "sidekey.onboarding.pending.v1"
    /// The former onboarding's completion marker (removed 2026-10-17). Its
    /// users ran Whytap before the first-launch marker existed.
    static let legacyCompletedKey = "sidekey.b2b.onboarding.hasCompleted"

    /// `true` when the onboarding should open now. Marks the Mac as launched.
    static func consume(in defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: pendingKey) { return true }
        let ranBefore = defaults.bool(forKey: presentedKey) || defaults.bool(forKey: legacyCompletedKey)
        defaults.set(true, forKey: presentedKey)
        guard !ranBefore else { return false }
        defaults.set(true, forKey: pendingKey)
        return true
    }

    static func finish(in defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingKey)
    }
}
