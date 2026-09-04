import Foundation

/// User-controlled display preferences. `hideHelpers` is surfaced by
/// the status-bar menu as "Hide Helpers" and removes inline shortcut
/// affordances. `hideIslandHoverWidgets` is the Dynamic Island eye
/// toggle: when enabled, hover expansion and the Now Playing island
/// surfaces stay hidden until the user opens the eye again.
///
/// `ObservableObject` (not the lighter-weight `@MainActor` pattern used
/// by `PrivacyPreferences`) because three of the four helper consumers
/// are SwiftUI views that need to react reactively to the toggle. The
/// menu rebuilds on every flip, so a non-observable plain class would
/// have worked for the menu alone — but it would force the SwiftUI
/// views to re-mount via host rebuild on every toggle, which is the
/// pattern this class avoids.
///
/// The class is `@MainActor` because it owns `@Published` state read by
/// SwiftUI views (which require main-actor observation in Swift 6
/// strict concurrency) and because the singleton is created on the
/// main actor inside `AppDelegate`.
@MainActor
final class DisplayPreferences: ObservableObject {
    static let shared = DisplayPreferences()

    /// UserDefaults keys are namespaced under `sidekey.preferences.*` so
    /// they sit alongside other user-preference toggles (e.g.
    /// `sidekey.preferences.selectedLanguage` in `PrivacyPreferences`)
    /// and stay distinct from the `sidekey.privacy.*` group.
    private enum Key {
        static let hideHelpers = "sidekey.preferences.hideHelpers"
        static let hideIslandHoverWidgets = "sidekey.preferences.hideIslandHoverWidgets"
    }

    private let defaults: UserDefaults

    /// Designated initializer takes a `UserDefaults` instance so tests
    /// can inject an isolated suite instead of polluting `.standard`.
    /// Production code uses `DisplayPreferences.shared`, which is bound
    /// to `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Mirror the persisted value into the `@Published` storage so
        // the first read inside SwiftUI observation reflects the
        // round-tripped UserDefaults value, not the property's default.
        self._hideHelpers = Published(initialValue: defaults.bool(forKey: Key.hideHelpers))
        self._hideIslandHoverWidgets = Published(
            initialValue: defaults.bool(forKey: Key.hideIslandHoverWidgets)
        )
    }

    /// When `true`, every inline helper chip in the UI hides itself.
    /// Setter persists the new value to the bound `UserDefaults`
    /// instance before publishing the change so observers can read the
    /// new state via either the property or the defaults backing store.
    /// Default = `false` (helpers visible) so a fresh user discovers
    /// the hotkeys.
    @Published var hideHelpers: Bool = false {
        didSet {
            defaults.set(hideHelpers, forKey: Key.hideHelpers)
        }
    }

    /// When `true`, the Dynamic Island ignores hover expansion and hides
    /// its compact/expanded Now Playing widgets. Default = `false` so the
    /// island behaves normally until the user closes the eye button.
    @Published var hideIslandHoverWidgets: Bool = false {
        didSet {
            defaults.set(hideIslandHoverWidgets, forKey: Key.hideIslandHoverWidgets)
        }
    }
}
