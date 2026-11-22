import AppKit
import SwiftUI

/// Settings → Integrations → Calendars: Calendar on this Mac is the one way to
/// connect calendars; Google, Outlook and the rest come through Internet
/// Accounts. Accounts connected directly by an earlier build keep working and
/// are listed with Disconnect; the direct sign-in code stays but is not offered.
// WHY: .project-docs/decisions/2026-11-23-calendar-macos-only.md
struct SettingsCalendarIntegrationsView: View {
    @ObservedObject var connections: CalendarConnections
    @StateObject private var flow: CalendarConnectionFlow
    private let configurationInfo: [String: Any]?
    @State private var removing: ConnectedCalendarAccount?
    @State private var confirmingAppleDisconnect = false
    @State private var error: String?

    init(connections: CalendarConnections, configurationInfo: [String: Any]? = Bundle.main.infoDictionary,
         flow: CalendarConnectionFlow? = nil) {
        self.connections = connections; self.configurationInfo = configurationInfo
        self._flow = StateObject(wrappedValue: flow ?? CalendarConnectionFlow(connections: connections))
    }

    var body: some View {
        if CalendarAvailability.isOpen { openBody } else { CalendarComingSoonCard() }
    }

    private var busy: Bool { connections.isConnecting || connections.connectionBlockReason != nil }

    private var openBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendars").font(.system(size: 15, weight: .semibold))
            Text("Whytap shows the calendars of this Mac and only reads them. Add Google, Outlook and other accounts in System Settings → Internet Accounts; they appear here.")
                .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let message = connections.connectionBlockReason {
                warning(message)
            }
            MacCard { macCard.padding(14) }
            if !connections.accounts.isEmpty || connections.errors["accounts"] != nil {
                MacCard { directCard.padding(14) }
            }
            if let error { warning(error) }
            HStack(spacing: 8) {
                IntegrationAction(title: "Open Internet Accounts") { PermissionsHelper.openInternetAccountsSettings() }
                    .accessibilityHint("Opens System Settings → Internet Accounts")
                IntegrationLink(title: "Calendar privacy", destination: URL(string: "https://whytap.ai/calendar-privacy/")!)
            }.font(.system(size: 11))
        }
        .background(CalendarConnectionWindowClose(onClose: flow.cancel).frame(width: 0, height: 0))
        // Settings shows the live permission, not what Calendar saw last
        // (status only: no prompt, no event read).
        .onAppear { recheckAppleAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheckAppleAccess()
        }
        .onDisappear { flow.cancel() }
        .onChange(of: flow.error) { _, error in
            guard let error else { return }
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        .alert("Disconnect calendars of this Mac?", isPresented: $confirmingAppleDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { connections.disableApple() }
        } message: { Text("Whytap stops showing them. Your calendars and macOS access stay as they are.") }
        .alert("Disconnect \(removing?.label ?? "account")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
                Button("Cancel", role: .cancel) { removing = nil }
                Button("Disconnect", role: .destructive) { disconnect(account) }
            } message: { _ in Text("This removes the direct connection from Whytap. Your events stay in the source calendar.") }
    }

    private var macStatus: String {
        if flow.working { return "Waiting for macOS…" }
        switch connections.macAccess {
        case .notAsked: return "Not connected"
        case .refused: return "Access off"
        case .loading: return "Loading calendars…"
        case .noCalendars: return "No calendars on this Mac yet"
        case .ready:
            let count = connections.feeds.filter { $0.provider == .apple }.count
            return count == 1 ? "1 calendar" : "\(count) calendars"
        }
    }

    @ViewBuilder private var macCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Calendars on this Mac").font(.system(size: 13, weight: .semibold))
                    Text(macStatus).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.text2)
                }
                Spacer(minLength: 8)
                if flow.working {
                    IntegrationAction(title: "Cancel") { flow.cancel() }
                } else if connections.macAccess == .refused {
                    IntegrationAction(title: "Open Privacy Settings", primary: true) { PermissionsHelper.openCalendarsSettings() }
                        .accessibilityHint("Opens System Settings → Privacy & Security → Calendars")
                } else if connections.appleEnabled {
                    IntegrationAction(title: "Disconnect", enabled: !busy) { confirmingAppleDisconnect = true }
                } else {
                    IntegrationAction(title: "Allow access", primary: true, enabled: !busy) {
                        flow.startRegistered(provider: .apple, info: configurationInfo)
                    }
                    .accessibilityHint("macOS asks once for access to the calendars of this Mac")
                }
            }
            switch connections.macAccess {
            case .refused:
                warning((flow.lastProvider == .apple ? flow.error : nil) ?? connections.macAccessOffMessage)
            case .notAsked:
                Text("iCloud, Google, Outlook and every account in Internet Accounts. macOS asks for full calendar access; Whytap only reads events.")
                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2).fixedSize(horizontal: false, vertical: true)
                if flow.lastProvider == .apple, let message = flow.error { warning(message) }
            case .noCalendars:
                Text("Add an account with calendars in System Settings → Internet Accounts, or create a calendar in the Calendar app.")
                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2).fixedSize(horizontal: false, vertical: true)
            case .loading:
                EmptyView()
            case .ready:
                Text("Ticked calendars appear in the day view.")
                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                ForEach(connections.macCalendarGroups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            CalendarSourceLogoView(source: .provider(group.service ?? .apple), size: 16)
                            Text(group.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        ForEach(group.feeds) { feed in
                            Toggle(feed.calendarTitle ?? feed.title, isOn: Binding(
                                get: { connections.isShown(feedID: feed.id) },
                                set: { connections.setVisible($0, feedID: feed.id) }))
                                .toggleStyle(.checkbox).font(.system(size: 12)).padding(.leading, 22)
                        }
                    }
                }
                if let message = connections.errors["visibility"] { warning(message) }
            }
        }
    }

    /// Accounts an earlier build connected through Google, Microsoft or Zoom sign-in.
    @ViewBuilder private var directCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connected directly").font(.system(size: 13, weight: .semibold))
            Text("These still work. To move one, add the account in Internet Accounts, then disconnect it here; the same events are shown once.")
                .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2).fixedSize(horizontal: false, vertical: true)
            if let message = connections.errors["accounts"] { warning(message) }
            ForEach(connections.accounts) { account in
                HStack(spacing: 12) {
                    CalendarSourceLogoView(source: .provider(account.provider), size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Text(account.provider.integrationTitle).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.text2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    IntegrationAction(title: "Disconnect", enabled: !busy) { removing = account }
                        .accessibilityLabel("Disconnect \(account.label) from \(account.provider.integrationTitle)")
                }
                if let message = connections.errors[account.id.uuidString] { warning(message) }
            }
        }
    }

    private func disconnect(_ account: ConnectedCalendarAccount) {
        removing = nil
        guard connections.beginConnecting(provider: account.provider) else {
            error = connections.connectionBlockReason ?? "Finish the other calendar operation first."
            return
        }
        error = nil
        Task {
            defer { connections.endConnecting() }
            do { try await connections.remove(account) } catch { self.error = error.localizedDescription }
        }
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsCalendarIntegrationsView {
    func recheckAppleAccess() {
        connections.checkAppleAccess()
        flow.clearAppleRefusalIfAllowed()
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
