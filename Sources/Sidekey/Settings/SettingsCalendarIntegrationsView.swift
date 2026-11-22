import AppKit
import SwiftUI

struct SettingsCalendarIntegrationsView: View {
    @ObservedObject var connections: CalendarConnections
    var readiness: (CalendarProvider) -> CalendarConnectionReadiness = {
        .shared($0, configuration: CalendarClientConfiguration.registered($0))
    }
    @StateObject private var flow: CalendarConnectionFlow
    private let configurationInfo: [String: Any]?

    init(connections: CalendarConnections,
         readiness: @escaping (CalendarProvider) -> CalendarConnectionReadiness = {
             .shared($0, configuration: CalendarClientConfiguration.registered($0))
         }, configurationInfo: [String: Any]? = Bundle.main.infoDictionary, flow: CalendarConnectionFlow? = nil) {
        self.connections = connections; self.readiness = readiness; self.configurationInfo = configurationInfo
        self._flow = StateObject(wrappedValue: flow ?? CalendarConnectionFlow(connections: connections))
    }

    var body: some View {
        if CalendarAvailability.isOpen { openBody } else { CalendarComingSoonCard() }
    }

    private var openBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendars").font(.system(size: 15, weight: .semibold))
            Text("Connect the feature you need. Each connection requests its own permissions.")
                .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let message = connections.accountConnectionIssue {
                Text(message).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = connections.connectionBlockReason {
                Text(message).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach([CalendarProvider.google, .microsoft, .apple, .zoom]) { provider in
                CalendarIntegrationCard(provider: provider, connections: connections,
                    readiness: readiness(provider), flow: flow,
                    onConnect: { flow.startRegistered(provider: provider, info: configurationInfo) })
            }
            IntegrationLink(title: "Calendar privacy", destination: URL(string: "https://whytap.ai/calendar-privacy/")!)
                .font(.system(size: 11))
        }
        .background(CalendarConnectionWindowClose(onClose: flow.cancel).frame(width: 0, height: 0))
        .onDisappear { flow.cancel() }
        .onChange(of: flow.error) { _, error in
            guard let error else { return }
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}

/// Settings retains its root view when its window closes; onDisappear alone is insufficient.
private struct CalendarConnectionWindowClose: NSViewRepresentable {
    let onClose: () -> Void
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) { view.onClose = onClose }

    final class Observer: NSView {
        var onClose: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)),
                    name: NSWindow.willCloseNotification, object: window)
            }
        }
        @objc private func windowClosing(_ notification: Notification) { onClose?() }
    }
}

private struct CalendarIntegrationCard: View {
    let provider: CalendarProvider
    @ObservedObject var connections: CalendarConnections
    let readiness: CalendarConnectionReadiness
    @ObservedObject var flow: CalendarConnectionFlow
    private var available: Bool { readiness == .available }
    let onConnect: () -> Void
    @State private var removing: ConnectedCalendarAccount?
    @State private var disconnecting = false
    @State private var error: String?

    private var accounts: [ConnectedCalendarAccount] { connections.accounts.filter { $0.provider == provider } }
    private var connected: Bool { provider == .apple ? connections.appleEnabled : !accounts.isEmpty }
    private var busy: Bool { disconnecting || connections.isConnecting || connections.connectionBlockReason != nil }
    private var actionTitle: String { available ? (connected ? "Add account" : "Connect") : "Unavailable" }
    private var status: String {
        if disconnecting { return "Disconnecting…" }
        if connections.connectingProvider == provider { return "Sign-in in progress…" }
        if provider != .apple && connections.errors["accounts"] != nil { return "Connections unavailable" }
        if connected { return "Connected" }
        if !available { return readiness.status }
        return "Not connected"
    }

    var body: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.integrationTitle).font(.system(size: 13, weight: .semibold))
                        Text(status).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.text2)
                    }
                    Spacer(minLength: 8)
                    if flow.working && flow.lastProvider == provider {
                        IntegrationAction(title: "Cancel") { flow.cancel() }
                    } else if provider == .apple && connected {
                        IntegrationAction(title: "Disconnect", enabled: !busy) { confirmAppleDisconnect() }
                    } else {
                        IntegrationAction(title: actionTitle,
                            primary: !connected, enabled: available && !busy && (provider == .apple || connections.accountConnectionIssue == nil), action: onConnect)
                            .accessibilityLabel("\(actionTitle) · \(provider.integrationTitle)")
                            .accessibilityHint(readiness.message ?? connections.connectionBlockReason ?? connections.accountConnectionIssue ?? "")
                    }
                }
                Text(provider.permissionSummary).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if !available {
                    Text(readiness.message ?? "")
                        .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if provider == .apple, let message = connections.errors["apple"] {
                    Text(message).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if provider == .apple, connections.appleAccessOff {
                    IntegrationAction(title: "Open Privacy Settings") { PermissionsHelper.openCalendarsSettings() }
                        .accessibilityHint("Opens System Settings → Privacy & Security → Calendars")
                }
                ForEach(accounts) { account in
                    HStack(spacing: 12) {
                        Text(account.label).font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        IntegrationAction(title: "Disconnect", enabled: !busy) { removing = account }
                            .accessibilityLabel("Disconnect \(account.label) from \(provider.integrationTitle)")
                    }
                    if let message = connections.errors[account.id.uuidString] {
                        Text(message).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.orange) }
                if flow.lastProvider == provider, let error = flow.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(14)
        }
        .alert("Disconnect \(provider.integrationTitle)?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
                Button("Cancel", role: .cancel) { removing = nil }
                Button("Disconnect", role: .destructive) {
                    guard connections.beginConnecting(provider: provider) else {
                        error = connections.connectionBlockReason ?? "Finish the other calendar operation first."
                        removing = nil
                        return
                    }
                    removing = nil; disconnecting = true; error = nil
                    Task {
                        defer { disconnecting = false; connections.endConnecting() }
                        do {
                            if provider == .apple { connections.disableApple() }
                            else { try await connections.remove(account) }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            } message: { _ in Text("This removes this calendar connection from Whytap. Your events are kept in the source calendar.") }
    }

    private func confirmAppleDisconnect() {
        removing = ConnectedCalendarAccount(id: UUID(), provider: .apple, label: provider.title)
    }
}

/// Calendar is closed: the section stays visible with a "Soon" plaque and an
/// inactive Connect button. Nothing here signs in, asks macOS for access or
/// reads a calendar. Stored connections are kept and work again when the
/// switch in `CalendarAvailability` is opened.
// WHY: .project-docs/decisions/2026-11-21-calendar-soon.md
struct CalendarComingSoonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Calendars").font(.system(size: 15, weight: .semibold))
                SettingsSoonBadge(text: CalendarAvailability.badge)
            }
            MacCard {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Google, Outlook, Apple and Zoom calendars").font(.system(size: 13, weight: .semibold))
                        Text(CalendarAvailability.message)
                            .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    IntegrationAction(title: "Connect", enabled: false) {}
                        .accessibilityHint(CalendarAvailability.message)
                }.padding(14)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The "Soon" plaque in Settings, in the Toolbox badge's capsule style.
struct SettingsSoonBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MacSettingsTheme.text2)
            .padding(.horizontal, 7)
            .frame(minHeight: 16)
            .background(
                Capsule()
                    .fill(MacSettingsTheme.hover)
                    .overlay(Capsule().strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5))
            )
            .accessibilityLabel(text)
    }
}
