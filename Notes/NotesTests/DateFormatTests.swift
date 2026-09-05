import XCTest
@testable import Notes

final class DateFormatTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private let locale = Locale(identifier: "en_US")

    /// 2026-09-05 14:30 UTC, a Saturday.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 14, minute: 30))!
    }

    /// ICU puts a narrow no-break space before AM/PM; the assertions use a
    /// plain space so they read the way the spec does.
    private func when(_ date: Date) -> String {
        DateFormat.when(date, now: now, calendar: calendar, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testTodayShowsTime() {
        let date = calendar.date(bySettingHour: 9, minute: 14, second: 0, of: now)!
        XCTAssertEqual(when(date), "9:14 AM")
    }

    func testWithinSixDaysShowsWeekday() {
        let thursday = calendar.date(byAdding: .day, value: -2, to: now)!
        XCTAssertEqual(when(thursday), "Thu")
        let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now)!
        XCTAssertEqual(when(sixDaysAgo), "Sun")
    }

    func testSameYearShowsMonthAndDay() {
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        XCTAssertEqual(when(sevenDaysAgo), "Aug 29")
    }

    func testOlderShowsYear() {
        let lastYear = calendar.date(byAdding: .year, value: -1, to: now)!
        XCTAssertEqual(when(lastYear), "Sep 5, 2025")
    }
}
