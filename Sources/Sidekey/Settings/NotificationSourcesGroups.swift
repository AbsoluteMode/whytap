import SwiftUI

/// The sources Notify shows, each with its switch and sound: the built-in
/// Meeting notes and the ones a coding agent connected. Shown on the Notify
/// screen in Features, the one place for notification settings.
// WHY: .project-docs/decisions/2026-11-26-notifications-in-notify.md
@MainActor
struct NotificationSourcesGroups: View {
    @ObservedObject var supervisor: NotifyScriptSupervisor
    @ObservedObject var meetingNotifications: MeetingReadyNotifications
    @ObservedObject var soundSettings: NotificationSoundSettings
    let imageLoader: (String) -> NSImage?
    var emptyText = "Ask your agent to connect the notifications you want."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = supervisor.error {
                MacBanner(tone: .warn, systemImage: "exclamationmark.triangle", text: error)
            }

            VStack(alignment: .leading, spacing: 0) {
                MacGroupTitle(title: "Built-in")
                MacCard {
                    MacRow(title: "Meeting notes", subtitle: "Notify me when my meeting notes are ready") {
                        NotificationSourceIcon(glyph: .brandImage(name: "whytap"),
                                               tint: Color(hexCSS: "#785EFF"), size: 28, imageLoader: imageLoader)
                            .accessibilityHidden(true)
                    } trailing: {
                        HStack(spacing: 10) {
                            NotificationSoundControl(settings: soundSettings, sourceID: MeetingReadyNotifications.sourceID,
                                                     sourceName: "meeting notes")
                            MacSwitch(isOn: $meetingNotifications.enabled, label: "Meeting-ready notifications")
                                .accessibilityLabel("Enable meeting notes notifications")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                MacGroupTitle(title: "Connected sources")
                MacCard {
                    if supervisor.sources.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "bell")
                                .font(.system(size: 26))
                                .foregroundStyle(MacSettingsTheme.text2)
                            Text("No sources connected")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(MacSettingsTheme.text)
                            Text(emptyText)
                                .font(.system(size: 12))
                                .foregroundStyle(MacSettingsTheme.text2)
                                .multilineTextAlignment(.center)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(supervisor.sources) { source in
                            if source.id != supervisor.sources.first?.id { MacRowSeparator() }
                            MacRow(title: source.script.name, subtitle: source.message) {
                                NotificationSourceIcon(
                                    glyph: NotifyLogoStore.resolve(logo: source.script.logo, source: source.script.name),
                                    tint: Color(hexCSS: source.script.tint ?? "#299FD6"), size: 28
                                )
                                .accessibilityHidden(true)
                            } trailing: {
                                HStack(spacing: 10) {
                                    NotificationSoundControl(settings: soundSettings, sourceID: source.id,
                                                             sourceName: source.script.name)
                                    MacSwitch(isOn: Binding(
                                        get: { supervisor.sources.first(where: { $0.id == source.id })?.script.enabled ?? false },
                                        set: { supervisor.setEnabled($0, id: source.id) }
                                    ))
                                    .accessibilityLabel("Enable \(source.script.name)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
