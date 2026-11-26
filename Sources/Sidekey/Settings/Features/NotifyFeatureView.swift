import SwiftUI

/// Settings -> Features -> Notify: what Notify does, its shortcut, the
/// sources with their switches and sounds, and Copy prompt, which hands a
/// coding agent everything it needs to connect a new source on this Mac.
// WHY: .project-docs/decisions/2026-11-24-hover-notify-monitor-screens.md
@MainActor
struct NotifyFeatureView: View {
    @ObservedObject var selection: SettingsWindowSelection
    @ObservedObject private var supervisor: NotifyScriptSupervisor
    @StateObject private var shortcut: FeatureShortcutEditor
    private let environment: FeaturesEnvironment

    init(selection: SettingsWindowSelection, environment: FeaturesEnvironment) {
        self.selection = selection
        self.environment = environment
        self.supervisor = environment.notifySupervisor
        _shortcut = StateObject(wrappedValue: FeatureShortcutEditor(hotkey: .tool(.notifs),
                                                                    preferences: environment.hotkeys))
    }

    static let about = "Cards to the left of the island from sources you choose: a finished build, a new pull request, "
        + "a message, a server check. Your coding agent connects a source as a small script on this Mac. "
        + "Whytap shows its cards and keeps the 500 newest in Notify; there is no notification server."

    static let promptText = "Copy the prompt, paste it into your coding agent and say what you want to hear about. "
        + "It writes a small local script, and the source appears under Connected sources with its own switch and sound."

    var body: some View {
        let info = FeatureCatalog.info(for: .notify)
        FeatureScreenScaffold {
            FeatureScreenHeader(info: info, about: Self.about) {
                selection.shownFeature = nil
            }
            FeatureVideoStrip(info: info)
            shortcutGroup
            // Nothing connected yet: the way to connect comes first.
            if supervisor.sources.isEmpty {
                promptCard
                sources
            } else {
                sources
                promptCard
            }
            Text("Click the speaker to choose a sound and hear it; crossed out means silent. Clicking a meeting card "
                 + "opens its notes. Cards appear while Whytap is open. Turning a source off keeps its setup and history.")
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { shortcut.cancel() }
    }

    private var shortcutGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Shortcut")
            MacCard {
                FeatureShortcutRow(editor: shortcut, detail: "Opens Notify in the island: your history and sources.")
                MacRowSeparator()
                MacRow(title: "Notify in the island", subtitle: "History of what arrived, Clear All and the sources.") {
                    MacButton(title: "Open") { environment.openHoverPanel(.notifications) }
                        .fixedSize()
                        .accessibilityLabel("Open Notify in the island")
                }
            }
        }
    }

    private var sources: some View {
        NotificationSourcesGroups(supervisor: supervisor,
                                  meetingNotifications: environment.meetingNotifications,
                                  soundSettings: environment.notificationSounds,
                                  imageLoader: { NotifyLogoStore.image(named: $0) },
                                  emptyText: "Copy the prompt into your coding agent to connect one.")
    }

    private var promptCard: some View {
        CodingAgentPromptCard(title: "Add your own", text: Self.promptText,
                              prompt: CodingAgentPrompt.notify(root: environment.notifyRoot),
                              copy: environment.copyText)
    }
}
