import Foundation

public enum ImportScope: String, CaseIterable, Sendable {
    case all = "All history"
    case individual = "Individual"
    case dates = "Date range"
}

public struct ActivitySelection: Equatable, Sendable {
    public var scope: ImportScope = .all
    public var ids: Set<Int64> = []
    public var start: Date
    public var end: Date

    public init(now: Date = Date(), calendar: Calendar = .current) {
        end = now
        start = calendar.date(byAdding: .month, value: -1, to: now) ?? now
    }

    /// Date pickers select whole local days, including 23/25-hour daylight-saving days.
    public func activities(in values: [StravaActivity], calendar: Calendar = .current) -> [StravaActivity] {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        let upper = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return values.filter { activity in
            guard activity.sport != nil else { return false }
            switch scope {
            case .all: return true
            case .individual: return ids.contains(activity.id)
            case .dates: return first <= last && activity.startDate >= first && activity.startDate < upper
            }
        }
    }
}
