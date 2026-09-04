import Foundation

/// Local store of the user's Drop mode and the capability opt-in flags.
///
/// The Dynamic Island drop-mode control reads this for a fast, synchronous
/// view of the current mode (and to flip it). Both modes use the same
/// realtime transcription pipeline for Drop; the mode only decides whether
/// the transcript runs through the cleanup LLM before the paste.
///
/// Mirrors the `PrivacyPreferences` storage pattern: namespaced
/// UserDefaults keys (`sidekey.preferences.*`), an injectable `UserDefaults`
/// instance for tests, and `@MainActor` so the singleton is naturally safe
/// to call from AppKit + SwiftUI contexts.
@MainActor
final class UserPreferencesCache {
    static let shared = UserPreferencesCache()

    private enum Key {
        /// Stored as the raw `TranscriptionMode` string (`"fast"` / `"smart"`).
        static let transcriptionMode = "sidekey.preferences.transcriptionMode"
        /// Capability opt-in flags (default OFF — `UserDefaults.bool(forKey:)`
        /// returns `false` for an absent key).
        static let agentEnabled = "sidekey.preferences.agentEnabled"
        static let meetingsEnabled = "sidekey.preferences.meetingsEnabled"
        static let googleEnabled = "sidekey.preferences.googleEnabled"
    }

    private let defaults: UserDefaults

    /// Designated initialiser takes a `UserDefaults` instance so tests
    /// can isolate writes to a UUID-named suite. Production callers use
    /// `UserPreferencesCache.shared`, which binds to
    /// `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Current Drop mode. Returns `.fast` on first launch or when a stale /
    /// corrupted value somehow ended up in defaults.
    var currentMode: TranscriptionMode {
        guard let raw = defaults.string(forKey: Key.transcriptionMode) else {
            return .fast
        }
        return TranscriptionMode(rawValue: raw) ?? .fast
    }

    /// Persists `mode` to `UserDefaults`. The next `currentMode` read
    /// (on the same or any other instance) reflects the new value.
    func setMode(_ mode: TranscriptionMode) {
        defaults.set(mode.rawValue, forKey: Key.transcriptionMode)
    }

    // MARK: - Capability opt-in flags

    /// Whether the user has opted in to the agent (R-Cmd) capability.
    /// Defaults to `false`.
    var currentAgentEnabled: Bool { defaults.bool(forKey: Key.agentEnabled) }
    func setAgentEnabled(_ on: Bool) {
        guard on != currentAgentEnabled else { return }
        defaults.set(on, forKey: Key.agentEnabled)
        NotificationCenter.default.post(name: .sidekeyCapabilityFlagsChanged, object: nil)
    }

    /// Whether the user has opted in to Meeting Notes. Defaults to `false`.
    var currentMeetingsEnabled: Bool { defaults.bool(forKey: Key.meetingsEnabled) }
    func setMeetingsEnabled(_ on: Bool) {
        guard on != currentMeetingsEnabled else { return }
        defaults.set(on, forKey: Key.meetingsEnabled)
        NotificationCenter.default.post(name: .sidekeyCapabilityFlagsChanged, object: nil)
    }

    /// Whether the user has opted in to the Google search capability.
    /// Defaults to `false`.
    var currentGoogleEnabled: Bool { defaults.bool(forKey: Key.googleEnabled) }
    func setGoogleEnabled(_ on: Bool) {
        guard on != currentGoogleEnabled else { return }
        defaults.set(on, forKey: Key.googleEnabled)
        NotificationCenter.default.post(name: .sidekeyCapabilityFlagsChanged, object: nil)
    }
}

extension Notification.Name {
    /// Posted by `UserPreferencesCache` whenever a capability flag
    /// (agent/meetings/google) actually changes value. AppDelegate
    /// listens to reconcile subsystem arming.
    static let sidekeyCapabilityFlagsChanged = Notification.Name("sidekey.capabilityFlags.changed")
}
