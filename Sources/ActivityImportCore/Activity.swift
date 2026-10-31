import Foundation
import CryptoKit

public enum Sport: String, Codable, Sendable {
    case running, cycling

    public var title: String { self == .running ? "Run" : "Ride" }
    public var symbol: String { self == .running ? "figure.run" : "figure.outdoor.cycle" }
}

public struct TrackPoint: Sendable, Equatable {
    public let date: Date
    public let latitude: Double?
    public let longitude: Double?
    public let altitude: Double?
    public let heartRate: Double?
}

public struct Activity: Identifiable, Sendable {
    public let sport: Sport
    public let start: Date
    public let end: Date
    /// TCX lap timer duration, which may exclude pauses. Never substitute moving time.
    public let duration: TimeInterval
    public let distance: Double
    public let points: [TrackPoint]

    /// Stable across file names, whitespace, time-zone notation and measurement corrections.
    public var id: String {
        let input = "tcx-v1|\(sport.rawValue)|\(Int64((start.timeIntervalSince1970 * 1000).rounded()))"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var routePoints: [TrackPoint] { points.filter { $0.latitude != nil && $0.longitude != nil } }
    public var heartRatePoints: [TrackPoint] { points.filter { $0.heartRate != nil } }
}

public enum DuplicatePolicy {
    /// Deliberately conservative: ambiguous overlaps require review, never an automatic overwrite.
    public static func matches(sport: Sport, start: Date, end: Date, candidate: Activity) -> Bool {
        guard sport == candidate.sport else { return false }
        if abs(start.timeIntervalSince(candidate.start)) <= 120 { return true }
        let overlap = min(end, candidate.end).timeIntervalSince(max(start, candidate.start))
        let shorter = min(end.timeIntervalSince(start), candidate.end.timeIntervalSince(candidate.start))
        return shorter > 0 && overlap / shorter >= 0.8
    }
}

public struct ImportProblem: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
