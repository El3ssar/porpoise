import Foundation
import Testing

@testable import PorpoiseCore

struct RelativeDateTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt; c.locale = Locale(identifier: "en_US")
        return c
    }

    @Test func minuteBoundariesUseCompletedMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seconds: Double in [0, 0.001, 59, 59.999] {
            #expect(FileFormat.relativeDate(now.addingTimeInterval(-seconds), now: now, calendar: calendar) == "Just now")
        }
        for (seconds, label): (Double, String) in [
            (60, "1 minute ago"), (119.99, "1 minute ago"), (120, "2 minutes ago"), (3599.99, "59 minutes ago"),
        ] {
            #expect(FileFormat.relativeDate(now.addingTimeInterval(-seconds), now: now, calendar: calendar) == label)
        }
        #expect(FileFormat.relativeDate(now.addingTimeInterval(-3600), now: now, calendar: calendar).hasPrefix("Today at "))
    }

    @Test func recentPastCrossesMidnightWithoutBecomingYesterday() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 0, minute: 2))!
        #expect(FileFormat.relativeDate(now.addingTimeInterval(-180), now: now, calendar: calendar) == "3 minutes ago")
        #expect(FileFormat.relativeDate(now.addingTimeInterval(-3600), now: now, calendar: calendar).hasPrefix("Yesterday at "))
    }

    @Test func futureDatesAreNeverDescribedAsAgo() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        for interval: Double in [0.01, 59, 120, 3600, 86400] {
            let text = FileFormat.relativeDate(now.addingTimeInterval(interval), now: now, calendar: calendar)
            #expect(text != "Just now" && !text.contains("ago"))
        }
    }

    @Test func olderDatesKeepTheirTimeInTheRequestedZoneAndLocale() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 12, minute: 34))!
        let now = date.addingTimeInterval(30 * 86400)
        var german = calendar
        german.locale = Locale(identifier: "de_DE"); german.timeZone = TimeZone(secondsFromGMT: 3600)!
        let text = FileFormat.relativeDate(date, now: now, calendar: german)
        #expect(text.contains("08.09.2026") && text.contains("13:34"))
        let english = FileFormat.relativeDate(date, now: now, calendar: calendar)
        #expect(english.contains("Sep 8, 2026") && english.contains("12:34"))
    }

    @Test func relativeDayUsesTheSameZoneAsItsTime() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 23, minute: 30))!
        let now = date.addingTimeInterval(7200)
        var west = calendar; west.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        #expect(FileFormat.relativeDate(date, now: now, calendar: calendar).hasPrefix("Yesterday at 11:30"))
        #expect(FileFormat.relativeDate(date, now: now, calendar: west).hasPrefix("Today at 3:30"))
    }

    @Test func exactTimestampIncludesDateSecondsAndZone() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12, minute: 34, second: 56))!
        let text = FileFormat.exactDate(date, calendar: calendar)
        #expect(text.contains("November 3, 2026") && text.contains("12:34:56") && text.contains("GMT"))
        #expect(!FileFormat.longDate(date, calendar: calendar).contains(":56"))
    }
}
