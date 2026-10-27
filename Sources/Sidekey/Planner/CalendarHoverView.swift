import Combine
import EventKit
import SwiftUI

// WHY: .project-docs/decisions/2026-10-21-calendar-hover.md
@MainActor
final class CalendarHoverModel: ObservableObject {
    enum Page: Equatable { case agenda, sources, providers, event(String) }
    static let shared = CalendarHoverModel(store: .shared, connections: .shared,
        activityChanged: { AppState.shared.calendarHoverActive = $0 },
        connectionActivityChanged: { AppState.shared.calendarHoverConnectionActive = $0 })
    let store: PlannerStore
    let connections: CalendarConnections
    let connectionFlow: CalendarConnectionFlow
    @Published var page: Page = .agenda
    @Published private(set) var selectedDay: Date
    @Published private(set) var refreshToken = 0
    private(set) var visible = false
    private var followingToday = true
    private let now: () -> Date
    private let activityChanged: (Bool) -> Void

    init(store: PlannerStore, connections: CalendarConnections, now: @escaping () -> Date = Date.init,
         activityChanged: @escaping (Bool) -> Void = { _ in },
         connectionActivityChanged: @escaping (Bool) -> Void = { _ in }, connectionFlow: CalendarConnectionFlow? = nil) {
        self.store = store; self.connections = connections; self.now = now; self.activityChanged = activityChanged
        self.connectionFlow = connectionFlow ?? CalendarConnectionFlow(connections: connections, activityChanged: connectionActivityChanged)
        selectedDay = Calendar.current.startOfDay(for: now())
    }

    func begin() {
        guard !visible else { return }
        visible = true; openToday(); activityChanged(true)
    }
    func end() { visible = false; activityChanged(false) }
    func openToday() {
        guard !connectionFlow.working else { return }
        page = .agenda; today()
    }
    func today() { followingToday = true; selectedDay = Calendar.current.startOfDay(for: now()); refresh() }
    func moveDay(_ offset: Int) {
        guard let day = Calendar.current.date(byAdding: .day, value: offset, to: selectedDay) else { return }
        followingToday = false; selectedDay = day; page = .agenda
    }
    func dayChanged() { if followingToday { today() } }
    func refresh() { refreshToken += 1 }
    @discardableResult
    func connect(_ provider: CalendarProvider, info: [String: Any]?, onSuccess: @escaping () -> Void = {}) -> Bool {
        guard !connectionFlow.working else { return false }
        page = .providers
        if provider == .apple && connections.appleEnabled { page = .sources; return false }
        return connectionFlow.startRegistered(provider: provider, info: info) { [self] in
            page = .agenda; refresh(); onSuccess()
        }
    }
    var isToday: Bool { Calendar.current.isDate(selectedDay, inSameDayAs: now()) }
    var interval: DateInterval { Calendar.current.dateInterval(of: .day, for: selectedDay)! }

    var events: [CalendarFeedEvent] {
        let local = connections.hiddenFeeds.contains("local") ? [] : store.archive.events.map {
            CalendarFeedEvent(id: $0.id.uuidString, feedID: "local", event: $0, sourceURL: nil)
        }
        let remote = connections.events.filter { !connections.hiddenFeeds.contains($0.feedID) }
        return CalendarEventMerger.merge(local + remote).filter { $0.event.occurs(on: selectedDay) }.sorted {
            if $0.event.allDay != $1.event.allDay { return $0.event.allDay }
            if $0.event.start != $1.event.start { return $0.event.start < $1.event.start }
            return $0.id < $1.id
        }
    }

    func sourceTitle(_ id: String) -> String {
        id == "local" ? "Whytap · On this Mac" : connections.feeds.first(where: { $0.id == id })?.title ?? "Connected calendar"
    }
}

