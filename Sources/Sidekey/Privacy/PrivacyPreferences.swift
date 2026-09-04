import Foundation

/// Per-user preferences: screenshot protection for the island overlay plus
/// the transcription / output languages.
///
/// State is persisted in `UserDefaults` so the toggles survive relaunch.
///
/// TODO(rename): this class is no longer purely "privacy" — `selectedLanguage`
/// is a user preference, not a privacy toggle. Once a second non-privacy
/// preference lands, rename to `UserPreferences` (and migrate the
/// `sidekey.privacy.*` UserDefaults keys to a unified namespace). Holding
/// off on the rename here to keep the diff small.
@MainActor
final class PrivacyPreferences {
    static let shared = PrivacyPreferences()

    /// UserDefaults keys are namespaced under `sidekey.privacy.*` so they
    /// can be cleared as a group when implementing "erase my data". The
    /// `selectedLanguage` key uses the `sidekey.preferences.*` namespace —
    /// it's not strictly a privacy setting, and the class is slated to be
    /// renamed (see TODO at top of file).
    private enum Key {
        static let screenshotProtectionEnabled = "sidekey.privacy.screenshotProtectionEnabled"
        /// Stores the ISO 639-1 code of the selected language (e.g. "ru").
        /// `nil` / absent key means Auto (the STT provider detects it from audio).
        static let selectedLanguage = "sidekey.preferences.selectedLanguage"
        static let targetLanguage = "sidekey.preferences.targetLanguage"
    }

    private let defaults: UserDefaults

    /// Designated initializer takes a `UserDefaults` instance so tests can
    /// use an isolated suite instead of polluting `.standard`. Production
    /// code uses `PrivacyPreferences.shared`, which is bound to
    /// `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// When enabled, the Dynamic Island overlay (transcripts, agent answers,
    /// history cards) opts out of macOS screenshots and screen shares.
    /// Defaults to `false` so the island stays visible in shares unless the
    /// user turns protection on (Settings -> Other).
    var screenshotProtectionEnabled: Bool {
        get {
            defaults.bool(forKey: Key.screenshotProtectionEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.screenshotProtectionEnabled)
        }
    }

    /// Selected transcription and agent response language. `nil` means Auto —
    /// the STT provider detects the language automatically from the audio.
    /// Stored as an ISO 639-1 code (e.g. "ru") in UserDefaults.
    ///
    /// Setting this property persists the code immediately. Setting to `nil`
    /// clears the key so subsequent reads return `nil` (Auto).
    ///
    /// Migration: the old free-form `sidekey.preferences.outputLanguage` key
    /// is intentionally abandoned — any value stored there is ignored. Users
    /// with an old value will see "Auto" on first launch and can re-select
    /// their language from the submenu. The old key is not deleted to avoid
    /// unnecessary writes, but it is never read.
    var selectedLanguage: AppLanguage? {
        get {
            guard let code = defaults.string(forKey: Key.selectedLanguage) else { return nil }
            return AppLanguage.find(code: code)
        }
        set {
            if let lang = newValue {
                defaults.set(lang.code, forKey: Key.selectedLanguage)
            } else {
                defaults.removeObject(forKey: Key.selectedLanguage)
            }
        }
    }

    /// Output (target) language for Smart-mode translation. `nil` means the
    /// feature is off — the drop comes back in the input language. When set to
    /// a language different from `selectedLanguage`, the Smart cleaner returns
    /// the message translated into it. Stored as an ISO 639-1 code in
    /// UserDefaults; setting `nil` clears the key.
    var targetLanguage: AppLanguage? {
        get {
            guard let code = defaults.string(forKey: Key.targetLanguage) else { return nil }
            return AppLanguage.find(code: code)
        }
        set {
            if let lang = newValue {
                defaults.set(lang.code, forKey: Key.targetLanguage)
            } else {
                defaults.removeObject(forKey: Key.targetLanguage)
            }
        }
    }

    /// Compatibility shim for `AgentController` which reads `outputLanguage`
    /// to pass the English language name to the agent prompt. Returns the
    /// `englishName` of the selected language, or `nil` for Auto.
    ///
    /// Read-only — write via `selectedLanguage` instead.
    var outputLanguage: String? { selectedLanguage?.englishName }
}
