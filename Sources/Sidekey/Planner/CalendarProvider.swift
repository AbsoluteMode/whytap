import Foundation
import WhytapCaseKit

enum CalendarProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, google, microsoft, zoom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: return "Apple Calendar"
        case .google: return "Google Calendar"
        case .microsoft: return "Outlook & Teams"
        case .zoom: return "Zoom Calendar"
        }
    }
    var authorizationEndpoint: String {
        switch self {
        case .google: return "https://accounts.google.com/o/oauth2/v2/auth"
        case .microsoft: return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        case .zoom: return "https://zoom.us/oauth/authorize"
        case .apple: return ""
        }
    }
    var tokenEndpoint: String {
        switch self {
        case .google: return "https://oauth2.googleapis.com/token"
        case .microsoft: return "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        case .zoom: return "https://zoom.us/oauth/token"
        case .apple: return ""
        }
    }
    var scopes: String {
        switch self {
        case .google: return "https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events.readonly"
        case .microsoft: return "offline_access Calendars.Read"
        case .zoom: return "calendar:read:list_calendar_lists calendar:read:list_events"
        case .apple: return ""
        }
    }
    var apiHost: String {
        switch self {
        case .google: return "www.googleapis.com"
        case .microsoft: return "graph.microsoft.com"
        case .zoom: return "api.zoom.us"
        case .apple: return ""
        }
    }
}

struct ConnectedCalendarAccount: Codable, Identifiable, Equatable {
    var id: UUID
    var provider: CalendarProvider
    var label: String
}

struct CalendarFeed: Identifiable, Equatable {
    var id: String
    var accountID: UUID?
    var remoteID: String
    var title: String
    var provider: CalendarProvider?
}

struct CalendarFeedEvent: Identifiable, Equatable {
    var id: String
    var feedID: String
    var event: PlannerEvent
    var sourceURL: URL?
    var externalUID: String?
    var additionalFeedIDs: [String] = []
}

enum CalendarEventMerger {
    static func merge(_ events: [CalendarFeedEvent]) -> [CalendarFeedEvent] {
        var result: [CalendarFeedEvent] = []
        var indices: [String: Int] = [:]
        for event in events {
            guard let uid = event.externalUID, !uid.isEmpty else { result.append(event); continue }
            let bounds = event.event.displayBounds()
            let key = uid + ":" + String(bounds.start.timeIntervalSince1970) + ":" + String(bounds.end.timeIntervalSince1970)
            if let index = indices[key] {
                let feeds = [result[index].feedID] + result[index].additionalFeedIDs
                if !feeds.contains(event.feedID) { result[index].additionalFeedIDs.append(event.feedID) }
                if result[index].event.meetingURL == nil { result[index].event.meetingURL = event.event.meetingURL }
                if result[index].sourceURL == nil { result[index].sourceURL = event.sourceURL }
            } else { indices[key] = result.count; result.append(event) }
        }
        return result
    }
}

enum CalendarConnectionError: Error, LocalizedError {
    case invalidResponse, signInRequired, denied, cancelled, timeout, keychain, configuration, unavailable, publicReviewPending
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The calendar service returned an unsupported response. Try refreshing."
        case .signInRequired: return "Sign-in expired. Disconnect this account, then use Connect account to sign in again."
        case .denied: return "Calendar access wasn’t granted. You can connect again when ready."
        case .cancelled: return "Connection cancelled."
        case .timeout: return "Sign-in timed out. Try connecting again."
        case .keychain: return "Couldn’t access Keychain. Unlock it and retry."
        case .configuration: return "Check the OAuth client configuration and registered redirect address."
        case .publicReviewPending: return "Public calendar sign-in is awaiting provider approval."
        case .unavailable: return "Couldn’t reach the calendar service. Check your connection and retry."
        case .http(403): return "Access denied. Check calendar permissions and your organization’s policy."
        case .http(429): return "The calendar service is busy. Wait a little before refreshing."
        case .http(let status): return "Calendar request failed (HTTP \(status)). Try refreshing."
        }
    }
}

enum CalendarDateCodec {
    static func parse(_ value: String, timeZone: String? = nil) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func safeURL(_ raw: String?) -> URL? {
        PlannerTodoFile.safeMeetingURL(raw)
    }

    static func meetingURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = safeURL(match.url?.absoluteString), let host = url.host?.lowercased() else { return nil }
            return ["zoom.us", "teams.microsoft.com", "teams.live.com", "meet.google.com"].contains {
                host == $0 || host.hasSuffix("." + $0)
            } ? url : nil
        }.first
    }
}
