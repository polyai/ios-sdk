//  MessageTimestamp.swift
//  Examples/UIKit/07-Playground
//
//  Timestamp grouping decisions (iMessage-style ~5 min gap). Ported verbatim
//  from the SwiftUI 07 helper — pure Foundation.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import Foundation

enum MessageTimestamp {

    /// Matches iMessage's ~5 min grouping threshold.
    static let groupGapSeconds: TimeInterval = 5 * 60

    // Cached — DateFormatter is expensive and chat views recompute on every scroll.
    private static let compactFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    static func compactTime(_ date: Date) -> String {
        compactFormatter.string(from: date)
    }

    static func groupHeader(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = compactFormatter.string(from: date)
        if calendar.isDateInToday(date) {
            return time
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(time)"
        }
        if let weekStart = calendar.date(byAdding: .day, value: -6, to: now), date >= weekStart {
            let weekday = DateFormatter.weekdayShort.string(from: date)
            return "\(weekday) \(time)"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            let md = DateFormatter.monthDay.string(from: date)
            return "\(md), \(time)"
        }
        let mdy = DateFormatter.monthDayYear.string(from: date)
        return "\(mdy), \(time)"
    }

    static func shouldInsertSeparator(previous: Date?, current: Date) -> Bool {
        guard let previous else { return true }
        return current.timeIntervalSince(previous) > groupGapSeconds
    }
}

private extension DateFormatter {
    static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static let monthDayYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return f
    }()
}
