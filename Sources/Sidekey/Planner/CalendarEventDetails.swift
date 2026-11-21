import EventKit
import Foundation

// WHY: .project-docs/decisions/2026-11-21-calendar-event-details.md
/// A person invited to a calendar event. Read from Calendar on this Mac and
/// Microsoft Graph, kept in memory only: `PlannerEvent` never encodes it.
struct PlannerEventAttendee: Equatable, Hashable, Sendable {
    enum Status: String, Equatable, Hashable, Sendable {
        case accepted, declined, tentative, pending

        init?(_ status: EKParticipantStatus) {
            switch status {
            case .accepted: self = .accepted
            case .declined: self = .declined
            case .tentative: self = .tentative
            case .pending: self = .pending
            default: return nil
            }
        }

        /// Microsoft Graph `responseStatus.response`.
        init?(graph response: String?) {
            switch response {
            case "accepted": self = .accepted
            case "declined": self = .declined
            case "tentativelyAccepted": self = .tentative
            case "notResponded", "none": self = .pending
            default: return nil
            }
        }
    }

    var name: String
    var email: String
    var isOrganizer = false
    var isCurrentUser = false
    var status: Status?

    /// The name, else the address.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return email.isEmpty ? "Unknown attendee" : email
    }

    /// First word of the name, else the whole address, for the block's one line.
    var shortName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? displayName
    }

    /// The organizer first, then attendees in order; one row per address. The
    /// organizer's own row in the attendee list carries their response.
    static func merged(organizer: PlannerEventAttendee?, attendees: [PlannerEventAttendee]) -> [PlannerEventAttendee] {
        var result: [PlannerEventAttendee] = []
        var indices: [String: Int] = [:]
        for person in (organizer.map { [$0] } ?? []) + attendees {
            let key = person.email.isEmpty ? "name:" + person.displayName.lowercased() : person.email.lowercased()
            if let index = indices[key] {
                if let status = person.status, result[index].isOrganizer || result[index].status == nil {
                    result[index].status = status
                }
                result[index].isCurrentUser = result[index].isCurrentUser || person.isCurrentUser
            } else {
                indices[key] = result.count
                result.append(person)
            }
        }
        return result
    }

    /// "Anna, Boris +3": two other people by first name and a count of the rest.
    /// You are left out; nil when nobody else attends.
    static func compactSummary(_ attendees: [PlannerEventAttendee], names: Int = 2) -> String? {
        let others = attendees.filter { !$0.isCurrentUser }
        guard !others.isEmpty else { return nil }
        let listed = others.prefix(names).map(\.shortName).joined(separator: ", ")
        return others.count > names ? "\(listed) +\(others.count - names)" : listed
    }

    /// EventKit identifies people by `mailto:` URLs.
    static func email(fromParticipantURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = url.absoluteString.dropFirst("mailto:".count)
        let address = (String(raw).removingPercentEncoding ?? String(raw)).trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? nil : address
    }

    init(name: String, email: String, isOrganizer: Bool = false, isCurrentUser: Bool = false, status: Status? = nil) {
        self.name = name; self.email = email; self.isOrganizer = isOrganizer
        self.isCurrentUser = isCurrentUser; self.status = status
    }

    init(participant: EKParticipant, isOrganizer: Bool = false) {
        self.init(name: participant.name ?? "", email: Self.email(fromParticipantURL: participant.url) ?? "",
                  isOrganizer: isOrganizer, isCurrentUser: participant.isCurrentUser,
                  status: isOrganizer ? nil : Status(participant.participantStatus))
    }

    static func eventKit(_ event: EKEvent) -> [PlannerEventAttendee] {
        merged(organizer: event.organizer.map { PlannerEventAttendee(participant: $0, isOrganizer: true) },
               attendees: (event.attendees ?? []).map { PlannerEventAttendee(participant: $0) })
    }

    /// Microsoft Graph `organizer` and `attendees`; rows without a name or address are skipped.
    static func graph(_ row: [String: Any]) -> [PlannerEventAttendee] {
        func person(_ value: Any?) -> (name: String, email: String)? {
            guard let address = (value as? [String: Any])?["emailAddress"] as? [String: Any] else { return nil }
            let name = address["name"] as? String ?? "", email = address["address"] as? String ?? ""
            return name.isEmpty && email.isEmpty ? nil : (name, email)
        }
        let organizer = person(row["organizer"]).map {
            PlannerEventAttendee(name: $0.name, email: $0.email, isOrganizer: true,
                                 isCurrentUser: row["isOrganizer"] as? Bool == true)
        }
        let attendees = (row["attendees"] as? [Any] ?? []).compactMap { value -> PlannerEventAttendee? in
            guard let found = person(value) else { return nil }
            let response = ((value as? [String: Any])?["status"] as? [String: Any])?["response"] as? String
            return PlannerEventAttendee(name: found.name, email: found.email, status: Status(graph: response))
        }
        return merged(organizer: organizer, attendees: attendees)
    }
}

