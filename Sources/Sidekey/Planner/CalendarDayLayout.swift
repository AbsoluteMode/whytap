import Foundation

// WHY: .project-docs/decisions/2026-11-20-calendar-day-view.md
/// Places one day's timed events on an hour grid. Positions are hours from the
/// start of the day, so a DST day is 23 or 25 hours long and stays exact.
enum CalendarDayLayout {
    struct Block: Equatable {
        let item: CalendarFeedEvent
        /// Hours from the start of the day, clipped to the day.
        let top: Double
        let height: Double
        /// Side-by-side slot among the events it overlaps.
        let column: Int
        let columns: Int
    }

    struct Hour: Equatable {
        let date: Date
        let top: Double
        let height: Double
    }

    /// Hour rows of `day`, each as long as it really is.
    static func hours(of day: DateInterval, calendar: Calendar = .current) -> [Hour] {
        var result: [Hour] = []
        var start = day.start
        while start < day.end {
            let next = min(calendar.date(byAdding: .hour, value: 1, to: start) ?? day.end, day.end)
            result.append(Hour(date: start, top: start.timeIntervalSince(day.start) / 3600,
                               height: next.timeIntervalSince(start) / 3600))
            start = next
        }
        return result
    }

    static func length(of day: DateInterval) -> Double { day.duration / 3600 }

    /// Timed events only; all-day events have their own row. `minimumHours`
    /// is the shortest drawn block, so a 5-minute event still has room for its
    /// title and counts as overlapping what it visually covers.
    static func blocks(_ items: [CalendarFeedEvent], day: DateInterval, minimumHours: Double) -> [Block] {
        let placed = items.filter { !$0.event.allDay }.compactMap { item -> (item: CalendarFeedEvent, top: Double, end: Double)? in
            let start = max(item.event.start, day.start), end = min(item.event.end, day.end)
            guard end > start || item.event.start == item.event.end else { return nil }
            let top = start.timeIntervalSince(day.start) / 3600
            let drawnEnd = min(length(of: day), max(end.timeIntervalSince(day.start) / 3600, top + minimumHours))
            return (item, min(top, length(of: day) - minimumHours), drawnEnd)
        }.sorted { $0.top != $1.top ? $0.top < $1.top : $0.end != $1.end ? $0.end > $1.end : $0.item.id < $1.item.id }

        var result: [Block] = []
        var cluster: [(item: CalendarFeedEvent, top: Double, end: Double, column: Int)] = []
        var columnEnds: [Double] = []
        var clusterEnd = -Double.infinity
        func flush() {
            let count = max(1, columnEnds.count)
            result += cluster.map { Block(item: $0.item, top: $0.top, height: $0.end - $0.top, column: $0.column, columns: count) }
            cluster = []; columnEnds = []
        }
        for entry in placed {
            if entry.top >= clusterEnd { flush() }
            let column = columnEnds.firstIndex { $0 <= entry.top } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(entry.end) } else { columnEnds[column] = entry.end }
            cluster.append((entry.item, entry.top, entry.end, column))
            clusterEnd = max(cluster.count == 1 ? entry.end : clusterEnd, entry.end)
        }
        flush()
        return result
    }

    /// Where the day opens: an hour before now on today, else an hour before
    /// the first timed event, else 8 AM.
    static func initialHour(events: [Block], isToday: Bool, now: Date, day: DateInterval) -> Double {
        let target: Double
        if isToday { target = now.timeIntervalSince(day.start) / 3600 - 1 }
        else if let first = events.map(\.top).min() { target = first - 1 }
        else { target = 8 }
        return min(max(0, target.rounded(.down)), max(0, length(of: day) - 1))
    }
}
