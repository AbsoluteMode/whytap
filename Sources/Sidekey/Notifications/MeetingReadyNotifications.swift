import Combine
import Foundation

/// App-owned source: no script, provider setup or system notification permission.
// WHY: .project-docs/decisions/2026-10-20-meeting-ready-notifications.md
@MainActor
final class MeetingReadyNotifications: ObservableObject {
    static let shared = MeetingReadyNotifications(defaults: .standard, hub: .shared)
    static let sourceID = "builtin.meeting-ready"
    private static let enabledKey = "notifications.meetingReady.enabled"

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    private let defaults: UserDefaults
    private let hub: LocalNotificationHub

    init(defaults: UserDefaults, hub: LocalNotificationHub) {
        self.defaults = defaults
        self.hub = hub
        // Absence means ON for both existing installations and new users.
        // Never overwrite a user's explicit OFF when the app starts again.
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    @discardableResult
    func receive(_ event: MeetingsCoordinatorEvent) async -> Bool {
        guard enabled else { return false }
        let id: UUID
        let title: String
        let body: String
        switch event {
        case .newMeetingAvailable(let meetingId):
            (id, title, body) = (meetingId, "Meeting notes are ready", "Click to open your meeting notes.")
        case .meetingTranscriptAvailable(let meetingId):
            // WHY: .project-docs/decisions/2026-11-28-meeting-transcript-without-notes-model.md
            (id, title, body) = (meetingId, "Meeting transcript is ready",
                                 "No notes model is chosen. Click to open the transcript.")
        case .meetingFailed:
            return false
        }
        return await hub.receive(LocalNotificationEvent(
            id: Self.sourceID + ":" + id.uuidString,
            source: Self.sourceID, sourceName: "Meeting notes",
            title: title, body: body,
            link: nil, timestamp: Date(), customTint: "#785EFF", customLogo: "whytap",
            meetingID: id
        ))
    }
}
