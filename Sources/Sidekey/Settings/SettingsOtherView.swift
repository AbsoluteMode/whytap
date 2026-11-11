import SwiftUI

/// Settings → "Other" tab.
///
/// Holds miscellaneous per-user toggles that do not belong to a dedicated
/// Settings section:
///   - Volume ducking while recording voice (bound to `VolumeDuckConfig`)
///   - Meeting Notes on/off (capability flag, persisted by the host)
///   - Google search on/off (capability flag, persisted by the host)
///   - Island display picker (bound to the injected `DisplayPickerViewModel`)
///   - Screenshot protection for the island overlay (`PrivacyPreferences`)
///
/// The view is deliberately pure: capability toggles route through injected
/// closures (`onMeetingsToggle`, `onGoogleToggle`) so the host — not this
/// view — owns the cache write. This mirrors the pattern used in
/// Settings capability toggles.
@MainActor
struct SettingsOtherView: View {
    /// Injected (the host owns it as `@StateObject`) so the options list
    /// survives this view's re-inits on tab switches.
    @ObservedObject private var displayPicker: DisplayPickerViewModel

    private let volumeDuckConfig: VolumeDuckConfig
    /// Injected on/off switch for the island idle auto-hide. Writing it posts
    /// `IslandIdlePreferences.didChangeNotification`, which the host observes to
    /// poke the live `IslandIdleController` — the view stays pure (no controller
    /// reference).
    private let islandIdlePreferences: IslandIdlePreferences
    /// Live getter for the meetings capability flag. Read on `init` AND on
    /// `.onAppear` so a revisit (SwiftUI recreates the tab view) reflects the
    /// current value rather than a stale static seed.
    private let meetingsEnabledProvider: () -> Bool
    /// Live getter for the Google search capability flag (same contract as
    /// `meetingsEnabledProvider`).
    private let googleEnabledProvider: () -> Bool
    private let onMeetingsToggle: (Bool) -> Void
    private let onGoogleToggle: (Bool) -> Void
    /// Backing store for the screenshot-protection toggle.
    private let privacyPreferences: PrivacyPreferences
    /// Applies the toggle to the live island panel (host-wired).
    private let screenshotProtectionChanged: (Bool) -> Void

    /// Local mirror of the volume-duck flag. Seeded from `volumeDuckConfig`
    /// on init and re-read on appear; written back on every toggle.
    @State private var volumeDuckEnabled: Bool
    @State private var dropAutoStopEnabled = false

    /// Local mirror of the island auto-hide flag. Seeded from
    /// `islandIdlePreferences` on init and re-read on appear; written back on
    /// every toggle.
    @State private var islandAutoHideEnabled: Bool

    /// Local mirror of the meetings capability flag. Seeded from
    /// `meetingsEnabledProvider()` on init and re-read on appear; live changes
    /// route through `onMeetingsToggle`.
    @State private var meetingsEnabled: Bool

    /// Local mirror of the Google search capability flag. Seeded from
    /// `googleEnabledProvider()` on init and re-read on appear; live changes
    /// route through `onGoogleToggle`.
    @State private var googleEnabled: Bool

    /// Local mirror of the screenshot-protection flag. Seeded from
    /// `privacyPreferences` on init and re-read on appear.
    @State private var screenshotProtectionEnabled: Bool

