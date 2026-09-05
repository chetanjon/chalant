import Foundation

/// The "when" in a list row.
///
/// Today shows the time (`9:14 AM`), the last six days a weekday (`Thu`),
/// the same year a date (`Aug 28`), and anything older the year too
/// (`Aug 28, 2025`). Every form follows the user's locale.
enum DateFormat {
    static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfDay, to: startOfToday).day ?? .max
        if days > 0, days <= 6 {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter.string(from: date)
        }

        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d y")
        }
        return formatter.string(from: date)
    }
}
