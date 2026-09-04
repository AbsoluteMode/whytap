import Foundation

/// Bucket a meeting falls into for the sidebar's date-grouped sections.
/// Today / Yesterday / This Week are relative to `now`; older meetings
/// land in `.month(year:month:)` and render under "April 2026" style
/// headers. Same model the macOS Mail sidebar uses.
enum MeetingsDateBucket: Hashable, Sendable {
    case today
    case yesterday
    /// Earlier in the current calendar week but before yesterday. The
    /// week starts on `Calendar.firstWeekday` (Monday in ru_RU).
    case thisWeek
    /// Any meeting older than the current calendar week. Year is included
    /// so December 2024 and December 2025 land in separate buckets.
    case month(year: Int, month: Int)
}

/// One bucket worth of meetings — emitted by `groupAndSort` so the
/// sidebar can render header rows + child rows in one pass.
struct MeetingsDateSection: Equatable, Sendable {
    let bucket: MeetingsDateBucket
    let meetings: [MeetingMetaWithLocalState]
}

/// Pure helpers for the sidebar grouping. Injects `now` and the
/// `Calendar` so tests are deterministic across timezones.
enum MeetingsDateGrouping {

    /// Pick which header a meeting sits under.
    static func bucket(
        for date: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> MeetingsDateBucket {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday {
            return .today
        }
        if let startOfYesterday = calendar.date(
            byAdding: .day, value: -1, to: startOfToday
        ), date >= startOfYesterday {
            return .yesterday
        }
        if let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now),
           date >= weekInterval.start {
            return .thisWeek
        }
        let comps = calendar.dateComponents([.year, .month], from: date)
        return .month(year: comps.year ?? 0, month: comps.month ?? 1)
    }

    /// Human-readable label for a bucket. Today / Yesterday / This Week
    /// are localised through `NSLocalizedString`; month buckets format
    /// via `DateFormatter` with `MMMM yyyy` so the user sees their
    /// locale's standalone month name.
    static func headerLabel(
        for bucket: MeetingsDateBucket,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        switch bucket {
        case .today:
            return NSLocalizedString(
                "meetings.sidebar.section.today",
                value: "Today",
                comment: "Sidebar section header for meetings recorded today."
            )
        case .yesterday:
            return NSLocalizedString(
                "meetings.sidebar.section.yesterday",
                value: "Yesterday",
                comment: "Sidebar section header for meetings recorded yesterday."
            )
        case .thisWeek:
            return NSLocalizedString(
                "meetings.sidebar.section.thisWeek",
                value: "This Week",
                comment: "Sidebar section header for older meetings in the current week."
            )
        case let .month(year, month):
            return monthLabel(year: year, month: month, calendar: calendar, locale: locale)
        }
    }

    /// Group a flat list of meetings into ordered sections with rows
    /// sorted newest-first inside each section. Section order is fixed:
    /// Today → Yesterday → This Week → month(desc).
    static func groupAndSort(
        _ meetings: [MeetingMetaWithLocalState],
        now: Date,
        calendar: Calendar = .current
    ) -> [MeetingsDateSection] {
        guard !meetings.isEmpty else { return [] }

        var grouped: [MeetingsDateBucket: [MeetingMetaWithLocalState]] = [:]
        for meeting in meetings {
            let b = bucket(for: meeting.startedAt, now: now, calendar: calendar)
            grouped[b, default: []].append(meeting)
        }

        let monthBuckets = grouped.keys
            .compactMap { bucket -> (year: Int, month: Int)? in
                guard case let .month(year, month) = bucket else { return nil }
                return (year, month)
            }
            .sorted { lhs, rhs in
                if lhs.year != rhs.year { return lhs.year > rhs.year }
                return lhs.month > rhs.month
            }
            .map { MeetingsDateBucket.month(year: $0.year, month: $0.month) }

        let ordered: [MeetingsDateBucket] = [.today, .yesterday, .thisWeek] + monthBuckets

        return ordered.compactMap { bucket -> MeetingsDateSection? in
            guard let rows = grouped[bucket], !rows.isEmpty else { return nil }
            let sorted = rows.sorted { $0.startedAt > $1.startedAt }
            return MeetingsDateSection(bucket: bucket, meetings: sorted)
        }
    }

    // MARK: - Private

    private static func monthLabel(
        year: Int,
        month: Int,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let date = calendar.date(from: components) else {
            return "\(year)-\(month)"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        // The date above is built at midnight in `calendar`'s zone, so the
        // formatter must read it back in that same zone. Without this it
        // falls back to `TimeZone.current`, and a positive-offset calendar
        // (say Europe/Moscow) formatted on a UTC machine renders the 1st of
        // the month as the previous month.
        formatter.timeZone = calendar.timeZone
        // `MMMM yyyy` — standalone month name + 4-digit year. Renders as
        // "April 2026" in en_US, "Апрель 2026" in ru_RU.
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: date)
    }
}
