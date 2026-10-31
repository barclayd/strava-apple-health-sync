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

    private func distanceType(_ sport: Sport) -> HKQuantityType {
        HKQuantityType(sport == .running ? .distanceWalkingRunning : .distanceCycling)
    }

    func authorise(for activity: Activity) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ImportProblem("Apple Health is unavailable on this device.") }
        var writes: Set<HKSampleType> = [workoutType, distanceType(activity.sport)]
        if !activity.heartRatePoints.isEmpty { writes.insert(heartType) }
        if !activity.routePoints.isEmpty { writes.insert(routeType) }
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
        // TCX gives timer duration but not exact pause events. The explicit-duration initializer preserves
        // the original timer AND elapsed interval without inventing a pause timeline. See README.
        let workout = HKWorkout(activityType: activity.sport == .running ? .running : .cycling,
                                start: activity.start, end: activity.end, duration: activity.duration,
                                totalEnergyBurned: nil, totalDistance: HKQuantity(unit: .meter(), doubleValue: activity.distance),
                                metadata: metadata("workout"))
        try await store.save(workout)
        var measurements: [HKSample] = [HKQuantitySample(type: distanceType(activity.sport),
            quantity: HKQuantity(unit: .meter(), doubleValue: activity.distance), start: activity.start,
            end: activity.end, metadata: metadata("distance"))]
        for (index, point) in activity.heartRatePoints.enumerated() {
            measurements.append(HKQuantitySample(type: heartType,
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: point.heartRate!),
                start: point.date, end: point.date, metadata: metadata("heart.\(index)")))
        }
        // Keep batches small; each sample is tagged before saving so interrupted writes are recoverable.
        for offset in stride(from: 0, to: measurements.count, by: 500) {
            try await store.addSamples(Array(measurements[offset..<min(offset + 500, measurements.count)]), to: workout)
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
        let optionalTypes: [HKSampleType] = [routeType, heartType]
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
