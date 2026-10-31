import Foundation
import HealthKit
import CoreLocation
import ActivityImportCore

@MainActor final class HealthWriter {
    private let store = HKHealthStore()
    private static let batchKey = "com.barclayd.healthimport.batch"
    private static let activityKey = "com.barclayd.healthimport.activity"
    private let workoutType = HKObjectType.workoutType()
    private let heartType = HKQuantityType(.heartRate)
    private let routeType = HKSeriesType.workoutRoute()
    private let energyType = HKQuantityType(.activeEnergyBurned)
    private let powerType = HKQuantityType(.cyclingPower)
    private let cadenceType = HKQuantityType(.cyclingCadence)
    private let speedType = HKQuantityType(.cyclingSpeed)

    private func distanceType(_ sport: Sport) -> HKQuantityType {
        HKQuantityType(sport == .running ? .distanceWalkingRunning : .distanceCycling)
    }

    func authorise(for activity: Activity) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ImportProblem("Apple Health is unavailable on this device.") }
        var writes: Set<HKSampleType> = [workoutType, distanceType(activity.sport)]
        if !activity.heartRatePoints.isEmpty { writes.insert(heartType) }
        if !activity.routePoints.isEmpty { writes.insert(routeType) }
        if activity.activeEnergy != nil { writes.insert(energyType) }
        if activity.sport == .cycling {
            if !activity.powerPoints.isEmpty { writes.insert(powerType) }
            if !activity.cadencePoints.isEmpty { writes.insert(cadenceType) }
            if !activity.speedPoints.isEmpty { writes.insert(speedType) }
        }
        try await store.requestAuthorization(toShare: writes, read: [workoutType])
        guard writes.allSatisfy({ store.authorizationStatus(for: $0) == .sharingAuthorized }) else {
            throw ImportProblem("Allow writing all the data shown in this preview before importing. Nothing has been saved.")
        }
        // Successful authorisation does NOT establish read permission. The UI explains this separately.
    }

    func hasDuplicate(_ activity: Activity) async throws -> Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let dates = try await store.earliestAuthorizedSampleDate(for: [workoutType])
            if let earliest = dates[workoutType], activity.start < earliest {
                throw ImportProblem("Health access is limited to recent workouts. Allow all recorded workout data in Health settings before importing this older activity.")
            }
        }
        #endif
        let sameID = HKQuery.predicateForObjects(withMetadataKey: Self.activityKey, allowedValues: [activity.id])
        if !(try await samples(type: workoutType, predicate: sameID)).isEmpty { return true }
        let nearDate = HKQuery.predicateForSamples(withStart: activity.start.addingTimeInterval(-120),
                                                  end: activity.end.addingTimeInterval(120), options: [])
        let existing = try await samples(type: workoutType, predicate: nearDate)
        return existing.compactMap { $0 as? HKWorkout }.contains { workout in
            let sport: Sport?
            switch workout.workoutActivityType {
            case .running: sport = .running
            case .cycling: sport = .cycling
            default: sport = nil
            }
            guard let sport else { return false }
            return DuplicatePolicy.matches(sport: sport, start: workout.startDate, end: workout.endDate, candidate: activity)
        }
    }

    func save(_ activity: Activity, record: ImportRecord) async throws {
        func metadata(_ suffix: String) -> [String: Any] {
            [Self.batchKey: record.id.uuidString, Self.activityKey: activity.id,
             HKMetadataKeySyncIdentifier: "healthimport.\(activity.id).\(suffix)", HKMetadataKeySyncVersion: 1]
        }
        var measurements: [HKSample] = [HKQuantitySample(type: distanceType(activity.sport),
            quantity: HKQuantity(unit: .meter(), doubleValue: activity.distance), start: activity.start,
            end: activity.end, metadata: metadata("distance"))]
        for (index, point) in activity.heartRatePoints.enumerated() {
            measurements.append(HKQuantitySample(type: heartType,
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: point.heartRate!),
                start: point.date, end: point.date, metadata: metadata("heart.\(index)")))
        }
        if let calories = activity.activeEnergy {
            guard calories.isFinite, calories > 0, calories <= 100_000 else { throw ImportProblem("Invalid active energy.") }
            var energyMetadata = metadata("energy")
            energyMetadata["com.barclayd.healthimport.energyInterpretation"] = "Strava calories, confirmed as active energy by user"
            measurements.append(HKQuantitySample(type: energyType, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: calories),
                start: activity.start, end: activity.end, metadata: energyMetadata))
        }
        if activity.sport == .cycling {
            let speedUnit = HKUnit.meter().unitDivided(by: .second())
            let cadenceUnit = HKUnit.count().unitDivided(by: .minute())
            for (index, point) in activity.points.enumerated() {
                let values: [(Double?, HKQuantityType, HKUnit, String)] = [
                    (point.power, powerType, .watt(), "power"),
                    (point.cadence, cadenceType, cadenceUnit, "cadence"),
                    (point.speed, speedType, speedUnit, "speed")
                ]
                for (value, type, unit, suffix) in values {
                    guard let value else { continue }
                    var sampleMetadata = metadata("\(suffix).\(index)")
                    if suffix == "power" { sampleMetadata["com.barclayd.healthimport.stravaEstimatedPower"] = activity.powerIsEstimated }
                    measurements.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                        start: point.date, end: point.date, metadata: sampleMetadata))
                }
            }
        }
        var workoutMetadata = metadata("workout")
        if let indoor = activity.indoor { workoutMetadata[HKMetadataKeyIndoorWorkout] = indoor }
        if let elevation = activity.elevationGain { workoutMetadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: elevation) }
        let workout: HKWorkout
        if activity.stravaID != nil {
            // Strava elapsed duration matches the collected interval. A builder also produces native
            // workout statistics for energy, power, cadence and speed from the imported samples.
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = activity.sport == .cycling ? .cycling : .running
            configuration.locationType = activity.indoor == true ? .indoor : activity.indoor == false || !activity.routePoints.isEmpty ? .outdoor : .unknown
            let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: nil)
            do {
                try await builder.beginCollection(at: activity.start)
                try await builder.addMetadata(workoutMetadata)
                for offset in stride(from: 0, to: measurements.count, by: 500) {
                    try await builder.addSamples(Array(measurements[offset..<min(offset + 500, measurements.count)]))
                }
                try await builder.endCollection(at: activity.end)
                guard let result = try await builder.finishWorkout() else { throw ImportProblem("Health did not return the saved workout.") }
                workout = result
            } catch { builder.discardWorkout(); throw error }
        } else {
            // TCX timer duration can differ from elapsed time without supplying a pause timeline.
            workout = HKWorkout(activityType: activity.sport == .running ? .running : .cycling,
                start: activity.start, end: activity.end, duration: activity.duration,
                totalEnergyBurned: nil, totalDistance: HKQuantity(unit: .meter(), doubleValue: activity.distance), metadata: workoutMetadata)
            try await store.save(workout)
            for offset in stride(from: 0, to: measurements.count, by: 500) {
                try await store.addSamples(Array(measurements[offset..<min(offset + 500, measurements.count)]), to: workout)
            }
        }
        if !activity.routePoints.isEmpty {
            let builder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
            let locations = activity.routePoints.map { point in
                CLLocation(coordinate: CLLocationCoordinate2D(latitude: point.latitude!, longitude: point.longitude!),
                           altitude: point.altitude ?? 0, horizontalAccuracy: -1, verticalAccuracy: -1,
                           timestamp: point.date)
            }
            for offset in stride(from: 0, to: locations.count, by: 500) {
                try await builder.insertRouteData(Array(locations[offset..<min(offset + 500, locations.count)]))
            }
            _ = try await builder.finishRoute(with: workout, metadata: metadata("route"))
        }
    }

    /// Delete only this app's records carrying the selected transaction marker. Other sources are untouched.
    func undo(_ record: ImportRecord) async throws {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: Self.batchKey, allowedValues: [record.id.uuidString])
        ])
        // Associated samples are removed explicitly; deleting a workout alone does not remove all its data.
        let optionalTypes: [HKSampleType] = [routeType, heartType, energyType, powerType, cadenceType, speedType]
        let types = optionalTypes.filter { store.authorizationStatus(for: $0) != .notDetermined }
            + [distanceType(record.sport), workoutType]
        for type in types {
            // A type unused in this import may never have been authorised. Querying our own samples is allowed.
            let owned = try await samples(type: type, predicate: predicate)
            if !owned.isEmpty { try await store.delete(owned) }
        }
    }

    private func samples(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                        sortDescriptors: nil) { _, result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result ?? []) }
            })
        }
    }
}
