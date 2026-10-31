import Foundation

public struct ActivityQuery: Equatable, Sendable {
    public let after: Date?
    public let before: Date

    public init(after: Date? = nil, before: Date) { self.after = after; self.before = before }

    public static func days(from start: Date, through end: Date, calendar: Calendar = .current) -> Self {
        let lower = calendar.startOfDay(for: start)
        let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        return Self(after: lower, before: upper)
    }

    public static func month(containing date: Date, calendar: Calendar = .current) -> Self {
        let month = calendar.dateInterval(of: .month, for: date)!
        return Self(after: month.start, before: month.end)
    }

    public func contains(_ date: Date) -> Bool { date < before && (after.map { date >= $0 } ?? true) }
}
