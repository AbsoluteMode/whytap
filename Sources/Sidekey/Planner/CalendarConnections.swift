import EventKit
import SwiftUI
import Combine

/// Calendar on this Mac through EventKit. Tests replace it so no scenario asks
/// macOS for access or reads the user's real calendars.
// WHY: .project-docs/decisions/2026-11-22-calendar-release.md
struct AppleCalendarAccess {
    /// Read-only; never shows a system prompt.
    var status: @MainActor () -> EKAuthorizationStatus
    /// Shows the macOS prompt while undecided; afterwards answers at once.
    var request: @MainActor () async throws -> Bool
    var read: @MainActor (DateInterval) -> (feeds: [CalendarFeed], events: [CalendarFeedEvent])
    /// The calendars alone, for Settings: no events, so a day open in Hover is untouched.
    var list: @MainActor () -> [CalendarFeed]

    init(status: @escaping @MainActor () -> EKAuthorizationStatus,
         request: @escaping @MainActor () async throws -> Bool,
         read: @escaping @MainActor (DateInterval) -> (feeds: [CalendarFeed], events: [CalendarFeedEvent]),
         list: (@MainActor () -> [CalendarFeed])? = nil) {
        self.status = status; self.request = request; self.read = read
        self.list = list ?? { read(DateInterval(start: Date(), duration: 0)).feeds }
    }

    /// Whytap may read events: Full Access. "Add Events Only" cannot read.
    static func canRead(_ status: EKAuthorizationStatus) -> Bool { status == .fullAccess }

    /// One store for the app's lifetime, created only when the user connects or
    /// access was already granted; creating it shows no prompt by itself.
    @MainActor static let eventKit: AppleCalendarAccess = {
        let box = EventKitStoreBox()
        func feed(_ calendar: EKCalendar) -> CalendarFeed {
            CalendarFeed(id: "apple:" + calendar.calendarIdentifier, accountID: nil, remoteID: calendar.calendarIdentifier,
                title: calendar.title + " · " + calendar.source.title, provider: .apple,
                displayService: calendar.source.map {
                    CalendarDisplayService.classify(sourceType: $0.sourceType, sourceTitle: $0.title)
                }, sourceTitle: calendar.source?.title, calendarTitle: calendar.title,
                sourceID: calendar.source?.sourceIdentifier)
        }
        return AppleCalendarAccess(
            status: { EKEventStore.authorizationStatus(for: .event) },
            request: { try await box.store.requestFullAccessToEvents() },
            read: { interval in
                let store = box.store
                let calendars = store.calendars(for: .event)
                let feeds = calendars.map(feed)
                // EventKit reads every calendar when the list is empty; no calendars means no events.
                guard !calendars.isEmpty else { return (feeds, []) }
                let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
                let events = store.events(matching: predicate).map { event in
                    CalendarFeedEvent(id: "apple:" + (event.eventIdentifier ?? event.calendarItemIdentifier) + ":" + CalendarDateCodec.string(event.startDate),
                        feedID: "apple:" + event.calendar.calendarIdentifier,
                        event: PlannerEvent(title: event.title ?? "Untitled event", start: event.startDate, end: event.endDate,
                            allDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "",
                            meetingURL: CalendarDateCodec.meetingURL(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")),
                            attendees: PlannerEventAttendee.eventKit(event)),
                        sourceURL: CalendarEventAction.appleEventURL(identifier: event.calendarItemIdentifier),
                        externalUID: event.calendarItemExternalIdentifier)
                }
                return (feeds, events)
            },
            list: { box.store.calendars(for: .event).map(feed) })
    }()
}

/// What Calendar on this Mac can show, for the Calendars page and Settings.
// WHY: .project-docs/decisions/2026-11-23-calendar-macos-only.md
enum MacCalendarAccess: Equatable {
    /// Never connected in Whytap: one button asks macOS.
    case notAsked
    /// macOS refuses (denied, restricted, revoked, Add Events Only).
    case refused
    /// Connected, the first read has not finished.
    case loading
    /// Connected, but this Mac has no calendars: add accounts in Internet Accounts.
    case noCalendars
    case ready
}

/// One account of Internet Accounts (iCloud, an address, Exchange) and its calendars.
struct MacCalendarGroup: Identifiable, Equatable {
    /// EventKit's source identifier (titles can repeat).
    let id: String
    /// The account's name, with its service added when another account has the same name.
    let title: String
    let service: CalendarProvider?
    let feeds: [CalendarFeed]
}

@MainActor
private final class EventKitStoreBox {
    private var created: EKEventStore?
    var store: EKEventStore {
        if let created { return created }
        let store = EKEventStore(); created = store; return store
    }
}

@MainActor
final class CalendarConnections: ObservableObject {
    static let shared = CalendarConnections(backup: .shared, activityChanged: { AppState.shared.calendarConnectionActive = $0 })
    @Published private(set) var accounts: [ConnectedCalendarAccount] = []
    @Published private(set) var feeds: [CalendarFeed] = []
    @Published private(set) var events: [CalendarFeedEvent] = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var lastSynced: [String: Date] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var hiddenFeeds: Set<String> = []
    @Published private(set) var appleEnabled = false
    @Published private(set) var connectingProvider: CalendarProvider?
    /// macOS refuses Whytap calendar access (denied, restricted, revoked or
    /// "Add Events Only") for a saved Apple connection or a Connect refused in
    /// this run: only System Settings can change it. `checkAppleAccess()` keeps
    /// it current from the live authorization status.
    @Published private(set) var appleAccessOff = false
    /// Connect was refused in this run; nothing was saved. Cleared once access is
    /// allowed (then Connect succeeds without a prompt) or by Disconnect.
    @Published private(set) var appleConnectRefused = false
    /// Settings read the calendar list (without events) in this run.
    private var appleListLoaded = false
    var isConnecting: Bool { connectingProvider != nil }

