import Combine
import EventKit
import SwiftUI

// WHY: .project-docs/decisions/2026-10-21-calendar-hover.md
@MainActor
final class CalendarHoverModel: ObservableObject {
    enum Page: Equatable { case agenda, sources, providers }
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

    /// `#RRGGBB` of the event's calendar in the day view.
    func feedColor(_ id: String) -> String {
        if id == "local" { return CalendarFeedColor.local }
        return connections.feeds.first(where: { $0.id == id })?.color ?? CalendarFeedColor.fallback(for: id)
    }

    /// Tooltip and VoiceOver name of the click: Join meeting or Open in <calendar app>.
    func actionTitle(_ item: CalendarFeedEvent) -> String? {
        switch CalendarEventAction.resolve(item) {
        case .join: return "Join meeting"
        case .open(let url):
            // A merged event can open another copy's link, so name the link's own service.
            if url.scheme == "ical" { return "Open in Calendar" }
            let host = url.host?.lowercased() ?? ""
            let provider = CalendarProvider.allCases.first { $0.webHosts.contains { host == $0 || host.hasSuffix("." + $0) } }
                ?? connections.feeds.first(where: { $0.id == item.feedID })?.provider
            return provider == .apple ? "Open in Calendar" : "Open in " + (provider?.title ?? "its calendar")
        case nil: return nil
        }
    }

    var dayNow: Date { now() }

    /// Opens URLs; tests replace it.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// A click on an event: join its meeting, else open it in its own calendar.
    @discardableResult
    func perform(_ item: CalendarFeedEvent) -> Bool {
        guard let action = CalendarEventAction.resolve(item) else { return false }
        openURL(action.url)
        return true
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
        .frame(height: 26)
    }

    private var title: String {
        switch model.page {
        case .agenda: return "Calendar"
        case .sources: return "Calendars"
        case .providers: return "Connect"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .agenda: agenda
        case .sources: sources
        case .providers: providers
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
            let events = model.events
            let allDay = events.filter(\.event.allDay)
            if !allDay.isEmpty { allDayRow(allDay) }
            dayGrid(events)
                .overlay {
                    if events.isEmpty {
                        VStack(spacing: 4) {
                            Text(connections.refreshing ? "Updating calendars…" : "No events for this day")
                                .font(.system(size: 12, weight: .medium))
                            Text(connections.accounts.isEmpty && !connections.appleEnabled
                                 ? "Connect a calendar to see your schedule." : "Events from your selected calendars appear here.")
                                .font(.system(size: 11)).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white.opacity(0.86)).padding(.horizontal, 12).padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                    }
                }
            Text(TimeZone.current.identifier).font(.system(size: 10)).foregroundStyle(.white.opacity(0.76))
        }
    }

