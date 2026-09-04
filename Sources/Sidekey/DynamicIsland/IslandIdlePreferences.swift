import Foundation

/// UserDefaults-backed on/off switch for the Dynamic Island idle auto-hide
/// (spec §6). Default ON (missing key = enabled), mirroring `VolumeDuckConfig`
/// — the feature shipped always-on in 1.17.1, so the toggle only ever lets a
/// user OPT OUT; a fresh install keeps the current behaviour.
///
/// A real change posts `didChangeNotification` so the host can poke the live
/// `IslandIdleController` (a disable while the island is hidden must un-hide it
/// immediately, not wait for the next hover/hotkey). Setting the same value is
/// a no-op and posts nothing — same contract as
/// `IslandScreenResolver.setPreferredDisplayUUID`.
@MainActor
final class IslandIdlePreferences {
    /// `UserDefaults` key. Centralised so
    /// `defaults write <bundle-id> com.sidekey.island.idleHideEnabled -bool false`
    /// has one canonical rollback key string.
    static let isEnabledDefaultsKey = "com.sidekey.island.idleHideEnabled"

    /// Posted after `isEnabled` persists a DIFFERENT value. The host observes it
    /// and calls `IslandIdleController.settingsDidChange()`.
    static let didChangeNotification = Notification.Name(
        "sidekey.dynamicIsland.idleHideEnabledDidChange"
    )

    private let defaults: UserDefaults
    private let center: NotificationCenter

    init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
    }

    /// Whether idle auto-hide is active. Missing key means enabled; explicit
    /// `false` is the opt-out.
    var isEnabled: Bool {
        get {
            guard let stored = defaults.object(forKey: Self.isEnabledDefaultsKey) as? Bool else {
                return true
            }
            return stored
        }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: Self.isEnabledDefaultsKey)
            center.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
