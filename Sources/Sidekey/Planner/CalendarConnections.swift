import EventKit
import SwiftUI
import Combine

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
    var isConnecting: Bool { connectingProvider != nil }
    var connectionBlockReason: String? { backup?.calendarConnectionBlockReason }
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
    private var appleStore: EKEventStore?
    private var generation = 0
    private var metadataValid = true
    private static let accountsKey = CalendarAccountSettings.accountsKey

    init(defaults: UserDefaults = .standard, oauth: CalendarOAuthClient = CalendarOAuthClient(),
        http: CalendarHTTP = CalendarHTTP(), backup: BackupViewModel? = nil,
        activityChanged: @escaping (Bool) -> Void = { _ in }) {
        self.defaults = defaults; self.oauth = oauth; self.backup = backup; self.activityChanged = activityChanged
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
        guard visible || hiddenFeeds.contains(feedID) || hiddenFeeds.count < CalendarAccountSettings.maximumHiddenFeeds else {
            errors["visibility"] = "Too many hidden calendars. Show a calendar or disconnect an unused account first."
            return
        }
        guard feedID.utf8.count <= 1024, !feedID.contains("\0") else { return }
        if visible { hiddenFeeds.remove(feedID) } else { hiddenFeeds.insert(feedID) }
        errors.removeValue(forKey: "visibility")
        saveHiddenFeeds()
    }

    private func saveHiddenFeeds() {
        if hiddenFeeds.count < CalendarAccountSettings.maximumHiddenFeeds { errors.removeValue(forKey: "visibility") }
        defaults.set(Array(hiddenFeeds), forKey: "planner.calendar.hiddenFeeds")
    }

    func enableApple() async throws {
        let store = appleStore ?? EKEventStore()
        appleStore = store
        guard try await store.requestFullAccessToEvents() else { throw CalendarConnectionError.denied }
        try Task.checkCancellation()
        appleEnabled = true
        defaults.set(true, forKey: "planner.calendar.appleEnabled")
    }

    func disableApple() {
        generation += 1
        refreshing = false
        appleEnabled = false
        defaults.set(false, forKey: "planner.calendar.appleEnabled")
        feeds.removeAll { $0.provider == .apple }
        events.removeAll { $0.feedID.hasPrefix("apple:") }
        hiddenFeeds = hiddenFeeds.filter { !$0.hasPrefix("apple:") }
        saveHiddenFeeds()
        errors.removeValue(forKey: "apple"); lastSynced.removeValue(forKey: "apple")
    }

    func refresh(interval: DateInterval) async {
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

    func refreshAppleIfEnabled(interval: DateInterval) {
        guard appleEnabled else { return }
        do { try refreshApple(interval: interval); errors.removeValue(forKey: "apple"); lastSynced["apple"] = Date() }
        catch { errors["apple"] = error.localizedDescription }
    }

    private func refreshApple(interval: DateInterval) throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            feeds.removeAll { $0.provider == .apple }; events.removeAll { $0.feedID.hasPrefix("apple:") }
            throw CalendarConnectionError.denied
        }
        let store = appleStore ?? EKEventStore()
        appleStore = store
        let calendars = store.calendars(for: .event)
        let foundFeeds = calendars.map { calendar in
            CalendarFeed(id: "apple:" + calendar.calendarIdentifier, accountID: nil, remoteID: calendar.calendarIdentifier,
                title: calendar.title + " · " + calendar.source.title, provider: .apple)
        }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        let foundEvents = store.events(matching: predicate).map { event in
            CalendarFeedEvent(id: "apple:" + (event.eventIdentifier ?? event.calendarItemIdentifier) + ":" + CalendarDateCodec.string(event.startDate),
                feedID: "apple:" + event.calendar.calendarIdentifier,
                event: PlannerEvent(title: event.title ?? "Untitled event", start: event.startDate, end: event.endDate,
                    allDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "",
                    meetingURL: CalendarDateCodec.meetingURL(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " "))),
                sourceURL: CalendarEventAction.appleEventURL(identifier: event.calendarItemIdentifier),
                externalUID: event.calendarItemExternalIdentifier)
        }
        feeds.removeAll { $0.provider == .apple }; events.removeAll { $0.feedID.hasPrefix("apple:") }
        feeds += foundFeeds; events += foundEvents
        let currentIDs = Set(foundFeeds.map(\.id))
        let retained = hiddenFeeds.filter { !$0.hasPrefix("apple:") || currentIDs.contains($0) }
        if retained != hiddenFeeds { hiddenFeeds = retained; saveHiddenFeeds() }
    }
}