    var macAccess: MacCalendarAccess {
        if appleAccessOff { return .refused }
        guard appleEnabled else { return .notAsked }
        if lastSynced["apple"] == nil && !appleListLoaded { return errors["apple"] == nil ? .loading : .refused }
        return feeds.contains { $0.provider == .apple } ? .ready : .noCalendars
    }

    /// What to say while access is off: a saved connection recovers on its own,
    /// a refused Connect needs Connect again.
    var macAccessOffMessage: String {
        errors["apple"] ?? (appleEnabled ? CalendarConnectionError.appleAccessOffMessage
                                         : CalendarConnectionError.appleConnectRefusedMessage)
    }

    /// Calendars of this Mac by account, accounts and calendars in alphabetical order.
    /// An account is its EventKit source, not its title: two accounts can both be
    /// called "Work". Repeated titles get their service, then a number.
    var macCalendarGroups: [MacCalendarGroup] {
        let mac = feeds.filter { $0.provider == .apple }
        func key(_ feed: CalendarFeed) -> String {
            feed.sourceID ?? "\(feed.sourceTitle ?? "On My Mac")|\(feed.displayService?.rawValue ?? "")"
        }
        let keys = mac.reduce(into: [String]()) { list, feed in
            if !list.contains(key(feed)) { list.append(key(feed)) }
        }
        let groups = keys.map { id -> (id: String, title: String, service: CalendarProvider?, feeds: [CalendarFeed]) in
            let group = mac.filter { key($0) == id }
                .sorted { ($0.calendarTitle ?? $0.title).localizedStandardCompare($1.calendarTitle ?? $1.title) == .orderedAscending }
            return (id, group.first?.sourceTitle ?? "On My Mac", group.first?.displayService, group)
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        var used: [String: Int] = [:]
        return groups.map { group in
            var title = group.title
            if groups.filter({ $0.title == group.title }).count > 1 {
                title += " · " + Self.serviceName(group.service)
                used[title, default: 0] += 1
                if used[title]! > 1 { title += " \(used[title]!)" }
            }
            return MacCalendarGroup(id: group.id, title: title, service: group.service, feeds: group.feeds)
        }
    }

    private static func serviceName(_ service: CalendarProvider?) -> String {
        switch service {
        case .google: return "Google"
        case .microsoft: return "Exchange"
        case .zoom: return "Zoom"
        case .apple, nil: return "iCloud or this Mac"
        }
    }

    /// Settings opened, Allow access finished or Whytap came back from System
    /// Settings: reads the live status and, when a saved connection may read, the
    /// calendar list only (no prompt; nothing for an unconnected Mac). Events stay
    /// as Hover last read them for the day it shows.
    func prepareMacCalendars() {
        checkAppleAccess()
        guard CalendarAvailability.isOpen, appleEnabled, !appleAccessOff,
              AppleCalendarAccess.canRead(apple.status()) else { return }
        let found = apple.list()
        feeds.removeAll { $0.provider == .apple }
        feeds += found
        // Events of calendars that are gone leave with them; the rest are untouched.
        let ids = Set(found.map(\.id))
        events.removeAll { $0.feedID.hasPrefix("apple:") && !ids.contains($0.feedID) }
        appleListLoaded = true
        errors.removeValue(forKey: "apple")
    }

    /// Whether a calendar's events are shown. Only Calendar on this Mac can be
    /// hidden; Whytap's own events and direct connections are always shown.
    func isShown(feedID: String) -> Bool {
        !(feedID.hasPrefix("apple:") && hiddenFeeds.contains(feedID))
    }
    var connectionBlockReason: String? { CalendarAvailability.blockReason ?? backup?.calendarConnectionBlockReason }
    var accountConnectionIssue: String? {
        if let error = errors["accounts"] { return error }
        return accounts.count >= 64 ? "Disconnect an unused calendar account before adding another." : nil
    }
    private let activityChanged: (Bool) -> Void
    private weak var backup: BackupViewModel?
    private var backupChanges: AnyCancellable?
    private let defaults: UserDefaults
    let oauth: CalendarOAuthClient
    private let remote: CalendarRemoteClient
    private let apple: AppleCalendarAccess
    private var generation = 0
    private var metadataValid = true
    private static let accountsKey = CalendarAccountSettings.accountsKey

    init(defaults: UserDefaults = .standard, oauth: CalendarOAuthClient = CalendarOAuthClient(),
        http: CalendarHTTP = CalendarHTTP(), backup: BackupViewModel? = nil,
        apple: AppleCalendarAccess? = nil,
        activityChanged: @escaping (Bool) -> Void = { _ in }) {
        self.defaults = defaults; self.oauth = oauth; self.backup = backup; self.activityChanged = activityChanged
        self.apple = apple ?? .eventKit
        remote = CalendarRemoteClient(http: http, oauth: oauth)
        hiddenFeeds = Set(defaults.stringArray(forKey: "planner.calendar.hiddenFeeds") ?? [])
        appleEnabled = defaults.bool(forKey: "planner.calendar.appleEnabled")
        if let data = defaults.data(forKey: Self.accountsKey) {
            do {
                accounts = try CalendarAccountSettings.decode(data)
            }
            catch { metadataValid = false; errors["accounts"] = "Couldn’t read your calendar connections. Saved settings have been kept." }
        }
        backupChanges = backup?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// One calendar permission/sign-in flow across Settings and Planner.
    func beginConnecting(provider: CalendarProvider) -> Bool {
        guard !isConnecting, connectionBlockReason == nil else { return false }
        connectingProvider = provider
        activityChanged(true)
        return true
    }

    func endConnecting() {
        connectingProvider = nil
        activityChanged(false)
    }

    func add(_ account: ConnectedCalendarAccount) throws {
        guard CalendarAvailability.isOpen else { throw CalendarConnectionError.comingSoon }
        guard metadataValid, accounts.count < 64, account.provider != .apple, !accounts.contains(where: { $0.id == account.id }),
              !account.label.isEmpty, account.label.count <= 120 else { throw CalendarConnectionError.configuration }
        let candidate = accounts + [account]
        defaults.set(try JSONEncoder().encode(candidate), forKey: Self.accountsKey)
        accounts = candidate
    }

    func remove(_ account: ConnectedCalendarAccount) async throws {
        try await oauth.disconnect(account.id)
        let candidate = accounts.filter { $0.id != account.id }
        defaults.set(try JSONEncoder().encode(candidate), forKey: Self.accountsKey)
        accounts = candidate
        generation += 1
        refreshing = false
        let ids = Set(feeds.filter { $0.accountID == account.id }.map(\.id))
        feeds.removeAll { ids.contains($0.id) }; events.removeAll { ids.contains($0.feedID) }
        hiddenFeeds = hiddenFeeds.filter { !$0.hasPrefix(account.id.uuidString + ":") }
        saveHiddenFeeds()
        errors.removeValue(forKey: account.id.uuidString); lastSynced.removeValue(forKey: account.id.uuidString)
    }

    func setVisible(_ visible: Bool, feedID: String) {
        guard feedID.utf8.count <= 1024, !feedID.contains("\0") else { return }
        // Entries of direct connections are inactive since 2026-11-23 (only calendars
        // of this Mac have ticks); they make room before the limit refuses a tick.
        if !visible, feedID.hasPrefix("apple:"), !hiddenFeeds.contains(feedID),
           hiddenFeeds.count >= CalendarAccountSettings.maximumHiddenFeeds {
            let overflow = hiddenFeeds.count - CalendarAccountSettings.maximumHiddenFeeds + 1
            for legacy in hiddenFeeds.filter({ !$0.hasPrefix("apple:") }).sorted().prefix(overflow) { hiddenFeeds.remove(legacy) }
        }
        guard visible || hiddenFeeds.contains(feedID) || hiddenFeeds.count < CalendarAccountSettings.maximumHiddenFeeds else {
            errors["visibility"] = "Too many hidden calendars. Show a calendar or disconnect an unused account first."
            return
        }
        if visible { hiddenFeeds.remove(feedID) } else { hiddenFeeds.insert(feedID) }
        errors.removeValue(forKey: "visibility")
        saveHiddenFeeds()
    }

    private func saveHiddenFeeds() {
        if hiddenFeeds.count < CalendarAccountSettings.maximumHiddenFeeds { errors.removeValue(forKey: "visibility") }
        defaults.set(Array(hiddenFeeds), forKey: "planner.calendar.hiddenFeeds")
    }

    func enableApple() async throws {
        // Closed: never create the event store or ask macOS for calendar access.
        guard CalendarAvailability.isOpen else { throw CalendarConnectionError.comingSoon }
        // Only here, after the user pressed Connect, may macOS show its prompt.
        // A refusal saved earlier answers at once without a prompt.
        let granted = try await apple.request()
        try Task.checkCancellation()
        guard granted, AppleCalendarAccess.canRead(apple.status()) else {
            appleAccessOff = true
            appleConnectRefused = true
            throw CalendarConnectionError.appleConnectRefused
        }
        appleAccessOff = false
        appleConnectRefused = false
        errors.removeValue(forKey: "apple")
        appleEnabled = true
        defaults.set(true, forKey: "planner.calendar.appleEnabled")
    }

    func disableApple() {
        generation += 1
        refreshing = false
        appleEnabled = false
        appleAccessOff = false
        appleConnectRefused = false
        appleListLoaded = false
        defaults.set(false, forKey: "planner.calendar.appleEnabled")
        feeds.removeAll { $0.provider == .apple }
        events.removeAll { $0.feedID.hasPrefix("apple:") }
        hiddenFeeds = hiddenFeeds.filter { !$0.hasPrefix("apple:") }
        saveHiddenFeeds()
        errors.removeValue(forKey: "apple"); lastSynced.removeValue(forKey: "apple")
    }

    func refresh(interval: DateInterval) async {
        // Closed: no provider request and no EventKit read, whatever was connected before.
        guard CalendarAvailability.isOpen else { return }
        generation += 1
        let current = generation
        refreshing = true
        defer { if generation == current { refreshing = false } }
        refreshAppleIfEnabled(interval: interval)
        for account in accounts {
            guard !Task.isCancelled, generation == current else { return }
            let key = account.id.uuidString
            do {
                let snapshot = try await remote.snapshot(account: account, interval: interval)
                guard !Task.isCancelled, generation == current, accounts.contains(where: { $0.id == account.id }) else { return }
                let previous = Set(feeds.filter { $0.accountID == account.id }.map(\.id))
                feeds.removeAll { previous.contains($0.id) }
                events.removeAll { previous.contains($0.feedID) }
                feeds += snapshot.feeds; events += snapshot.events
                let currentIDs = Set(snapshot.feeds.map(\.id))
                let retained = hiddenFeeds.filter { !$0.hasPrefix(key + ":") || currentIDs.contains($0) }
                if retained != hiddenFeeds { hiddenFeeds = retained; saveHiddenFeeds() }
                lastSynced[key] = Date(); errors.removeValue(forKey: key)
            } catch is CancellationError { return }
            catch { if generation == current { errors[key] = error.localizedDescription } }
        }
    }

    /// Re-reads the authorization status (never prompts, never reads events) for a
    /// saved Apple connection or a refused Connect, e.g. when Settings or Calendar
    /// opens or Whytap becomes active after System Settings. Returns true when a
    /// saved connection can read again, so the caller may refresh its events.
    @discardableResult
    func checkAppleAccess() -> Bool {
        guard CalendarAvailability.isOpen, appleEnabled || appleConnectRefused else { return false }
        if AppleCalendarAccess.canRead(apple.status()) {
            let recovered = appleEnabled && appleAccessOff
            appleAccessOff = false
            appleConnectRefused = false
            if errors["apple"] == CalendarConnectionError.appleAccessOffMessage { errors.removeValue(forKey: "apple") }
            return recovered
        }
        appleAccessOff = true
        if appleEnabled {
            feeds.removeAll { $0.provider == .apple }; events.removeAll { $0.feedID.hasPrefix("apple:") }
            errors["apple"] = CalendarConnectionError.appleAccessOffMessage
        }
        return false
    }

    func refreshAppleIfEnabled(interval: DateInterval) {
        guard CalendarAvailability.isOpen, appleEnabled else { return }
        do { try refreshApple(interval: interval); errors.removeValue(forKey: "apple"); lastSynced["apple"] = Date() }
        catch { errors["apple"] = error.localizedDescription }
    }

    private func refreshApple(interval: DateInterval) throws {
        // Read-only status check: a revoked access never brings up a prompt.
        guard AppleCalendarAccess.canRead(apple.status()) else {
            feeds.removeAll { $0.provider == .apple }; events.removeAll { $0.feedID.hasPrefix("apple:") }
            appleAccessOff = true
            throw CalendarConnectionError.appleAccessOff
        }
        appleAccessOff = false
        let (foundFeeds, foundEvents) = apple.read(interval)
        feeds.removeAll { $0.provider == .apple }; events.removeAll { $0.feedID.hasPrefix("apple:") }
        feeds += foundFeeds; events += foundEvents
        let currentIDs = Set(foundFeeds.map(\.id))
        let retained = hiddenFeeds.filter { !$0.hasPrefix("apple:") || currentIDs.contains($0) }
        if retained != hiddenFeeds { hiddenFeeds = retained; saveHiddenFeeds() }
    }
}
