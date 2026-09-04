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
/// `OnboardingSkillsScreen`.
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
    /// Fires the manual meeting-record toggle (same path as the ⌥M hotkey
    /// and the hover "Record" tile). The host wires the coordinator call.
    private let onMeetingRecordToggle: () -> Void
    /// Backing store for the screenshot-protection toggle.
    private let privacyPreferences: PrivacyPreferences
    /// Applies the toggle to the live island panel (host-wired).
    private let screenshotProtectionChanged: (Bool) -> Void

    /// Live recording state for the Start/Stop button label —
    /// `meetingRecordingActive` is already published on `AppState` by the
    /// recording pill pipeline.
    @ObservedObject private var appState = AppState.shared

    /// Local mirror of the volume-duck flag. Seeded from `volumeDuckConfig`
    /// on init and re-read on appear; written back on every toggle.
    @State private var volumeDuckEnabled: Bool

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
        onMeetingRecordToggle: @escaping () -> Void = {},
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
        self.onMeetingRecordToggle = onMeetingRecordToggle
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
                            MacSwitch(isOn: volumeDuckToggleBinding)
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
                            MacSwitch(isOn: meetingsToggleBinding)
                        }

                        MacRow(
                            title: "Google search",
                            subtitle: "Right Option searches your selection on Google."
                        ) {
                            MacSwitch(isOn: googleToggleBinding)
                        }

                        MacRow(
                            title: "Record a meeting now",
                            subtitle: "Start recording anytime — even mid-call; press again to stop."
                        ) {
                            Button(appState.meetingRecordingActive ? "Stop" : "Start") {
                                onMeetingRecordToggle()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!meetingsEnabled)
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
                            MacSwitch(isOn: screenshotProtectionToggleBinding)
                        }
                    }
                    MacBanner(
                        tone: .privacy,
                        systemImage: "lock.shield",
                        text: "Audio and text are processed on this Mac or sent only to the providers you configure with your own keys."
                    )
                }

                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Display")
                    MacCard {
                        MacRow(
                            title: "Auto-hide island",
                            subtitle: "Fades into the notch after a while of no use. Hover it or press a hotkey to bring it back."
                        ) {
                            MacSwitch(isOn: islandAutoHideToggleBinding)
                        }

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
            // hydration can rewrite either flag. Without this the toggle (and
            // the capability-gated Start button) sit stale until a tab
            // revisit.
            meetingsEnabled = meetingsEnabledProvider()
            googleEnabled = googleEnabledProvider()
        }
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
