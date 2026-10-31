import Foundation

public struct StravaActivity: Decodable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let sportType: String
    public let startDate: Date
    public let elapsedTime: Int
    public let movingTime: Int
    public let distance: Double
    public let manual: Bool?
    public let deviceName: String?
    public let calories: Double?
    public let totalElevationGain: Double?
    public let trainer: Bool?
    public let deviceWatts: Bool?
    public let averageWatts: Double?
    public let maxWatts: Double?
    public let averageCadence: Double?
    public let averageSpeed: Double?
    public let maxSpeed: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, distance, manual, calories, trainer
        case sportType = "sport_type", startDate = "start_date", elapsedTime = "elapsed_time"
        case movingTime = "moving_time", deviceName = "device_name"
        case totalElevationGain = "total_elevation_gain", deviceWatts = "device_watts"
        case averageWatts = "average_watts", maxWatts = "max_watts", averageCadence = "average_cadence"
        case averageSpeed = "average_speed", maxSpeed = "max_speed"
    }

    public var sport: Sport? {
        switch sportType {
        case "Run", "TrailRun", "VirtualRun": .running
        case "Ride", "MountainBikeRide", "GravelRide", "VirtualRide", "EBikeRide", "EMountainBikeRide", "Velomobile": .cycling
        default: nil
        }
    }

    public func activity(streams: StravaStreams) throws -> Activity {
        guard id > 0, let sport, elapsedTime > 0, elapsedTime <= 604_800,
              movingTime >= 0, movingTime <= elapsedTime,
              distance.isFinite, distance >= 0, distance <= 10_000_000,
              startDate.timeIntervalSince1970.isFinite else {
            throw ImportProblem("This activity has an unsupported sport or invalid measurements. This trial supports runs and rides.")
        }
        let points = try streams.points(start: startDate, elapsed: elapsedTime)
        var result = Activity(sport: sport, start: startDate,
                              end: startDate.addingTimeInterval(Double(elapsedTime)),
                              duration: Double(elapsedTime), distance: distance, points: points)
        result.stravaID = id
        if let calories {
            guard calories.isFinite, (0...100_000).contains(calories) else { throw ImportProblem("Strava returned invalid calories.") }
            result.stravaCalories = calories > 0 ? calories : nil
        }
        if let totalElevationGain {
            guard totalElevationGain.isFinite, (0...100_000).contains(totalElevationGain) else { throw ImportProblem("Strava returned invalid elevation gain.") }
            result.elevationGain = totalElevationGain
        }
        result.indoor = trainer ?? (sportType == "VirtualRide" || sportType == "VirtualRun" ? true : nil)
        result.powerIsEstimated = deviceWatts != true
        if streams.hasOriginalTiming {
            result.pauses = StravaPauses.detect(in: points)
            // An all-stationary or inconsistent recording must not become a zero-length workout.
            if result.pausedDuration >= result.duration { result.pauses = [] }
        }
        return result
    }
}

public struct StravaStreams: Decodable, Sendable {
    public struct Stream<Value: Decodable & Sendable>: Decodable, Sendable {
        let data: [Value]
        let originalSize: Int
        let resolution: String
        let seriesType: String
        enum CodingKeys: String, CodingKey {
            case data, resolution
            case originalSize = "original_size", seriesType = "series_type"
        }
    }
    let time: Stream<Double>?
    let latlng: Stream<[Double]>?
    let altitude: Stream<Double>?
    let heartrate: Stream<Double>?
    let watts: Stream<Double>?
    let cadence: Stream<Double>?
    let velocitySmooth: Stream<Double>?
    let moving: Stream<Bool>?
    let distance: Stream<Double>?
    enum CodingKeys: String, CodingKey {
        case time, latlng, altitude, heartrate, watts, cadence, moving, distance
        case velocitySmooth = "velocity_smooth"
    }

    public static var empty: Self { Self(time: nil, latlng: nil, altitude: nil, heartrate: nil, watts: nil, cadence: nil, velocitySmooth: nil, moving: nil, distance: nil) }

    var hasOriginalTiming: Bool { time.map { $0.originalSize == $0.data.count } ?? false }

    func points(start: Date, elapsed: Int) throws -> [TrackPoint] {
        guard let time else {
            guard latlng == nil, altitude == nil, heartrate == nil, watts == nil, cadence == nil, velocitySmooth == nil, moving == nil, distance == nil else {
                throw ImportProblem("Strava did not supply timestamps for the recorded samples.")
            }
            return []
        }
        guard !time.data.isEmpty, time.data.count <= 100_000 else {
            throw ImportProblem("This activity exceeds the trial’s sample limit or has an empty time stream.")
        }
        func aligned<T>(_ stream: Stream<T>?) throws {
            guard let stream else { return }
            guard stream.data.count == time.data.count, stream.originalSize == time.originalSize,
                  stream.resolution == time.resolution, stream.seriesType == time.seriesType else {
                throw ImportProblem("Strava’s sample streams do not align. Nothing has been imported.")
            }
        }
        try aligned(latlng); try aligned(altitude); try aligned(heartrate)
        try aligned(watts); try aligned(cadence); try aligned(velocitySmooth)
        try aligned(moving); try aligned(distance)
        var previous = -1.0
        var previousDistance = -1.0
        return try time.data.enumerated().map { index, offset in
            guard offset.isFinite, offset >= 0, offset <= Double(elapsed), offset > previous else {
                throw ImportProblem("Strava returned invalid or unordered sample timestamps.")
            }
            previous = offset
            let location = latlng?.data[index]
            if let location {
                guard location.count == 2, location.allSatisfy(\.isFinite),
                      (-90...90).contains(location[0]), (-180...180).contains(location[1]) else {
                    throw ImportProblem("Strava returned an invalid route coordinate.")
                }
            }
            let elevation = altitude?.data[index]
            let heart = heartrate?.data[index]
            if let elevation, !elevation.isFinite || !(-12_000...100_000).contains(elevation) {
                throw ImportProblem("Strava returned an invalid elevation.")
            }
            if let heart, !heart.isFinite || !(0...300).contains(heart) {
                throw ImportProblem("Strava returned an invalid heart-rate sample.")
            }
            func measurement(_ stream: Stream<Double>?, maximum: Double) throws -> Double? {
                guard let value = stream?.data[index] else { return nil }
                guard value.isFinite, (0...maximum).contains(value) else {
                    throw ImportProblem("Strava returned an invalid cycling measurement.")
                }
                return value
            }
            var point = TrackPoint(date: start.addingTimeInterval(offset), latitude: location?.first,
                                   longitude: location?.last, altitude: elevation, heartRate: heart == 0 ? nil : heart)
            point.power = try measurement(watts, maximum: 10_000)
            point.cadence = try measurement(cadence, maximum: 400)
            point.speed = try measurement(velocitySmooth, maximum: 150)
            point.moving = moving?.data[index]
            point.cumulativeDistance = try measurement(distance, maximum: 10_000_000)
            if let value = point.cumulativeDistance {
                guard value >= previousDistance else { throw ImportProblem("Strava returned an unordered distance stream.") }
                previousDistance = value
            }
            return point
        }
    }
}

public enum StravaJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(type, from: data) }
        catch { throw ImportProblem("Strava returned an unreadable response. Nothing has been imported.") }
    }
}
