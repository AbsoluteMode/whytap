import Foundation

/// Feature flag for the Now Playing (Dynamic Island music) feature.
///
/// Mirrors `MeetingsConfig`: `isEnabled` toggles the whole
/// `NowPlayingCoordinator` wiring on or off via `UserDefaults`. The
/// rollout default is `true` so installs run without a manual
/// `defaults write`; an explicit stored `false` is the kill switch.
///
/// `isEnabled` lives on the instance (not static) so tests inject an
/// isolated `UserDefaults` suite and flipping the flag never leaks between
/// tests or into real user preferences.
@MainActor
final class NowPlayingConfig {
    /// `UserDefaults` key for the toggle. Centralised so
    /// `defaults write <bundle-id> com.sidekey.nowplaying.enabled -bool false`
    /// has one canonical rollback key string. The Stage 4 Settings toggle
    /// binds to this same key.
    static let isEnabledDefaultsKey = "com.sidekey.nowplaying.enabled"

    private let defaults: UserDefaults

    /// - Parameter defaults: typically `.standard`; tests inject an
    ///   isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Feature flag. Missing key means enabled for the current rollout;
    /// explicit `false` remains a kill switch.
    var isEnabled: Bool {
        get {
            guard let stored = defaults.object(forKey: Self.isEnabledDefaultsKey) as? Bool else {
                return true
            }
            return stored
        }
        set { defaults.set(newValue, forKey: Self.isEnabledDefaultsKey) }
    }
}
