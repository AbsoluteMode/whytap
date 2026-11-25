import SwiftUI

/// Settings → General (the tab whose raw id is still `other`, so
/// `whytap://settings/other` keeps working).
///
/// What is left once every feature has its own screen in Features: the
/// island itself (auto-hide, which display) and screenshot protection. Drop's
/// switches, Meeting Notes, Google search and the Agent moved to their
/// feature screens.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
@MainActor
struct SettingsOtherView: View {
    /// Injected (the host owns it as `@StateObject`) so the options list
    /// survives this view's re-inits on tab switches.
    @ObservedObject private var displayPicker: DisplayPickerViewModel
    /// Injected on/off switch for the island idle auto-hide. Writing it posts
    /// `IslandIdlePreferences.didChangeNotification`, which the host observes to
    /// poke the live `IslandIdleController`.
    private let islandIdlePreferences: IslandIdlePreferences
    /// Backing store for the screenshot-protection toggle.
    private let privacyPreferences: PrivacyPreferences
    /// Applies the toggle to the live island panel (host-wired).
    private let screenshotProtectionChanged: (Bool) -> Void

    @State private var islandAutoHideEnabled: Bool
    /// Settings → General → Display → "Island position". WHY:
    /// .project-docs/decisions/2026-11-22-island-beside-system-island.md
    @State private var systemIslandPlacement = IslandSystemIslandPlacement.current()

    @State private var screenshotProtectionEnabled: Bool

    init(
        displayPicker: DisplayPickerViewModel,
        islandIdlePreferences: IslandIdlePreferences? = nil,
        privacyPreferences: PrivacyPreferences? = nil,
        screenshotProtectionChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.displayPicker = displayPicker
        let resolvedIdlePrefs = islandIdlePreferences ?? IslandIdlePreferences()
        self.islandIdlePreferences = resolvedIdlePrefs
        let resolvedPrivacy = privacyPreferences ?? .shared
        self.privacyPreferences = resolvedPrivacy
        self.screenshotProtectionChanged = screenshotProtectionChanged
        _screenshotProtectionEnabled = State(initialValue: resolvedPrivacy.screenshotProtectionEnabled)
        _islandAutoHideEnabled = State(initialValue: resolvedIdlePrefs.isEnabled)
    }

    /// The clip shows an example combo; the popover names the user's own.
    static func dropAutoStopVideoShortcuts(_ configuration: HotkeyConfiguration) -> [FeatureVideoShortcut] {
        [FeatureVideoShortcut(label: "Drop", contents: configuration.dropVoiceShortcut.contents)]
    }

    static func googleSearchVideoShortcuts(_ configuration: HotkeyConfiguration) -> [FeatureVideoShortcut] {
        [FeatureVideoShortcut(label: "Text", contents: configuration.googleSearchTextShortcut.contents),
         FeatureVideoShortcut(label: "Voice", contents: configuration.googleSearchVoiceShortcut.contents)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("General")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                        .accessibilityAddTraits(.isHeader)
                    Text("The island itself and your privacy. Each feature’s own settings are on its screen in Features.")
                        .font(.system(size: 13))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Island")
                    MacCard {
                        MacRow(
                            title: "Auto-hide island",
                            subtitle: "Fades into the notch after a while of no use. Hover it or press a hotkey to bring it back."
                        ) {
                            FeatureVideoButton(video: .autoHide)
                        } trailing: {
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

                        MacRowSeparator()
                        MacRow(
                            title: "Island position",
                            subtitle: "Automatic keeps the camera area free for the system Dynamic Island on a touch MacBook Pro."
                        ) {
                            MacPopup(
                                items: IslandSystemIslandPlacement.allCases.map {
                                    .init(value: $0, label: $0.title)
                                },
                                selection: Binding(
                                    get: { systemIslandPlacement },
                                    set: { newValue in
                                        systemIslandPlacement = newValue
                                        IslandSystemIslandPlacement.set(newValue)
                                    }
                                )
                            )
                            .accessibilityLabel("Island position")
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
                            FeatureVideoButton(video: .screenshotProtection)
                        } trailing: {
                            MacSwitch(isOn: screenshotProtectionToggleBinding, label: "Screenshot protection")
                        }
                    }
                }
            }
            .frame(maxWidth: SettingsFeaturesView.contentWidth, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear {
            // Re-read live values so a tab revisit (SwiftUI recreates this view)
            // never shows a stale toggle state.
            islandAutoHideEnabled = islandIdlePreferences.isEnabled
            systemIslandPlacement = IslandSystemIslandPlacement.current()
            screenshotProtectionEnabled = privacyPreferences.screenshotProtectionEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: IslandIdlePreferences.didChangeNotification)) { _ in
            islandAutoHideEnabled = islandIdlePreferences.isEnabled
        }
    }

    /// Binding: persists to `IslandIdlePreferences` on every flip. The setter
    /// posts `didChangeNotification`, which the host observes to poke the live
    /// `IslandIdleController`.
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
}
