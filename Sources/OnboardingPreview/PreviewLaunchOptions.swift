import Foundation

/// Preview-only launch configuration driven by environment variables, so a
/// screenshot harness can render a deterministic onboarding screen in a
/// chosen language without clicking through the flow or relying on system
/// grants. None of this exists in the production app — `PreviewRoot`
/// reimplements the flow with mock surfaces, and these knobs only seed its
/// initial state.
///
///   PREVIEW_LANG=en|ru     onboarding UI language at launch (default: en)
///   PREVIEW_STEP=<name>    onboarding step to start on (default: welcome)
///
/// Accepted `PREVIEW_STEP` values are the `PreviewRoot.Step` raw values:
/// welcome, agent, permissions, language, drop, tryDrop,
/// tryAgent, skills, helpers. Parsing is
/// case-insensitive; an unset or unrecognised value falls back to the
/// normal default and logs a notice.
enum PreviewLaunchOptions {
    static let languageKey = "PREVIEW_LANG"
    static let stepKey = "PREVIEW_STEP"

    /// Builds the onboarding locale and forces its language from
    /// `PREVIEW_LANG` when present. Setting `.language` explicitly also
    /// overrides any value persisted by a previous preview run, so the env
    /// var is authoritative for the screenshot.
    @MainActor
    static func makeLocale() -> OnboardingLocale {
        let locale = OnboardingLocale()
        if let lang = resolvedLanguage() {
            locale.language = lang
        }
        return locale
    }

    /// Resolves `PREVIEW_STEP` to a `PreviewRoot.Step`, defaulting to
    /// `.welcome` (the normal preview entry point) when unset/unknown.
    static func initialStep() -> PreviewRoot.Step {
        guard let raw = environmentValue(stepKey) else { return .welcome }
        if let match = PreviewRoot.Step.allCases.first(where: {
            $0.rawValue.lowercased() == raw.lowercased()
        }) {
            return match
        }
        let accepted = PreviewRoot.Step.allCases.map(\.rawValue).joined(separator: ", ")
        NSLog("OnboardingPreview: unknown PREVIEW_STEP=\"%@\" — using .welcome. Accepted: %@", raw, accepted)
        return .welcome
    }

    /// Parses `PREVIEW_LANG` to an `OnboardingUILanguage`, or nil when
    /// unset (caller keeps the default English locale). An unrecognised
    /// value logs a notice and is treated as unset.
    private static func resolvedLanguage() -> OnboardingUILanguage? {
        guard let raw = environmentValue(languageKey) else { return nil }
        if let match = OnboardingUILanguage(rawValue: raw.lowercased()) {
            return match
        }
        NSLog("OnboardingPreview: unknown PREVIEW_LANG=\"%@\" — using en. Accepted: en, ru", raw)
        return nil
    }

    /// Reads an env var, trimming whitespace and treating empty as unset.
    private static func environmentValue(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