    /// All-day events above the grid, one chip each, in their calendar's colour.
    private func allDayRow(_ items: [CalendarFeedEvent]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    CalendarEventButton(model: model, item: item) { _ in
                        HStack(spacing: 5) {
                            Text(item.event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(model.sourceTitle(item.feedID)).font(.system(size: 10)).lineLimit(1).opacity(0.8)
                        }.padding(.leading, 9).padding(.trailing, 7).frame(height: 22)
                    }.frame(maxWidth: 220)
                }
            }
        }.scrollIndicators(.never).frame(height: 22)
    }

    /// The classic day: hour lines with labels, events as blocks from start to
    /// end in their calendar's colour, the current time on today.
    private func dayGrid(_ events: [CalendarFeedEvent]) -> some View {
        let day = model.interval
        let hours = CalendarDayLayout.hours(of: day)
        let unit = CalendarDayGrid.hourHeight
        let blocks = CalendarDayLayout.blocks(events, day: day, minimumHours: CalendarDayGrid.minimumBlockHeight / unit)
        return ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(hours.enumerated()), id: \.offset) { index, hour in
                        HStack(alignment: .top, spacing: 0) {
                            Text(index == 0 ? "" : Calendar.current.component(.minute, from: hour.date) == 0
                                 ? hour.date.formatted(.dateTime.hour())
                                 // A half-hour DST shift (Lord Howe) starts rows off the hour.
                                 : hour.date.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.76))
                                .frame(width: CalendarDayGrid.gutter - 4, alignment: .trailing)
                                .offset(y: -6)
                            Rectangle().fill(.white.opacity(0.14)).frame(height: 1).padding(.leading, 4)
                        }
                        .frame(height: hour.height * unit, alignment: .top)
                        .id(index)
                    }
                }
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        let width = geometry.size.width - CalendarDayGrid.gutter - 2
                        ForEach(blocks, id: \.item.id) { block in
                            let columnWidth = width / CGFloat(block.columns)
                            CalendarEventButton(model: model, item: block.item) { hovering in
                                CalendarEventBlockLabel(model: model, item: block.item,
                                                        height: block.height * unit - 2, hovering: hovering)
                            }
                            .frame(width: max(0, columnWidth - 2), height: max(0, block.height * unit - 2))
                            .offset(x: CalendarDayGrid.gutter + CGFloat(block.column) * columnWidth, y: block.top * unit + 1)
                        }
                        if model.isToday {
                            TimelineView(.everyMinute) { _ in
                                let y = model.dayNow.timeIntervalSince(day.start) / 3600 * unit
                                if y >= 0, y <= CalendarDayLayout.length(of: day) * unit {
                                    HStack(spacing: 0) {
                                        Circle().fill(Color.red).frame(width: 7, height: 7)
                                        Rectangle().fill(Color.red).frame(height: 1.5)
                                    }
                                    .offset(x: CalendarDayGrid.gutter - 3, y: y - 3.5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6).padding(.trailing, 2)
            }
            .scrollIndicators(.visible)
            // Another day opens at its first event, which may arrive after the fetch.
            .task(id: model.isToday ? "\(day.start)" : "\(day.start):\(blocks.map(\.top).min() ?? -1)") {
                let hour = CalendarDayLayout.initialHour(events: blocks, isToday: model.isToday, now: model.dayNow, day: day)
                await Task.yield()
                // A little below the top, so the hour's label above its line stays visible.
                scroll.scrollTo(Int(hour), anchor: UnitPoint(x: 0, y: 0.04))
            }
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
                Circle().fill(Color(hexCSS: model.feedColor(id))).frame(width: 8, height: 8).accessibilityHidden(true)
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

/// Day view geometry in points.
enum CalendarDayGrid {
    static let hourHeight: CGFloat = 44
    /// Hour labels left of the grid.
    static let gutter: CGFloat = 38
    /// A short event still fits one line of text.
    static let minimumBlockHeight: CGFloat = 18
}

/// An event in its calendar's colour. With a meeting link or an original it is
/// a button (join, else open in its calendar); otherwise it only shows.
struct CalendarEventButton<Label: View>: View {
    @ObservedObject var model: CalendarHoverModel
    let item: CalendarFeedEvent
    @ViewBuilder let label: (Bool) -> Label
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let color = Color(hexCSS: model.feedColor(item.feedID))
        let title = model.actionTitle(item)
        let help = [item.event.title, CalendarEventBlockLabel.timeRange(item.event), model.sourceTitle(item.feedID), title]
            .compactMap { $0 }.joined(separator: " · ")
        Group {
            if title != nil {
                Button { model.perform(item) } label: { label(hovering).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    .buttonStyle(CalendarEventBlockStyle(color: color, hovering: hovering, focused: focused))
                    .focused($focused)
                    .onHover { hovering = $0 }
            } else {
                label(false).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(CalendarEventBlockStyle.surface(color: color, fill: 0.3))
            }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.event.title, CalendarEventBlockLabel.timeRange(item.event), model.sourceTitle(item.feedID)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(title ?? "")
        .accessibilityAddTraits(title != nil ? .isButton : [])
        // children: .ignore hides the Button's own action; VoiceOver activates through this one.
        .accessibilityAction { model.perform(item) }
    }
}

/// Tinted block with a solid calendar-coloured edge; hover and press deepen the tint.
struct CalendarEventBlockStyle: ButtonStyle {
    let color: Color
    let hovering: Bool
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Self.surface(color: color, fill: configuration.isPressed ? 0.55 : hovering ? 0.45 : 0.3))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(focused ? 0.85 : 0), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovering)
    }

    static func surface(color: Color, fill: Double) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(color.opacity(fill))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// Title, then "11:00 – 11:45 AM · Work" when the block is tall enough; a short
/// block keeps the title and its start time on one line.
struct CalendarEventBlockLabel: View {
    @ObservedObject var model: CalendarHoverModel
    let item: CalendarFeedEvent
    let height: CGFloat
    let hovering: Bool

    static func timeRange(_ event: PlannerEvent) -> String? {
        event.allDay ? nil : (event.start..<max(event.end, event.start)).formatted(.interval.hour().minute())
    }

    var body: some View {
        Group {
            if height >= 30 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.event.title).font(.system(size: 11, weight: .semibold))
                        .lineLimit(height >= 46 ? 2 : 1)
                    Text([Self.timeRange(item.event), model.sourceTitle(item.feedID)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).lineLimit(1).opacity(0.85)
                }.padding(.vertical, 3)
            } else {
                HStack(spacing: 4) {
                    Text(item.event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(item.event.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10)).lineLimit(1).opacity(0.85).layoutPriority(-1)
                }.frame(maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
