import Foundation
import Testing

@testable import Trio

@Suite("Log Auto-save Tests") struct LogAutoSaveTests {
    private static let timeZone = TimeZone(identifier: "America/New_York")!

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test("Latest slot is the most recent 12:01 am") func latestSlot() {
        let slot = Self.date(2026, 10, 31, 0, 1)
        #expect(LogAutoSave.latestSlot(atOrBefore: Self.date(2026, 10, 31, 0, 1), calendar: Self.calendar) == slot)
        #expect(LogAutoSave.latestSlot(atOrBefore: Self.date(2026, 10, 31, 15, 30), calendar: Self.calendar) == slot)
        #expect(LogAutoSave.latestSlot(atOrBefore: Self.date(2026, 11, 1, 0, 0, 59), calendar: Self.calendar) == slot)
        #expect(
            LogAutoSave.latestSlot(atOrBefore: Self.date(2026, 11, 1, 0, 1), calendar: Self.calendar) ==
                Self.date(2026, 11, 1, 0, 1)
        )
    }

    @Test("Due once each day after 12:01 am") func isDue() {
        let saved = Self.date(2026, 10, 31, 0, 1)
        #expect(LogAutoSave.isDue(now: Self.date(2026, 10, 31, 9, 0), lastSlot: nil, calendar: Self.calendar))
        #expect(!LogAutoSave.isDue(now: Self.date(2026, 10, 31, 23, 59), lastSlot: saved, calendar: Self.calendar))
        #expect(!LogAutoSave.isDue(now: Self.date(2026, 11, 1, 0, 0, 30), lastSlot: saved, calendar: Self.calendar))
        #expect(LogAutoSave.isDue(now: Self.date(2026, 11, 1, 0, 1), lastSlot: saved, calendar: Self.calendar))
        // Missed days are caught up with a single save
        #expect(LogAutoSave.isDue(now: Self.date(2026, 11, 4, 8, 0), lastSlot: saved, calendar: Self.calendar))
    }

    @Test("Slot survives the daylight saving change") func daylightSaving() {
        // Clocks go back at 2 am on 1 November 2026 in New York
        let slot = LogAutoSave.latestSlot(atOrBefore: Self.date(2026, 11, 1, 12, 0), calendar: Self.calendar)
        #expect(slot == Self.date(2026, 11, 1, 0, 1))
        #expect(LogAutoSave.isDue(now: Self.date(2026, 11, 2, 0, 1), lastSlot: slot, calendar: Self.calendar))
    }

    @Test("File is named after the local date it is saved") func fileName() {
        #expect(LogAutoSave.fileName(for: Self.date(2026, 11, 1, 0, 1), timeZone: Self.timeZone) == "2026-11-01.zip")
        #expect(LogAutoSave.fileName(for: Self.date(2026, 1, 5, 23, 59), timeZone: Self.timeZone) == "2026-01-05.zip")
    }
}