struct CalendarHoverView: View {
    static let contentHeight: CGFloat = 350
    @ObservedObject var model: CalendarHoverModel
    @ObservedObject private var store: PlannerStore
    @ObservedObject private var connections: CalendarConnections
    @ObservedObject private var connectionFlow: CalendarConnectionFlow
    let onBack: () -> Void
    private let liveUpdates: Bool
    private let configurationInfo: [String: Any]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: CalendarHoverModel, liveUpdates: Bool = true,
         configurationInfo: [String: Any]? = Bundle.main.infoDictionary, onBack: @escaping () -> Void) {
        self.model = model; self.store = model.store; self.connections = model.connections
        self.connectionFlow = model.connectionFlow
        self.liveUpdates = liveUpdates; self.configurationInfo = configurationInfo; self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            content
        }
        .padding(12).frame(height: Self.contentHeight)
        .foregroundStyle(.white.opacity(0.96))
        .environment(\.colorScheme, .dark)
        .task(id: "\(model.selectedDay.timeIntervalSince1970):\(model.refreshToken)") {
            guard liveUpdates else { return }
            repeat {
                await connections.refresh(interval: model.interval)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: connections.accounts) { _, _ in model.refresh() }
        .onChange(of: connections.appleEnabled) { _, _ in model.refresh() }
        .onChange(of: connectionFlow.error) { _, error in
            guard let error else { return }
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in
                guard liveUpdates else { return }
                connections.refreshAppleIfEnabled(interval: model.interval)
            }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in model.dayChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in model.dayChanged(); model.refresh() }
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            IslandHoverBackButton(destination: "calendar:\(model.page)",
                accessibilityLabel: model.page == .agenda ? "Back to tools" : "Back to calendar") {
                if model.page == .agenda { onBack() }
                else { connectionFlow.cancel(); model.page = .agenda }
            }
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if model.page == .agenda {
                CalendarHoverButton { model.page = .sources } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle").frame(width: 26, height: 26)
                }.accessibilityLabel("Choose visible calendars")
            }
            if model.page == .agenda || model.page == .sources {
                CalendarHoverButton { model.page = .providers } label: {
                    Text("Connect").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 26)
                }.accessibilityLabel("Connect a calendar")
            }
        }
    }

    private var title: String {
        switch model.page {
        case .agenda, .event: return "Calendar"
        case .sources: return "Calendars"
        case .providers: return "Connect"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .agenda: agenda
        case .sources: sources
        case .providers: providers
        case .event(let id): details(id)
        }
    }

    private var agenda: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                CalendarHoverButton { model.moveDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 28) }
                    .accessibilityLabel("Previous day")
                CalendarHoverButton { model.today() } label: {
                    VStack(spacing: 1) {
                        Text(model.isToday ? "Today" : model.selectedDay.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.selectedDay.formatted(.dateTime.day().month(.wide)))
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.76))
                    }.frame(maxWidth: .infinity).frame(height: 34)
                }.help("Show today · " + TimeZone.current.identifier)
                    .accessibilityLabel("\(model.selectedDay.formatted(date: .complete, time: .omitted)). Show today")
                CalendarHoverButton { model.moveDay(1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 28) }
                    .accessibilityLabel("Next day")
                CalendarHoverButton { model.refresh() } label: {
                    Group {
                        if connections.refreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: 26, height: 28)
                }.disabled(connections.refreshing).accessibilityLabel("Refresh calendars")
            }
            if !connections.errors.isEmpty || store.errorMessage != nil || connectionFlow.error != nil {
                CalendarHoverButton {
                    if connectionFlow.error != nil { model.page = .providers }
                    else { model.page = .sources }
                } label: {
                    Label("Some calendars need attention", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    if model.events.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "calendar").font(.system(size: 22))
                            Text(connections.refreshing ? "Updating calendars…" : "No events for this day")
                                .font(.system(size: 12, weight: .medium))
                            Text(connections.accounts.isEmpty && !connections.appleEnabled
                                 ? "Connect a calendar to see your schedule." : "Events from your selected calendars appear here.")
                                .font(.system(size: 11)).multilineTextAlignment(.center)
                        }.foregroundStyle(.white.opacity(0.76)).frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(model.events) { item in
                        CalendarHoverButton { model.page = .event(item.id) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Text(item.event.allDay ? "All day" : item.event.start < model.interval.start ? "Ongoing"
                                     : item.event.start.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 45, alignment: .leading)
                                    .foregroundStyle(.white.opacity(0.82))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.event.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(model.sourceTitle(item.feedID)).font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.76)).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.system(size: 9)).padding(.top, 3)
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        }.help(item.event.title)
                    }
                }.padding(3)
            }.scrollIndicators(.visible).id(model.selectedDay)
            Text(TimeZone.current.identifier).font(.system(size: 10)).foregroundStyle(.white.opacity(0.76))
        }
    }

    private var providers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach([CalendarProvider.google, .microsoft, .apple, .zoom]) { provider in
                    CalendarHoverButton {
                        model.connect(provider, info: configurationInfo) {
                            if model.visible { NSApp.activate(ignoringOtherApps: true) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(provider.integrationTitle).font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 2)
                            if connectionFlow.working && connectionFlow.lastProvider == provider {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Connect").font(.system(size: 11, weight: .medium))
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(connections.isConnecting)
                    .accessibilityLabel(connectionFlow.working && connectionFlow.lastProvider == provider
                        ? "Connecting \(provider.integrationTitle)" : "Connect \(provider.integrationTitle)")
                    if connectionFlow.lastProvider == provider, let error = connectionFlow.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.orange)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10)
                    }
                }
                if connectionFlow.working {
                    CalendarHoverButton { connectionFlow.cancel() } label: {
                        Text("Cancel").font(.system(size: 11)).padding(8)
                    }
                }
            }.padding(3)
        }.scrollIndicators(.visible)
    }

    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                feed("local", title: "Whytap · On this Mac")
                ForEach(connections.feeds) { source in feed(source.id, title: source.title) }
                if let message = connections.connectionBlockReason { Text(message).font(.system(size: 11)) }
                if connections.feeds.isEmpty {
                    Text("Connected calendars appear here after refresh.").font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.76)).padding(.vertical, 6)
                }
                ForEach(connections.errors.keys.sorted(), id: \.self) { key in
                    Text(connections.errors[key] ?? "").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                if let error = store.errorMessage {
                    Text(error).font(.system(size: 11))
                    CalendarHoverButton { store.reload() } label: { Text("Retry").font(.system(size: 11)).padding(8) }
                }
                Text("Manage connected accounts in Settings → Integrations.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.76)).padding(.top, 8)
            }.padding(3)
        }.scrollIndicators(.visible)
    }

    private func feed(_ id: String, title: String) -> some View {
        let visible = !connections.hiddenFeeds.contains(id)
        return CalendarHoverButton { connections.setVisible(!visible, feedID: id) } label: {
            HStack(spacing: 8) {
                Image(systemName: visible ? "checkmark.square.fill" : "square")
                Text(title).font(.system(size: 12)).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityValue(visible ? "Shown" : "Hidden").help(title)
            .accessibilityRepresentation {
                Toggle(title, isOn: Binding(get: { !connections.hiddenFeeds.contains(id) },
                    set: { connections.setVisible($0, feedID: id) }))
            }
            .disabled(connections.connectionBlockReason != nil || connections.isConnecting)
    }

    @ViewBuilder private func details(_ id: String) -> some View {
        if let item = model.events.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.event.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                    Text(model.sourceTitle(item.feedID)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.76))
                    Text(eventTime(item.event))
                        .font(.system(size: 12))
                    if !item.event.location.isEmpty {
                        Label(item.event.location, systemImage: "location").font(.system(size: 12)).textSelection(.enabled)
                    }
                    if !item.event.notes.isEmpty { Text(item.event.notes).font(.system(size: 12)).textSelection(.enabled) }
                    if let url = item.event.meetingURL { IntegrationLink(title: "Join meeting", destination: url) }
                    if let url = item.sourceURL { IntegrationLink(title: "Open original", destination: url) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(3)
            }.scrollIndicators(.visible)
        } else {
            Text("This event is no longer in your selected calendars.").font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.76)).frame(maxHeight: .infinity)
        }
    }

    private func eventTime(_ event: PlannerEvent) -> String {
        if event.allDay {
            let bounds = event.displayBounds()
            let start = bounds.start.formatted(date: .abbreviated, time: .omitted)
            let lastDay = bounds.end.addingTimeInterval(-1)
            return "All day · " + start + (Calendar.current.isDate(bounds.start, inSameDayAs: lastDay) ? ""
                : " – " + lastDay.formatted(date: .abbreviated, time: .omitted))
        }
        return event.start.formatted(date: .abbreviated, time: .shortened) + " – "
            + event.end.formatted(date: .abbreviated, time: .shortened)
    }
}

struct CalendarHoverFieldFeedback: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(.white.opacity(enabled && hovering ? 0.55 : 0), lineWidth: 1).allowsHitTesting(false))
            .onHover { hovering = enabled && $0 }
    }
}

struct CalendarHoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action, label: label).buttonStyle(CalendarHoverButtonStyle(focused: focused)).focused($focused)
    }
}

struct CalendarHoverButtonStyle: ButtonStyle {
    var focused = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.96))
            .background(.white.opacity(enabled && configuration.isPressed ? 0.23 : enabled && hovering ? 0.15 : 0.06),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(focused && enabled ? 0.85 : 0), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.42)
            .onHover { hovering = enabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: enabled && hovering)
    }
}
