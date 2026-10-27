import AppKit
import SwiftUI

@MainActor
struct NotifyHoverPanel: View {
    @ObservedObject var hub: LocalNotificationHub
    @ObservedObject var supervisor: NotifyScriptSupervisor
    @ObservedObject var meetingNotifications: MeetingReadyNotifications
    let onBack: () -> Void
    let showsBackButton: Bool
    @State private var showsSources = false
    @State private var pendingRemoval: String?

    init(hub: LocalNotificationHub? = nil, supervisor: NotifyScriptSupervisor? = nil,
         meetingNotifications: MeetingReadyNotifications? = nil,
         showsBackButton: Bool = true, onBack: @escaping () -> Void) {
        self.hub = hub ?? .shared; self.supervisor = supervisor ?? .shared; self.onBack = onBack; self.showsBackButton = showsBackButton
        self.meetingNotifications = meetingNotifications ?? .shared
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Group {
                    if showsBackButton {
                        IslandHoverBackButton(destination: "notify", action: onBack)
                    }
                    else { Color.clear.frame(height: 1) }
                }.frame(width: 68, alignment: .leading)
                Text("Notify").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
                Button {
                    if showsSources { NSWorkspace.shared.open(NotifyPaths.root) }
                    else { Task { await hub.clear() } }
                } label: {
                    if showsSources { Image(systemName: "folder") }
                    else { Text("Clear All") }
                }
                .buttonStyle(.plain).frame(width: 68, alignment: .trailing)
                .disabled(!showsSources && hub.history.isEmpty)
                .accessibilityLabel(showsSources ? "Open notification sources folder" : "Clear all notifications")
            }
            .font(.system(size: 11, weight: .medium)).frame(height: 24)
            HStack(spacing: 2) {
                sectionButton("History", selected: !showsSources) { showsSources = false }
                sectionButton("Sources", selected: showsSources) { showsSources = true }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.24)))


            if let error = hub.error ?? supervisor.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    if showsSources {
                        HStack(spacing: 7) {
                            NotificationSourceIcon(glyph: .brandImage(name: "whytap"), tint: Color(hexCSS: "#785EFF"))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Meeting notes").font(.system(size: 11, weight: .semibold))
                                Text("When your notes are ready").font(.system(size: 9)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("Enable meeting notes notifications", isOn: $meetingNotifications.enabled)
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.12, green: 0.12, blue: 0.14)))
                        if supervisor.sources.isEmpty {
                            empty("No other sources yet", detail: "Ask your agent to connect more notifications.")
                        }
                        ForEach(supervisor.sources) { source in sourceRow(source) }
                    } else {
                        if hub.history.isEmpty { empty("No notifications yet", detail: "Notifications from your sources appear here.") }
                        ForEach(hub.history) { event in historyRow(event) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .foregroundStyle(Color.white)
        .environment(\.colorScheme, .dark)
        .task(id: hub.history.first?.id) { if !showsSources { await hub.markRead() } }
        .onChange(of: showsSources) { _, value in if !value { Task { await hub.markRead() } } }
        .confirmationDialog("Remove this notification source?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Remove source", role: .destructive) { if let id = pendingRemoval { supervisor.remove(id: id) }; pendingRemoval = nil }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { Text("Its script will stop. Notification history and script files will be kept.") }
    }
    private func sectionButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(Color.white.opacity(selected ? 1 : 0.6))
                .frame(maxWidth: .infinity).frame(height: 23)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(selected ? 0.14 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "bell").font(.system(size: 24)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(.vertical, 14).frame(maxWidth: .infinity)
    }
    private func historyRow(_ event: LocalNotificationEvent) -> some View {
        Button {
            hub.activate(event)
        } label: {
            HStack(spacing: 8) {
                NotificationSourceIcon(glyph: IslandNotificationPill.resolvedGlyph(for: event),
                                       tint: IslandNotificationPill.resolvedTint(for: event), size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(event.body.isEmpty ? event.sourceName : event.body)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(event.timestamp, style: .relative).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 48)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.12, green: 0.12, blue: 0.14)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!event.canActivate)
        .opacity(1)
        .accessibilityLabel("\(event.sourceName), \(event.title), \(event.body)")
        .contextMenu { Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(event.title + "\n" + event.body, forType: .string) } }
    }
    private func sourceRow(_ source: NotifySourceStatus) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "bell.badge").foregroundStyle(Color(hexCSS: source.script.tint ?? "#299FD6"))
            VStack(alignment: .leading, spacing: 2) {
                Text(source.script.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(source.message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Enabled", isOn: Binding(get: { source.script.enabled }, set: { supervisor.setEnabled($0, id: source.id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .accessibilityLabel("Enable \(source.script.name)")
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.12, green: 0.12, blue: 0.14)))
        .contextMenu { Button("Remove source…", role: .destructive) { pendingRemoval = source.id } }
    }
}
