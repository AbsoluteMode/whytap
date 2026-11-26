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
    /// Opens a tab that is no longer in the sidebar (More).
    private let open: (SettingsWindowTab) -> Void

    @State private var islandAutoHideEnabled: Bool
    @State private var screenshotProtectionEnabled: Bool

    init(
        displayPicker: DisplayPickerViewModel,
        islandIdlePreferences: IslandIdlePreferences? = nil,
        privacyPreferences: PrivacyPreferences? = nil,
        screenshotProtectionChanged: @escaping (Bool) -> Void = { _ in },
        open: @escaping (SettingsWindowTab) -> Void = { _ in }
    ) {
        self.open = open
        self.displayPicker = displayPicker
        let resolvedIdlePrefs = islandIdlePreferences ?? IslandIdlePreferences()
        self.islandIdlePreferences = resolvedIdlePrefs
        let resolvedPrivacy = privacyPreferences ?? .shared
        self.privacyPreferences = resolvedPrivacy
        self.screenshotProtectionChanged = screenshotProtectionChanged
        _screenshotProtectionEnabled = State(initialValue: resolvedPrivacy.screenshotProtectionEnabled)
        _islandAutoHideEnabled = State(initialValue: resolvedIdlePrefs.isEnabled)
    }

    /// Tabs that left the sidebar and open from General.
    static let moreRows: [(title: String, subtitle: String, tab: SettingsWindowTab)] = [
        ("Backup", "Encrypted backups of your keys and settings, to restore or move to another Mac.", .backup),
        ("Integrations", "Connect GitHub, where your encrypted backups are kept.", .integrations),
    ]

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
                    Text("The island itself, your privacy and the rest of Whytap. Each feature’s own settings are on its screen in Features.")
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

                // WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "More")
                    MacCard {
                        ForEach(Array(Self.moreRows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { MacRowSeparator() }
                            MacRow(title: row.title, subtitle: row.subtitle) {
                                MacButton(title: "Open", style: .ghost) { open(row.tab) }
                                    .fixedSize()
                                    .accessibilityLabel("Open \(row.title)")
                            }
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
