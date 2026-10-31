import Foundation

/// This is an import interpretation, not a reconstruction of Garmin's timer events.
/// Keep timestamps intact; HealthKit pause/resume events describe the inactive intervals.
enum StravaPauses {
    static func detect(in points: [TrackPoint]) -> [DateInterval] {
        guard points.count >= 3 else { return [] }
        let intervals = zip(points, points.dropFirst()).map { $1.date.timeIntervalSince($0.date) }.sorted()
        let cadence = intervals[(intervals.count - 1) / 2]
        // Sparse or downsampled tracks don't locate a break accurately enough.
        guard cadence > 0, cadence <= 10 else { return [] }
        let gapThreshold = max(30, cadence * 10)
        var result: [DateInterval] = []
        for (first, next) in zip(points, points.dropFirst()) {
            let gap = next.date.timeIntervalSince(first.date)
            let start: Date
            if gap >= gapThreshold {
                // A long recording gap can also be a signal outage during movement.
                // Require <=20 m of travel before interpreting it as a stationary break.
                guard stationary(first, next) else { continue }
                start = first.moving == false ? first.date : first.date.addingTimeInterval(cadence)
            } else {
                guard first.moving == false else { continue }
                start = first.date
            }
            guard start < next.date else { continue }
            if let last = result.last, start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: next.date)
            } else { result.append(DateInterval(start: start, end: next.date)) }
        }
        return result
    }

    private static func stationary(_ first: TrackPoint, _ next: TrackPoint) -> Bool {
        if let a = first.cumulativeDistance, let b = next.cumulativeDistance {
            return b >= a && b - a <= 20
        }
        guard let aLat = first.latitude, let aLon = first.longitude,
              let bLat = next.latitude, let bLon = next.longitude else { return false }
        let radians = Double.pi / 180
        let latitude = sin((bLat - aLat) * radians / 2)
        let longitude = sin((bLon - aLon) * radians / 2)
        let haversine = latitude * latitude + cos(aLat * radians) * cos(bLat * radians) * longitude * longitude
        let metres = 6_371_000 * 2 * asin(sqrt(min(1, max(0, haversine))))
        return metres <= 20
    }
}
