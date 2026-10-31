import Foundation

/// Shared app quotas include Stitch. Leave headroom and pause instead of retrying in a loop.
struct StravaRequestBudget {
    private(set) var resumeAfter: Date?

    mutating func observe(_ response: StravaResponse, at date: Date) {
        var waitUntil = date
        for prefix in ["x-ratelimit", "x-readratelimit"] {
            guard let limits = pair(response.headers["\(prefix)-limit"]),
                  limits.allSatisfy({ $0 > 0 }),
                  let usage = pair(response.headers["\(prefix)-usage"]) else { continue }
            if usage[0] >= limits[0] - max(1, limits[0] / 10) {
                waitUntil = max(waitUntil, boundary(after: date, seconds: 900))
            }
            if usage[1] >= limits[1] - max(1, limits[1] / 10) {
                waitUntil = max(waitUntil, boundary(after: date, seconds: 86_400))
            }
        }
        if response.status == 429 { waitUntil = max(waitUntil, boundary(after: date, seconds: 900)) }
        if waitUntil > date { resumeAfter = max(resumeAfter ?? date, waitUntil) }
    }

    func check(at date: Date) throws {
        if let resumeAfter, date < resumeAfter {
            throw ImportProblem("Strava’s shared request budget is nearly used. Resume after \(resumeAfter.formatted(date: .abbreviated, time: .shortened)). Completed imports are kept.")
        }
    }

    private func pair(_ value: String?) -> [Int]? {
        guard let value else { return nil }
        let values = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return values.count == 2 && values.allSatisfy { $0 >= 0 } ? values : nil
    }

    private func boundary(after date: Date, seconds: Double) -> Date {
        Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / seconds) + 1) * seconds + 1)
    }
}