    /// - Parameters:
    ///   - displayPicker: Host-owned view model for the island display row.
    ///   - volumeDuckConfig: Injected config object (defaults to a
    ///     `.standard`-backed instance for production callers).
    ///   - meetingsEnabled: Live getter for the Meetings toggle seed. Read on
    ///     init and re-read on appear so a tab revisit never shows a stale value.
    ///   - googleEnabled: Live getter for the Google toggle seed (same contract).
    ///   - onMeetingsToggle: Called when the user flips the Meetings switch.
    ///     The host writes the flag to the cache.
    ///   - onGoogleToggle: Called when the user flips the Google switch.
    ///     The host writes the flag to the cache.
    ///   - screenshotProtectionChanged: Called when the user flips the
    ///     screenshot-protection switch; the host applies it to the island.
    init(
        displayPicker: DisplayPickerViewModel,
        volumeDuckConfig: VolumeDuckConfig? = nil,
        islandIdlePreferences: IslandIdlePreferences? = nil,
        meetingsEnabled: @escaping () -> Bool = { false },
        googleEnabled: @escaping () -> Bool = { false },
        onMeetingsToggle: @escaping (Bool) -> Void = { _ in },
        onGoogleToggle: @escaping (Bool) -> Void = { _ in },
        privacyPreferences: PrivacyPreferences? = nil,
        screenshotProtectionChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.displayPicker = displayPicker
        let resolvedDucking = volumeDuckConfig ?? VolumeDuckConfig()
        self.volumeDuckConfig = resolvedDucking
        let resolvedIdlePrefs = islandIdlePreferences ?? IslandIdlePreferences()
        self.islandIdlePreferences = resolvedIdlePrefs
        self.meetingsEnabledProvider = meetingsEnabled
        self.googleEnabledProvider = googleEnabled
        self.onMeetingsToggle = onMeetingsToggle
        self.onGoogleToggle = onGoogleToggle
        let resolvedPrivacy = privacyPreferences ?? .shared
        self.privacyPreferences = resolvedPrivacy
        self.screenshotProtectionChanged = screenshotProtectionChanged
        _screenshotProtectionEnabled = State(initialValue: resolvedPrivacy.screenshotProtectionEnabled)
        _volumeDuckEnabled = State(initialValue: resolvedDucking.isEnabled)
        _islandAutoHideEnabled = State(initialValue: resolvedIdlePrefs.isEnabled)
        _meetingsEnabled = State(initialValue: meetingsEnabled())
        _googleEnabled = State(initialValue: googleEnabled())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Recording")
                    MacCard {
                        MacRow(
                            title: "Lower other audio while speaking",
                            subtitle: "Lowers built-in-speaker volume while you record voice, restores after. External outputs (USB/Bluetooth DACs) are never touched."
                        ) {
                            MacSwitch(isOn: volumeDuckToggleBinding, label: "Lower other audio while speaking")
                        }

                        MacRowSeparator()
                        MacRow(
                            title: "Stop Drop automatically",
                            subtitle: "With a Toggle shortcut: press once, speak, and dictation ends when you stop. Press again to stop sooner. Hold shortcuts are unchanged."
                        ) {
                            MacSwitch(isOn: dropAutoStopToggleBinding, label: "Stop Drop automatically")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Features")
                    MacCard {
                        MacRow(
                            title: "Meeting Notes",
                            subtitle: "Detect calls, record, and summarize. Off until you turn it on."
                        ) {
                            MacSwitch(isOn: meetingsToggleBinding, label: "Meeting Notes")
                        }

                        MacRowSeparator()
                        MacRow(
                            title: "Google search",
                            subtitle: "Right Option searches your selection on Google."
                        ) {
                            MacSwitch(isOn: googleToggleBinding, label: "Google search")
                        }

                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Privacy")
                    MacCard {
                        MacRow(
                            title: "Screenshot protection",
                            subtitle: "Hide the island from screenshots and screen shares."
                        ) {
                            MacSwitch(isOn: screenshotProtectionToggleBinding, label: "Screenshot protection")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Display")
                    MacCard {
                        MacRow(
                            title: "Auto-hide island",
                            subtitle: "Fades into the notch after a while of no use. Hover it or press a hotkey to bring it back."
                        ) {
                            MacSwitch(isOn: islandAutoHideToggleBinding, label: "Auto-hide island")
                        }

                        MacRowSeparator()
                        MacRow(
                            title: "Show island on",
                            subtitle: "Automatic picks the screen with the notch, else your primary display."
                        ) {
                            MacPopup(
                                items: displayPicker.options.map {
                                    .init(value: $0.value, label: $0.label)
                                },
                                selection: Binding(
                                    get: { displayPicker.selection },
                                    set: { displayPicker.selection = $0 }
                                )
                            )
                            .accessibilityLabel("Show island on")
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            // Re-read live values so a tab revisit (SwiftUI recreates this view)
            // never shows a stale toggle state.
            volumeDuckEnabled = volumeDuckConfig.isEnabled
            dropAutoStopEnabled = DropAutoStopPreferences.shared.isEnabled
            islandAutoHideEnabled = islandIdlePreferences.isEnabled
            meetingsEnabled = meetingsEnabledProvider()
            googleEnabled = googleEnabledProvider()
            screenshotProtectionEnabled = privacyPreferences.screenshotProtectionEnabled
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .sidekeyCapabilityFlagsChanged)
        ) { _ in
            // Capability flags can flip while this tab is OPEN — accepting the
            // ⌥M enable nudge writes Meetings ON from outside Settings, and
            // hydration can rewrite either flag. Without this the toggles
            // sit stale until a tab revisit.
            meetingsEnabled = meetingsEnabledProvider()
            googleEnabled = googleEnabledProvider()
        }
        .onReceive(NotificationCenter.default.publisher(for: IslandIdlePreferences.didChangeNotification)) { _ in
            islandAutoHideEnabled = islandIdlePreferences.isEnabled
        }
    }

    /// Binding: persists to `DropAutoStopPreferences`; read when a take starts.
    private var dropAutoStopToggleBinding: Binding<Bool> {
        Binding(
            get: { dropAutoStopEnabled },
            set: { newValue in
                dropAutoStopEnabled = newValue
                DropAutoStopPreferences.shared.isEnabled = newValue
            }
        )
    }

    /// Binding: persists to `VolumeDuckConfig` on every flip. The volume-duck
    /// controller reads the flag fresh on every update, so no live push needed.
    private var volumeDuckToggleBinding: Binding<Bool> {
        Binding(
            get: { volumeDuckEnabled },
            set: { newValue in
                volumeDuckEnabled = newValue
                volumeDuckConfig.isEnabled = newValue
            }
        )
    }

    /// Binding: persists to `IslandIdlePreferences` on every flip. The setter
    /// posts `didChangeNotification`, which the host observes to poke the live
    /// `IslandIdleController` — so a disable un-hides the island at once and an
    /// enable starts a fresh idle window, no view→controller wire needed.
    private var islandAutoHideToggleBinding: Binding<Bool> {
        Binding(
            get: { islandAutoHideEnabled },
            set: { newValue in
                islandAutoHideEnabled = newValue
                islandIdlePreferences.isEnabled = newValue
            }
        )
    }

    /// Binding: persists to `PrivacyPreferences` and lets the host apply the
    /// new value to the live island window.
    private var screenshotProtectionToggleBinding: Binding<Bool> {
        Binding(
            get: { screenshotProtectionEnabled },
            set: { newValue in
                screenshotProtectionEnabled = newValue
                privacyPreferences.screenshotProtectionEnabled = newValue
                screenshotProtectionChanged(newValue)
            }
        )
    }

    /// Binding: routes through the host-supplied closure so the host can write
    /// the cache without this view depending on the cache directly.
    private var meetingsToggleBinding: Binding<Bool> {
        Binding(
            get: { meetingsEnabled },
            set: { newValue in
                meetingsEnabled = newValue
                onMeetingsToggle(newValue)
            }
        )
    }

    /// Binding: routes through the host-supplied closure (same pattern as
    /// `meetingsToggleBinding`).
    private var googleToggleBinding: Binding<Bool> {
        Binding(
            get: { googleEnabled },
            set: { newValue in
                googleEnabled = newValue
                onGoogleToggle(newValue)
            }
        )
    }
}
