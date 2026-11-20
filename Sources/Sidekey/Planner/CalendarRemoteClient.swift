import Foundation

/// Direct, read-only provider adapters. Recurrence is expanded by the service for the visible date range.
struct CalendarRemoteClient {
    let http: CalendarHTTP
    let oauth: CalendarOAuthClient

    func snapshot(account: ConnectedCalendarAccount, interval: DateInterval) async throws -> (feeds: [CalendarFeed], events: [CalendarFeedEvent]) {
        let provider = account.provider
        let path: String
        switch provider {
        case .google: path = "/calendar/v3/users/me/calendarList"
        case .microsoft: path = "/v1.0/me/calendars"
        case .zoom: path = "/v2/calendars/users/me/calendarList"
        case .apple: throw CalendarConnectionError.configuration
        }
        let calendars = try await pages(account: account,
            url: CalendarHTTP.apiURL(provider: provider, path: path), field: provider == .microsoft ? "value" : "items")
        let feeds = try calendars.filter { ($0["deleted"] as? Bool) != true }.map { value -> CalendarFeed in
            guard let id = value["id"] as? String, !id.isEmpty else { throw CalendarConnectionError.invalidResponse }
            return CalendarFeed(id: account.id.uuidString + ":" + id, accountID: account.id, remoteID: id,
                title: (value["summaryOverride"] as? String) ?? (value["summary"] as? String) ??
                    (value["name"] as? String) ?? "Calendar", provider: provider)
        }
        var events: [CalendarFeedEvent] = []
        for feed in feeds {
            try Task.checkCancellation()
            let id = CalendarHTTP.pathComponent(feed.remoteID)
            let path: String
            var query: [URLQueryItem]
            if provider == .microsoft {
                path = "/v1.0/me/calendars/\(id)/calendarView"
                query = [URLQueryItem(name: "startDateTime", value: CalendarDateCodec.string(interval.start)),
                         URLQueryItem(name: "endDateTime", value: CalendarDateCodec.string(interval.end)),
                         URLQueryItem(name: "$top", value: "250")]
            } else {
                path = provider == .google ? "/calendar/v3/calendars/\(id)/events" : "/v2/calendars/\(id)/events"
                query = [URLQueryItem(name: "timeMin", value: CalendarDateCodec.string(interval.start)),
                         URLQueryItem(name: "timeMax", value: CalendarDateCodec.string(interval.end)),
                         URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "showDeleted", value: "false"),
                         URLQueryItem(name: "orderBy", value: "startTime"), URLQueryItem(name: "maxResults", value: "250")]
            }
            let rows = try await pages(account: account, url: CalendarHTTP.apiURL(provider: provider, path: path, query: query),
                field: provider == .microsoft ? "value" : "items")
            events += try rows.compactMap { try Self.event($0, feed: feed) }
        }
        return (feeds, events)
    }

    private func pages(account: ConnectedCalendarAccount, url: URL, field: String) async throws -> [[String: Any]] {
        var next: URL? = url
        var seen: Set<URL> = []
        var rows: [[String: Any]] = []
        while let target = next {
            try Task.checkCancellation()
            guard seen.count < 100, seen.insert(target).inserted,
                  target.scheme == "https", target.host == account.provider.apiHost,
                  target.port == nil || target.port == 443, target.user == nil, target.password == nil else {
                throw CalendarConnectionError.invalidResponse
            }
            var request = URLRequest(url: target)
            request.setValue("Bearer \(try await oauth.accessToken(account.id, expectedProvider: account.provider))", forHTTPHeaderField: "Authorization")
            if account.provider == .microsoft {
                request.setValue("outlook.timezone=\"UTC\", outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
            }
            let result: [String: Any]
            do { result = try await http.json(request) }
            catch CalendarConnectionError.signInRequired {
                request.setValue("Bearer \(try await oauth.accessToken(account.id, forceRefresh: true, expectedProvider: account.provider))", forHTTPHeaderField: "Authorization")
                result = try await http.json(request)
            }
            if let items = result[field] as? [[String: Any]] { rows += items }
            else if result[field] != nil || !(result["kind"] as? String ?? "").hasPrefix("calendar#") {
                throw CalendarConnectionError.invalidResponse
            }
            if account.provider == .microsoft {
                if let link = result["@odata.nextLink"] as? String {
                    guard let parsed = URL(string: link) else { throw CalendarConnectionError.invalidResponse }
                    next = parsed
                } else { next = nil }
            } else if let token = result["nextPageToken"] as? String, !token.isEmpty {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "pageToken", value: token)]
                next = components.url
            } else { next = nil }
        }
        return rows
    }

    static func event(_ row: [String: Any], feed: CalendarFeed) throws -> CalendarFeedEvent? {
        if row["status"] as? String == "cancelled" || row["isCancelled"] as? Bool == true { return nil }
        guard let id = row["id"] as? String,
              let startValue = row["start"] as? [String: Any], let endValue = row["end"] as? [String: Any] else {
            throw CalendarConnectionError.invalidResponse
        }
        let allDay = (row["isAllDay"] as? Bool) ?? (startValue["date"] != nil)
        guard let startText = (startValue["date"] as? String) ?? (startValue["dateTime"] as? String),
              let endText = (endValue["date"] as? String) ?? (endValue["dateTime"] as? String) else {
            throw CalendarConnectionError.invalidResponse
        }
        // All-day dates float with the displayed civil day. Graph sends them as midnight dateTime values.
        let start = CalendarDateCodec.parse(allDay ? String(startText.prefix(10)) : startText,
            timeZone: allDay ? nil : startValue["timeZone"] as? String)
        let end = CalendarDateCodec.parse(allDay ? String(endText.prefix(10)) : endText,
            timeZone: allDay ? nil : endValue["timeZone"] as? String)
        guard let start, let end, end >= start else { throw CalendarConnectionError.invalidResponse }
        let notes = (row["description"] as? String) ??
            ((row["body"] as? [String: Any])?["content"] as? String) ?? ""
        let location = (row["location"] as? String) ??
            ((row["location"] as? [String: Any])?["displayName"] as? String) ?? ""
        let online = (row["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String
        let conference = row["conferenceData"] as? [String: Any]
        let entries = conference?["entryPoints"] as? [[String: Any]] ?? []
        let video = entries.first { $0["entryPointType"] as? String == "video" }?["uri"] as? String
        let meetingURL = CalendarDateCodec.safeURL(online ?? video ?? row["hangoutLink"] as? String) ??
            CalendarDateCodec.meetingURL(in: notes + " " + location)
        let event = PlannerEvent(title: (row["summary"] as? String) ?? (row["subject"] as? String) ?? "Untitled event",
            start: start, end: end == start ? start.addingTimeInterval(1) : end, allDay: allDay,
            location: location, notes: notes, meetingURL: meetingURL)
        return CalendarFeedEvent(id: feed.id + ":" + id, feedID: feed.id, event: event,
            sourceURL: CalendarDateCodec.safeURL((row["htmlLink"] as? String) ?? (row["webLink"] as? String)),
            externalUID: (row["iCalUID"] as? String) ?? (row["iCalUId"] as? String))
    }
}
