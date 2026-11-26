import Combine
import EventKit
import SwiftUI

// WHY: .project-docs/decisions/2026-10-21-calendar-hover.md
@MainActor
final class CalendarHoverModel: ObservableObject {
    enum Page: Equatable { case agenda, providers }
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
        guard CalendarAvailability.isOpen, !visible else { return }
        CalendarEventPreviewState.shared.clear()
        visible = true; recheckAppleAccess(); openToday(); activityChanged(true)
    }
    /// Live macOS calendar status (read only, no prompt): clears a stale refusal
    /// once access is allowed and refreshes a saved Apple connection that recovered.
    func recheckAppleAccess() {
        guard CalendarAvailability.isOpen else { return }
        if connections.checkAppleAccess() { refresh() }
        connectionFlow.clearAppleRefusalIfAllowed()
    }
    func end() { visible = false; CalendarEventPreviewState.shared.clear(); activityChanged(false) }
    func openToday() {
        guard CalendarAvailability.isOpen, !connectionFlow.working else { return }
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
        guard CalendarAvailability.isOpen, !connectionFlow.working else { return false }
        page = .providers
        if provider == .apple && connections.appleEnabled {
            // A saved connection with access off: its row is the way to System Settings.
            if connections.appleAccessOff { openPrivacySettings(); return false }
            page = .agenda; return false
        }
        return connectionFlow.startRegistered(provider: provider, info: info) { [self] in
            page = .agenda; refresh(); onSuccess()
        }
    }
    var isToday: Bool { Calendar.current.isDate(selectedDay, inSameDayAs: now()) }
    var interval: DateInterval { Calendar.current.dateInterval(of: .day, for: selectedDay)! }

    /// Whytap's own events and every calendar the user left ticked on the
    /// Calendars page; only calendars of this Mac can be unticked.
    // WHY: .project-docs/decisions/2026-11-23-calendar-macos-only.md
    var events: [CalendarFeedEvent] {
        let local = store.archive.events.map {
            CalendarFeedEvent(id: $0.id.uuidString, feedID: "local", event: $0, sourceURL: nil)
        }
        let shown = connections.events.filter { connections.isShown(feedID: $0.feedID) }
        return CalendarEventMerger.merge(local + shown).filter { $0.event.occurs(on: selectedDay) }.sorted {
            if $0.event.allDay != $1.event.allDay { return $0.event.allDay }
            if $0.event.start != $1.event.start { return $0.event.start < $1.event.start }
            return $0.id < $1.id
        }
    }

    func sourceTitle(_ id: String) -> String {
        id == "local" ? "Whytap · On this Mac" : connections.feeds.first(where: { $0.id == id })?.title ?? "Connected calendar"
    }

    /// The service a calendar belongs to, for the event's logo: a Google or
    /// Exchange account synced by Calendar on this Mac shows its own service.
    func source(_ feedID: String) -> CalendarEventSource? {
        if feedID == "local" { return .whytap }
        return connections.feeds.first(where: { $0.id == feedID }).flatMap(CalendarEventSource.of)
    }

    /// The second line of a block: "11:00 – 11:45 AM · Work".
    func blockMeta(_ item: CalendarFeedEvent) -> String {
        [CalendarEventBlockLabel.timeRange(item.event), sourceTitle(item.feedID)].compactMap { $0 }.joined(separator: " · ")
    }

    // WHY: .project-docs/decisions/2026-11-21-calendar-event-details.md
    /// Which fields a day-grid block of this size shows, and whether hovering it previews.
    func blockPlan(_ item: CalendarFeedEvent, height: CGFloat, textWidth: CGFloat) -> CalendarEventBlockPlan {
        let event = item.event
        return CalendarEventBlockPlan.make(height: height, textWidth: textWidth, title: event.title, meta: blockMeta(item),
            notes: CalendarEventText.plain(event.notes), attendeeSummary: PlannerEventAttendee.compactSummary(event.attendees),
            hasAttendees: !event.attendees.isEmpty,
            hasLocation: !event.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// An all-day chip previews when its line is cut or the event has more to say.
    func chipNeedsPreview(_ item: CalendarFeedEvent) -> Bool {
        let event = item.event
        let details = !CalendarEventText.plain(event.notes).isEmpty || !event.attendees.isEmpty
            || !event.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return CalendarEventBlockPlan.chipNeedsPreview(title: event.title, source: sourceTitle(item.feedID), hasDetails: details)
    }

    /// Every detail of an event for the hover preview.
    func previewContent(_ item: CalendarFeedEvent) -> CalendarEventPreviewContent {
        let event = item.event
        let location = event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = CalendarEventText.plain(event.notes)
        let day = event.displayBounds().start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return CalendarEventPreviewContent(id: item.id, title: event.title,
            when: day + " · " + (CalendarEventBlockLabel.timeRange(event) ?? "All day"),
            calendar: sourceTitle(item.feedID), source: source(item.feedID),
            location: location.isEmpty ? nil : location, action: actionTitle(item),
            link: event.meetingURL.map(CalendarEventPreviewContent.linkText),
            notes: notes.isEmpty ? nil : notes, attendees: event.attendees)
    }

    /// Whether the provider already has a connection, for the Connect list.
    func isConnected(_ provider: CalendarProvider) -> Bool {
        provider == .apple ? connections.appleEnabled : connections.accounts.contains { $0.provider == provider }
    }

    /// What a Connect row offers, shown on the row and spoken by VoiceOver.
    enum ConnectState: Equatable { case connecting, connected, accessOff, addAccount, connect }

    func connectState(_ provider: CalendarProvider) -> ConnectState {
        if connectionFlow.working && connectionFlow.lastProvider == provider { return .connecting }
        if provider == .apple && connections.appleEnabled && connections.appleAccessOff { return .accessOff }
        if !isConnected(provider) { return .connect }
        return provider == .apple ? .connected : .addAccount
    }

    /// VoiceOver name of a Connect row; it matches the row's visible words.
    func connectAccessibilityLabel(_ provider: CalendarProvider) -> String {
        let name = provider.integrationTitle
        switch connectState(provider) {
        case .connecting: return "Connecting \(name)"
        case .connected: return "\(name), connected"
        case .accessOff: return "\(name), access off. Open Privacy Settings"
        case .addAccount: return "Add \(name) account"
        case .connect: return "Connect \(name)"
        }
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
    /// Opens System Settings → Privacy & Security → Calendars; tests replace it.
    var openPrivacySettings: () -> Void = { PermissionsHelper.openCalendarsSettings() }
    /// Opens System Settings → Internet Accounts; tests replace it.
    var openInternetAccounts: () -> Void = { PermissionsHelper.openInternetAccountsSettings() }

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
    /// The day grid's visible rect in the island hover zone; previews start inside it.
    @State private var gridViewport: CGRect?

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
            guard liveUpdates, CalendarAvailability.isOpen else { return }
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
                guard liveUpdates, CalendarAvailability.isOpen else { return }
                connections.refreshAppleIfEnabled(interval: model.interval)
            }
        // Back from System Settings: pick up a changed calendar permission at once.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard liveUpdates else { return }
            model.recheckAppleAccess()
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
                CalendarHoverButton { model.page = .providers } label: {
                    Text(connections.appleEnabled ? "Calendars" : "Connect").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 26)
                }.accessibilityLabel(connections.appleEnabled ? "Choose calendars" : "Connect calendars")
            }
        }
        .frame(height: 26)
    }

    private var title: String {
        switch model.page {
        case .agenda: return "Calendar"
        case .providers: return "Calendars"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .agenda: agenda
        case .providers: providers
        }
    }

    private var agenda: some View {
        VStack(spacing: 8) {
            // Compact day switcher; calendars refresh on their own (see body).
            HStack(spacing: 4) {
                CalendarHoverButton { model.moveDay(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }.accessibilityLabel("Previous day")
                CalendarHoverButton { model.today() } label: {
                    (Text(model.isToday ? "Today" : model.selectedDay.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 12, weight: .semibold))
                     + Text("  " + model.selectedDay.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.76)))
                        .lineLimit(1).padding(.horizontal, 10).frame(height: 24)
                }.help("Show today · " + TimeZone.current.identifier)
                    .accessibilityLabel("\(model.selectedDay.formatted(date: .complete, time: .omitted)). Show today")
                CalendarHoverButton { model.moveDay(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }.accessibilityLabel("Next day")
                if connections.refreshing {
                    ProgressView().controlSize(.mini).frame(width: 16, height: 24).accessibilityLabel("Updating calendars")
                }
            }.frame(maxWidth: .infinity)
            if needsAttention {
                CalendarHoverButton { model.page = .providers } label: {
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
                                 ? "Connect a calendar to see your schedule." : "Events from your connected calendars appear here.")
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

    /// All-day events above the grid, one chip each, with their service's logo.
    private func allDayRow(_ items: [CalendarFeedEvent]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    CalendarEventButton(model: model, item: item, showsPreview: model.chipNeedsPreview(item)) { _ in
                        HStack(spacing: 5) {
                            CalendarSourceLogoView(source: model.source(item.feedID), size: 15)
                            Text(item.event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(model.sourceTitle(item.feedID)).font(.system(size: 10)).lineLimit(1).opacity(0.8)
                        }.padding(.leading, 6).padding(.trailing, 7).frame(height: 22)
                    }.frame(maxWidth: 220)
                }
            }
        }.scrollIndicators(.never).frame(height: 22)
    }

    /// The classic day: hour lines with labels, events as blocks from start to
    /// end with their service's logo, the current time on today.
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
                            let plan = model.blockPlan(block.item, height: block.height * unit - 2,
                                                       textWidth: columnWidth - 2 - CalendarDayGrid.blockTextInset)
                            CalendarEventButton(model: model, item: block.item, showsPreview: plan.needsPreview,
                                                viewport: gridViewport) { _ in
                                CalendarEventBlockLabel(model: model, item: block.item, plan: plan)
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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HistoryHoverView.hoverZoneSpaceName)) } action: {
                gridViewport = $0
            }
            // Another day opens at its first event, which may arrive after the fetch.
            .task(id: model.isToday ? "\(day.start)" : "\(day.start):\(blocks.map(\.top).min() ?? -1)") {
                let hour = CalendarDayLayout.initialHour(events: blocks, isToday: model.isToday, now: model.dayNow, day: day)
                await Task.yield()
                // A little below the top, so the hour's label above its line stays visible.
                scroll.scrollTo(Int(hour), anchor: UnitPoint(x: 0, y: 0.04))
            }
        }
    }

    /// The Calendars page: one permission for every calendar of this Mac, the
    /// calendars by account with a tick each, and where to add more accounts.
    // WHY: .project-docs/decisions/2026-11-23-calendar-macos-only.md
    private var providers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                macAccessSection
                if connectionFlow.working {
                    CalendarHoverButton { connectionFlow.cancel() } label: {
                        Text("Cancel").font(.system(size: 11)).padding(8)
                    }
                }
                // Problems of other calendars (direct connections, storage); Calendar on
                // this Mac shows its own above.
                if let message = connections.connectionBlockReason { notice(message) }
                ForEach(connections.errors.keys.sorted().filter { $0 != "apple" }, id: \.self) { key in
                    notice(connections.errors[key] ?? "")
                }
                if let error = store.errorMessage {
                    notice(error)
                    CalendarHoverButton { store.reload() } label: { Text("Retry").font(.system(size: 11)).padding(8) }
                }
                internetAccountsHint
                if !connections.accounts.isEmpty {
                    Text("Accounts connected directly: Settings → Features → Calendar.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.76)).padding(.horizontal, 2)
                }
            }.padding(3)
        }.scrollIndicators(.visible)
    }

    @ViewBuilder private var macAccessSection: some View {
        let appleError = connectionFlow.lastProvider == .apple ? connectionFlow.error : nil
        switch connections.macAccess {
        case .notAsked:
            Text("See the calendars of this Mac: iCloud, Google, Outlook and every account in Internet Accounts. Whytap only reads them.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            CalendarHoverButton { allowAccess() } label: {
                HStack(spacing: 8) {
                    CalendarSourceLogoView(source: .provider(.apple), size: 22)
                    Text(CalendarConnectionError.allowAccessTitle).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 2)
                    if connectionFlow.working { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(connections.isConnecting)
            .accessibilityLabel(CalendarConnectionError.allowAccessTitle)
            .accessibilityHint("macOS asks once for access to the calendars of this Mac")
            if let appleError { notice(appleError) }
        case .refused:
            notice(appleError ?? connections.macAccessOffMessage)
            CalendarHoverButton { model.openPrivacySettings() } label: {
                Text("Open Privacy Settings").font(.system(size: 11, weight: .medium)).padding(8)
            }.accessibilityHint("Opens System Settings → Privacy & Security → Calendars")
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading calendars…").font(.system(size: 11))
            }.padding(.horizontal, 2)
        case .noCalendars:
            Text("This Mac has no calendars yet.")
                .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 2)
        case .ready:
            ForEach(connections.macCalendarGroups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        CalendarSourceLogoView(source: .provider(group.service ?? .apple), size: 15)
                        Text(group.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }.padding(.horizontal, 2).padding(.top, 2)
                    ForEach(group.feeds) { feed in
                        CalendarFeedToggle(connections: connections, feed: feed)
                    }
                }
            }
        }
    }

    private var internetAccountsHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add Google, Outlook and other calendars in System Settings → Internet Accounts; they appear here.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.76)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            CalendarHoverButton { model.openInternetAccounts() } label: {
                Text("Open Internet Accounts").font(.system(size: 11, weight: .medium)).padding(8)
            }.accessibilityHint("Opens System Settings → Internet Accounts")
        }.padding(.top, 4)
    }

    private func allowAccess() {
        model.connect(.apple, info: configurationInfo) {
            if model.visible { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    private var needsAttention: Bool {
        !connections.errors.isEmpty || store.errorMessage != nil || connectionFlow.error != nil
            || connections.connectionBlockReason != nil
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.orange)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
    }
}

/// One calendar of this Mac with its tick; unticked calendars leave the day.
struct CalendarFeedToggle: View {
    @ObservedObject var connections: CalendarConnections
    let feed: CalendarFeed
    var body: some View {
        let shown = connections.isShown(feedID: feed.id)
        CalendarHoverButton { connections.setVisible(!shown, feedID: feed.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: shown ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(shown ? 0.96 : 0.6))
                Text(feed.calendarTitle ?? feed.title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(feed.calendarTitle ?? feed.title)
        .accessibilityValue(shown ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isToggle)
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
    /// Block width that is not text: leading and trailing padding, logo and gap.
    static let blockTextInset: CGFloat = 7 + 4 + 15 + 5
}

/// An event block, one colour for every calendar; its logo names the service.
/// With a meeting link or an original it is a button (join, else open in its
/// calendar); otherwise it only shows.
struct CalendarEventButton<Label: View>: View {
    @ObservedObject var model: CalendarHoverModel
    let item: CalendarFeedEvent
    /// The block cuts or leaves out details, so hovering shows the preview bubble.
    var showsPreview = false
    /// Visible part of the scrolling day; nil outside it (all-day chips).
    var viewport: CGRect?
    @ViewBuilder let label: (Bool) -> Label
    @State private var hovering = false
    @State private var frame: CGRect = .zero
    @FocusState private var focused: Bool

    var body: some View {
        let color = CalendarEventBlockStyle.color
        let title = model.actionTitle(item)
        let help = [item.event.title, CalendarEventBlockLabel.timeRange(item.event), model.sourceTitle(item.feedID), title]
            .compactMap { $0 }.joined(separator: " · ")
        Group {
            if title != nil {
                Button { model.perform(item) } label: { label(hovering).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    .buttonStyle(CalendarEventBlockStyle(color: color, hovering: hovering, focused: focused))
                    .focused($focused)
            } else {
                label(false).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(CalendarEventBlockStyle.surface(color: color, fill: 0.3))
            }
        }
        // The preview already shows everything; a tooltip would cover it.
        .modifier(CalendarEventHelp(text: showsPreview ? title : help))
        .onHover { hovering = $0; reportPreview() }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HistoryHoverView.hoverZoneSpaceName)) } action: {
            frame = $0
            if hovering { reportPreview() }
        }
        .onChange(of: item) { if hovering { reportPreview() } }
        .onChange(of: showsPreview) { reportPreview() }
        .onDisappear { CalendarEventPreviewState.shared.hide(item.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.event.title, CalendarEventBlockLabel.timeRange(item.event), model.sourceTitle(item.feedID)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(accessibilityDetails)
        .accessibilityHint(title ?? "")
        .accessibilityAddTraits(title != nil ? .isButton : [])
        // children: .ignore hides the Button's own action; only an actionable
        // event gets one back, so an event with nowhere to go is not activatable.
        .modifier(CalendarEventActivation(enabled: title != nil) { model.perform(item) })
    }

    /// Location and attendees, which the block itself may not show.
    private var accessibilityDetails: String {
        let event = item.event
        let location = event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let people = event.attendees.isEmpty ? nil
            : event.attendees.count == 1 ? "1 attendee" : "\(event.attendees.count) attendees"
        return [location.isEmpty ? nil : location, people].compactMap { $0 }.joined(separator: ", ")
    }

    private func reportPreview() {
        let state = CalendarEventPreviewState.shared
        guard hovering, showsPreview else { state.hide(item.id); return }
        let visible = viewport.map { frame.intersection($0) }
        state.show(model.previewContent(item), frame: visible.flatMap { $0.isEmpty ? nil : $0 } ?? frame)
    }
}

/// A native tooltip only when there is something to say.
private struct CalendarEventHelp: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// Tinted block with a solid edge; hover and press deepen the tint.
struct CalendarEventBlockStyle: ButtonStyle {
    // WHY: .project-docs/decisions/2026-11-21-calendar-logos.md
    /// Every event has this colour; the logo, not the colour, tells calendars apart.
    static let color = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)

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

/// The service's logo and the event's fields by priority for the block's
/// height: title, "11:00 – 11:45 AM · Work", description lines, attendees.
/// A short block keeps logo, title and start time on one line.
struct CalendarEventBlockLabel: View {
    @ObservedObject var model: CalendarHoverModel
    let item: CalendarFeedEvent
    let plan: CalendarEventBlockPlan

    static func timeRange(_ event: PlannerEvent) -> String? {
        event.allDay ? nil : (event.start..<max(event.end, event.start)).formatted(.interval.hour().minute())
    }

    var body: some View {
        Group {
            if plan.oneLine {
                HStack(spacing: 4) {
                    CalendarSourceLogoView(source: model.source(item.feedID), size: 13)
                    Text(item.event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(item.event.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10)).lineLimit(1).opacity(0.85).layoutPriority(-1)
                }.frame(maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 5) {
                    CalendarSourceLogoView(source: model.source(item.feedID), size: 15).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.event.title).font(.system(size: 11, weight: .semibold)).lineLimit(plan.titleLines)
                        Text(model.blockMeta(item)).font(.system(size: 10)).lineLimit(1).opacity(0.85)
                        if plan.noteLines > 0 {
                            Text(CalendarEventText.plain(item.event.notes)).font(.system(size: 10))
                                .lineLimit(plan.noteLines).opacity(0.8)
                        }
                        if plan.showsAttendees, let people = PlannerEventAttendee.compactSummary(item.event.attendees) {
                            (Text(Image(systemName: "person.2")) + Text(" " + people))
                                .font(.system(size: 10)).lineLimit(1).opacity(0.8)
                        }
                    }
                }.padding(.vertical, CalendarEventBlockPlan.verticalPadding)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 7).padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// VoiceOver activation for event blocks that have a link to open.
struct CalendarEventActivation: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(.default, action) } else { content }
    }
}