// WHY: .project-docs/decisions/2026-11-21-calendar-event-details.md
/// The service behind a calendar synced through Calendar on this Mac, for its
/// logo only. The connection itself stays Apple Calendar (EventKit).
enum CalendarDisplayService {
    private static let googleDomains: Set<String> = ["gmail", "googlemail"]
    private static let microsoftDomains: Set<String> = ["outlook", "hotmail", "live", "msn", "windowslive"]
    private static let googleWords: Set<String> = ["google"]
    private static let microsoftWords: Set<String> = ["outlook", "exchange", "office365", "microsoft", "hotmail"]

    /// EventKit exposes only the account's type and title (its description in
    /// Internet Accounts, by default "Google" or the address), not its server.
    static func classify(sourceType: EKSourceType, sourceTitle: String) -> CalendarProvider {
        switch sourceType {
        case .exchange: return .microsoft
        case .calDAV: break
        default: return .apple
        }
        let title = sourceTitle.lowercased()
        if let at = title.lastIndex(of: "@") {
            let firstLabel = title[title.index(after: at)...].split(separator: ".").first.map(String.init) ?? ""
            if googleDomains.contains(firstLabel) { return .google }
            if microsoftDomains.contains(firstLabel) { return .microsoft }
        }
        let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains(where: googleWords.contains) { return .google }
        let joined = zip(words, words.dropFirst()).map { $0 + $1 }
        if words.contains(where: microsoftWords.contains) || joined.contains("office365") { return .microsoft }
        return .apple
    }
}

/// Event descriptions as plain text: Google sends HTML, the others plain text.
/// Invitation boilerplate's decorative rules (Teams' underscores, Google's
/// `-::~:~::-`) and Outlook's `text<https://…>` link targets are removed; the
/// meeting link is shown on its own.
enum CalendarEventText {
    private static let bracketedLink = try! NSRegularExpression(pattern: "<(?:https?|mailto|tel):[^<>\\s]*>",
                                                              options: [.caseInsensitive])
    private static let ruleCharacters = Set("_-=─━*~:")

    /// A line made only of repeated rule characters (and spaces), at least three of them.
    static func isSeparator(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        return marks.count >= 3 && marks.allSatisfy(ruleCharacters.contains) && marks.contains { $0 != ":" }
    }

    private static let tag = try! NSRegularExpression(
        pattern: "</?(br|p|div|li|ul|ol|b|strong|i|em|u|span|a|font|h[1-6]|html|body)(?:\\s[^<>]*)?/?>",
        options: [.caseInsensitive])

    static func plain(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        let range = NSRange(result.startIndex..., in: result)
        if tag.firstMatch(in: result, range: range) != nil {
            let output = NSMutableString(string: result)
            for match in tag.matches(in: result, range: range).reversed() {
                let name = (result as NSString).substring(with: match.range(at: 1)).lowercased()
                let breaks = name == "br" || ["p", "div", "li", "ul", "ol"].contains(name) || name.hasPrefix("h")
                output.replaceCharacters(in: match.range, with: breaks ? "\n" : "")
            }
            result = String(output)
            for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
                result = result.replacingOccurrences(of: entity, with: value)
            }
        }
        result = bracketedLink.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                        withTemplate: "")
        result = result.components(separatedBy: "\n").compactMap { line -> String? in
            if isSeparator(line) { return nil }
            return line.allSatisfy(\.isWhitespace) ? "" : line
        }.joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
