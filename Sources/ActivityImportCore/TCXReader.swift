import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum TCXReader {
    public static let maximumBytes = 20 * 1024 * 1024

    public static func read(_ data: Data) throws -> [Activity] {
        guard data.count <= maximumBytes else { throw ImportProblem("Choose a TCX file smaller than 20 MB.") }
        // Only UTF-8 input is supported. Reject document types before the XML parser can expand entities.
        guard let xml = String(data: data, encoding: .utf8),
              !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else {
            throw ImportProblem("Use a UTF-8 TCX file without document types or entities.")
        }
        let delegate = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.problem == nil else {
            throw delegate.problem ?? ImportProblem("This TCX file is incomplete or malformed.")
        }
        guard !delegate.activities.isEmpty else { throw ImportProblem("No activities were found in this TCX file.") }
        return delegate.activities
    }
}

private final class Reader: NSObject, XMLParserDelegate {
    var activities: [Activity] = []
    var problem: ImportProblem?
    private var stack: [String] = []
    private var text = ""
    private var sport: Sport?
    private var start: Date?
    private var laps: [(Date, Double, Double)] = []
    private var lapStart: Date?
    private var lapTime: Double?
    private var lapDistance: Double?
    private var points: [TrackPoint] = []
    private var pointDate: Date?
    private var latitude: Double?
    private var longitude: Double?
    private var altitude: Double?
    private var heartRate: Double?
    private var totalPoints = 0

    private func fail(_ parser: XMLParser, _ message: String) {
        problem = ImportProblem(message)
        parser.abortParsing()
    }

    private func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func number(_ value: String) -> Double? {
        guard let value = Double(value), value.isFinite else { return nil }
        return value
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        stack.append(name)
        text = ""
        guard stack.count <= 40 else { return fail(parser, "This TCX file is too deeply nested.") }
        switch name {
        case "Activity":
            guard stack.suffix(3) == ["TrainingCenterDatabase", "Activities", "Activity"] else {
                return fail(parser, "Expected a TCX activity export.")
            }
            guard activities.count < 100 else { return fail(parser, "Import up to 100 activities at a time.") }
            switch attributes["Sport"] {
            case "Running": sport = .running
            case "Biking": sport = .cycling
            default: return fail(parser, "This POC supports TCX runs and rides. Other sports need an explicit mapping.")
            }
            start = nil; laps = []; points = []
        case "Lap" where stack.dropLast().last == "Activity":
            lapStart = attributes["StartTime"].flatMap(date)
            lapTime = nil; lapDistance = nil
        case "Trackpoint":
            pointDate = nil; latitude = nil; longitude = nil; altitude = nil; heartRate = nil
            totalPoints += 1
            if totalPoints > 100_000 { fail(parser, "Import up to 100,000 track points at a time.") }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.dropLast().last
        defer { stack.removeLast(); text = "" }
        switch name {
        case "Id" where parent == "Activity": start = date(value)
        case "TotalTimeSeconds" where parent == "Lap": lapTime = number(value)
        case "DistanceMeters" where parent == "Lap": lapDistance = number(value)
        case "Time" where parent == "Trackpoint": pointDate = date(value)
        case "LatitudeDegrees" where parent == "Position":
            latitude = number(value)
            if latitude == nil { fail(parser, "A latitude is not a finite number.") }
        case "LongitudeDegrees" where parent == "Position":
            longitude = number(value)
            if longitude == nil { fail(parser, "A longitude is not a finite number.") }
        case "AltitudeMeters" where parent == "Trackpoint":
            altitude = number(value)
            if altitude == nil { fail(parser, "An altitude is not a finite number.") }
        case "Value" where parent == "HeartRateBpm" && stack.contains("Trackpoint"):
            heartRate = number(value)
            if heartRate == nil || !(1...300).contains(heartRate!) { fail(parser, "A heart-rate sample is invalid.") }
        case "Trackpoint":
            guard let pointDate else { return fail(parser, "A track point is missing a valid timestamp.") }
            if (latitude == nil) != (longitude == nil) ||
                latitude.map({ !(-90...90).contains($0) }) == true ||
                longitude.map({ !(-180...180).contains($0) }) == true {
                return fail(parser, "A track point has invalid coordinates.")
            }
            if let previous = points.last, pointDate <= previous.date {
                return fail(parser, "Track-point timestamps must increase without duplicates.")
            }
            points.append(TrackPoint(date: pointDate, latitude: latitude, longitude: longitude,
                                     altitude: altitude, heartRate: heartRate))
        case "Lap" where parent == "Activity":
            guard let lapStart, let lapTime, lapTime > 0, let lapDistance, lapDistance >= 0 else {
                return fail(parser, "Each lap needs a valid start time, positive duration and non-negative distance.")
            }
            if let previous = laps.last, lapStart < previous.0.addingTimeInterval(previous.1 - 1) {
                return fail(parser, "The lap timestamps overlap or are out of order.")
            }
            laps.append((lapStart, lapTime, lapDistance))
        case "Activity":
            guard let sport, let start, !laps.isEmpty,
                  abs(laps[0].0.timeIntervalSince(start)) <= 1 else {
                return fail(parser, "The activity needs a timestamp matching its first lap.")
            }
            let duration = laps.reduce(0) { $0 + $1.1 }
            let distance = laps.reduce(0) { $0 + $1.2 }
            let lastLap = laps.last!
            let end = max(lastLap.0.addingTimeInterval(lastLap.1), points.last?.date ?? start)
            guard duration.isFinite, distance.isFinite, duration <= 7 * 86400,
                  end.timeIntervalSince(start) <= 7 * 86400,
                  duration <= end.timeIntervalSince(start) + 1,
                  start <= Date(), end <= Date(),
                  points.first.map({ $0.date >= start }) ?? true else {
                return fail(parser, "The activity has inconsistent dates or duration, or is longer than seven days.")
            }
            activities.append(Activity(sport: sport, start: start, end: end,
                                       duration: duration, distance: distance, points: points))
        default: break
        }
    }
}
