import Foundation

/// Shows settings that arrived from another Mac without a relaunch. Most
/// preferences are read from UserDefaults on every use; the stores below keep
/// their own copy and reload it here. Provider keys are read from the Keychain
/// on every request, so they need nothing.
// WHY: .project-docs/decisions/2026-11-20-settings-sync.md
@MainActor
enum SettingsSyncLiveReload {
    static func reload(items: Set<String>, defaults: UserDefaults = .standard) {
        // The Tavily key decides the Agent's search and the Models → Search row.
        if items.compactMap(SettingsSyncItem.secretAccount).contains(TavilySearch.keychainAccount) {
            NotificationCenter.default.post(name: .whytapTavilyKeyChanged, object: nil)
        }
        let keys = Set(items.compactMap(SettingsSyncItem.preferenceKey))
        guard !keys.isEmpty else { return }
        if keys.contains(AgentSettingsStore.webSearchChoiceKey) { AgentSettingsStore.shared.reloadWebSearchChoice() }
        if keys.contains(ConfigBackupRegistry.aiRoutingKey) { AIRoutingStore.shared.reloadFromDefaults() }
        if keys.contains(where: { $0.hasPrefix("hotkeys.") }) { HotkeyPreferences.shared.reloadFromDefaults() }
        if keys.contains(HoverLayoutStore.defaultsKey) { HoverLayoutStore.shared.reloadFromDefaults() }
        if keys.contains("notifications.sourceSounds") { NotificationSoundSettings.shared.reloadFromDefaults() }
        if keys.contains(BrightnessKeys.defaultsKey) {
            BrightnessKeys.shared.setEnabled(defaults.bool(forKey: BrightnessKeys.defaultsKey))
        }
        if keys.contains("sidekey.preferences.hideHelpers") || keys.contains("sidekey.preferences.hideIslandHoverWidgets") {
            DisplayPreferences.shared.reloadFromDefaults()
        }
        if keys.contains("sidekey.preferences.transcriptionMode") {
            NotificationCenter.default.post(name: .sidekeyDropModeChanged, object: nil)
        }
        if keys.contains(where: { ["sidekey.preferences.agentEnabled", "sidekey.preferences.meetingsEnabled",
                                    "sidekey.preferences.googleEnabled"].contains($0) }) {
            NotificationCenter.default.post(name: .sidekeyCapabilityFlagsChanged, object: nil)
        }
        if keys.contains(IslandIdlePreferences.isEnabledDefaultsKey) {
            NotificationCenter.default.post(name: IslandIdlePreferences.didChangeNotification, object: nil)
        }
    }
}
