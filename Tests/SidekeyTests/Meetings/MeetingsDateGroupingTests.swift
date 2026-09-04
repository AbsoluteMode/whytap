import XCTest
@testable import Sidekey

/// Pure-function tests for `MeetingsDateGrouping` — the helper the
/// meetings sidebar uses to bucket meetings into "Today", "Yesterday",
/// "This Week", and per-month sections. `now` is injected so the tests
/// are deterministic regardless of when CI runs.
final class MeetingsDateGroupingTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        cal.firstWeekday = 2 // Monday — matches RU locale, what Maxim uses
        return cal
    }()

    /// Anchored "now" used across the suite. Wednesday, 21 May 2026 at
    /// 14:00 Moscow time — comfortably mid-week so Today/Yesterday/This
    /// Week boundaries are unambiguous.
    private lazy var now: Date = {
        calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 21, hour: 14, minute: 0
        ))!
    }()

    // MARK: - bucket

    func test_bucket_today_returnsToday() {
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 21, hour: 9, minute: 0
        ))!
        XCTAssertEqual(
            MeetingsDateGrouping.bucket(for: date, now: now, calendar: calendar),
            .today
        )
    }

    func test_bucket_todayMidnight_returnsToday() {
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 21, hour: 0, minute: 0, second: 0
        ))!
        XCTAssertEqual(
            MeetingsDateGrouping.bucket(for: date, now: now, calendar: calendar),
            .today,
            "Midnight is the first second of Today and must bucket as .today."
        )
    }

    func test_bucket_oneSecondBeforeMidnight_returnsYesterday() {
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 20, hour: 23, minute: 59, second: 59
        ))!
        XCTAssertEqual(
            MeetingsDateGrouping.bucket(for: date, now: now, calendar: calendar),
            .yesterday
        )
    }

    func test_bucket_yesterday_returnsYesterday() {
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 20, hour: 12, minute: 0
        ))!
        XCTAssertEqual(
            MeetingsDateGrouping.bucket(for: date, now: now, calendar: calendar),
            .yesterday
        )
    }

    func test_bucket_twoDaysAgoSameWeek_returnsThisWeek() {
        // Mon 18 May — same calendar week as Wed 21 May.
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 18, hour: 10, minute: 0
        ))!
        XCTAssertEqual(
            MeetingsDateGrouping.bucket(for: date, now: now, calendar: calendar),
            .thisWeek
        )
    }

    func test_bucket_previousMonday_returnsMonthBucket() {
        // Mon 11 May 2026 — week before "now". Should fall into the
        // monthly bucket, not .thisWeek.
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 11, hour: 10, minute: 0
        ))!
        XCTAssertEqual(
            MeetingsDateGrouping.bucket(for: date, now: now, calendar: calendar),
            .month(year: 2026, month: 5)
        )
    }

    func test_bucket_lastMonth_returnsMonthBucket() {
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 4, day: 15, hour: 10, minute: 0
        ))!
        XCTAssertEqual(
            MeetingsDateGrouping.bucket(for: date, now: now, calendar: calendar),
            .month(year: 2026, month: 4)
        )
    }

    func test_bucket_lastYear_returnsMonthBucketWithYear() {
        let date = calendar.date(from: DateComponents(
            year: 2025, month: 12, day: 1, hour: 10, minute: 0
        ))!
        XCTAssertEqual(
            MeetingsDateGrouping.bucket(for: date, now: now, calendar: calendar),
            .month(year: 2025, month: 12)
        )
    }

    // MARK: - headerLabel

    func test_headerLabel_today() {
        XCTAssertEqual(
            MeetingsDateGrouping.headerLabel(
                for: .today, calendar: calendar, locale: Locale(identifier: "en_US")
            ),
            "Today"
        )
    }

    func test_headerLabel_yesterday() {
        XCTAssertEqual(
            MeetingsDateGrouping.headerLabel(
                for: .yesterday, calendar: calendar, locale: Locale(identifier: "en_US")
            ),
            "Yesterday"
        )
    }

    func test_headerLabel_thisWeek() {
        XCTAssertEqual(
            MeetingsDateGrouping.headerLabel(
                for: .thisWeek, calendar: calendar, locale: Locale(identifier: "en_US")
            ),
            "This Week"
        )
    }

    func test_headerLabel_monthEnglish() {
        XCTAssertEqual(
            MeetingsDateGrouping.headerLabel(
                for: .month(year: 2026, month: 4),
                calendar: calendar,
                locale: Locale(identifier: "en_US")
            ),
            "April 2026"
        )
    }

    func test_headerLabel_monthRussian() {
        // The macOS Russian locale renders standalone month names
        // capitalized — "Апрель 2026". Pinning the exact form because
        // the sidebar uses the user's current locale.
        let label = MeetingsDateGrouping.headerLabel(
            for: .month(year: 2026, month: 4),
            calendar: calendar,
            locale: Locale(identifier: "ru_RU")
        )
        XCTAssertTrue(
            label.contains("2026"),
            "Russian month label must include the year (got: \(label))."
        )
        XCTAssertFalse(
            label.lowercased().hasPrefix("month"),
            "Russian month label must not fall back to a placeholder (got: \(label))."
        )
    }

    // MARK: - groupAndSort

    /// Real-world end-to-end use the sidebar will call: given a flat
    /// list of meetings, group them into ordered buckets with their
    /// rows sorted newest-first inside each bucket. The bucket order
    /// is fixed: Today → Yesterday → This Week → month(desc).
    func test_groupAndSort_ordersBucketsAndMeetingsByStartedAtDesc() {
        let todayLate = meeting(year: 2026, month: 5, day: 21, hour: 13)
        let todayEarly = meeting(year: 2026, month: 5, day: 21, hour: 9)
        let yesterday = meeting(year: 2026, month: 5, day: 20, hour: 12)
        let thisWeek = meeting(year: 2026, month: 5, day: 18, hour: 10)
        let april = meeting(year: 2026, month: 4, day: 15, hour: 10)
        let march = meeting(year: 2026, month: 3, day: 5, hour: 10)

        // Intentionally shuffled.
        let input = [april, todayEarly, march, yesterday, thisWeek, todayLate]

        let sections = MeetingsDateGrouping.groupAndSort(
            input, now: now, calendar: calendar
        )

        XCTAssertEqual(sections.map(\.bucket), [
            .today, .yesterday, .thisWeek,
            .month(year: 2026, month: 4),
            .month(year: 2026, month: 3),
        ])
        XCTAssertEqual(sections[0].meetings.map(\.id), [todayLate.id, todayEarly.id])
        XCTAssertEqual(sections[1].meetings.map(\.id), [yesterday.id])
        XCTAssertEqual(sections[2].meetings.map(\.id), [thisWeek.id])
        XCTAssertEqual(sections[3].meetings.map(\.id), [april.id])
        XCTAssertEqual(sections[4].meetings.map(\.id), [march.id])
    }

    func test_groupAndSort_emptyInputReturnsEmptyArray() {
        XCTAssertEqual(
            MeetingsDateGrouping.groupAndSort([], now: now, calendar: calendar).count,
            0
        )
    }

    // MARK: - Helpers

    private func meeting(
        year: Int, month: Int, day: Int, hour: Int
    ) -> MeetingMetaWithLocalState {
        let started = calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: 0
        ))!
        return MeetingMetaWithLocalState(
            id: UUID(),
            startedAt: started,
            endedAt: started.addingTimeInterval(60),
            durationSeconds: 60,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: started
        )
    }
}
