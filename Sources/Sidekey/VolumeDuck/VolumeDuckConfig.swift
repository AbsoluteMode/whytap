import Foundation

/// UserDefaults-backed toggle for lowering the system output volume while the
/// user records voice (Drop / agent). Default ON (missing key = enabled),
/// mirroring `NowPlayingConfig`.
@MainActor
final class VolumeDuckConfig {
    /// `UserDefaults` key. Centralised so
    /// `defaults write <bundle-id> com.sidekey.volumeduck.enabled -bool false`
    /// has one canonical rollback key string.
    static let isEnabledDefaultsKey = "com.sidekey.volumeduck.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether volume-ducking-while-speaking is active. Missing key means
    /// enabled; explicit `false` is the kill switch.
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
