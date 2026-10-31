import XCTest
import HealthKit
import CoreLocation
import ActivityImportCore
@testable import HealthImport

final class HealthWriterTests: XCTestCase {
    @MainActor func testCyclingStatisticsAndScopedUndo() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic write tests must only run in a simulator.")
        #else
        let store = HKHealthStore()
        let types: [HKSampleType] = [HKObjectType.workoutType(), HKQuantityType(.distanceCycling),
            HKQuantityType(.activeEnergyBurned), HKQuantityType(.cyclingPower), HKQuantityType(.cyclingCadence),
            HKQuantityType(.cyclingSpeed), HKQuantityType(.heartRate), HKSeriesType.workoutRoute()]
        try XCTSkipUnless(types.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized },
            "First import the synthetic ride with active energy enabled in this simulator.")
        let detailURL = try XCTUnwrap(Bundle.main.url(forResource: "synthetic-ride", withExtension: "json"))
        let streamsURL = try XCTUnwrap(Bundle.main.url(forResource: "synthetic-ride-streams", withExtension: "json"))
        let detail = try String(contentsOf: detailURL, encoding: .utf8).replacingOccurrences(of: "2018-", with: "2015-")
        let source = try StravaJSON.decode(StravaActivity.self, from: Data(detail.utf8))
        let streams = try StravaJSON.decode(StravaStreams.self, from: Data(contentsOf: streamsURL))
        var activity = try source.activity(streams: streams)
        activity.activeEnergy = activity.stravaCalories
        activity.stravaID = 987654322
        let record = ImportRecord(activity: activity)
        let writer = HealthWriter()
        do {
            try await writer.save(activity, record: record)
            let saved = try await query(store, HKObjectType.workoutType(), record)
            let workout = try XCTUnwrap(saved.first as? HKWorkout)
            XCTAssertEqual(workout.duration, 120, accuracy: 0.01)
            XCTAssertEqual(workout.workoutActivityType, .cycling)
            XCTAssertEqual(workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()), 20)
            XCTAssertEqual(workout.statistics(for: HKQuantityType(.cyclingPower))?.maximumQuantity()?.doubleValue(for: .watt()), 200)
            XCTAssertEqual((workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()), 8)
            for type in [HKQuantityType(.cyclingPower), HKQuantityType(.cyclingCadence), HKQuantityType(.cyclingSpeed)] {
                let samples = try await query(store, type, record)
                XCTAssertEqual(samples.count, 4)
            }
            let routes = try await query(store, HKSeriesType.workoutRoute(), record)
            let route = try XCTUnwrap(routes.first as? HKWorkoutRoute)
            let locations = try await routeLocations(store, route)
            XCTAssertEqual(locations.map(\.altitude), [10, 12, 15, 18])
            XCTAssertEqual(locations.map(\.timestamp), activity.routePoints.map(\.date))
            XCTAssertTrue(locations.allSatisfy { $0.verticalAccuracy > 0 && $0.horizontalAccuracy > 0 },
                          "Fitness must receive valid altitude samples to display an elevation profile")
            XCTAssertEqual(route.metadata?["com.barclayd.healthimport.routeAccuracySource"] as? String,
                           "Import assumption; recording accuracy unavailable")
            XCTAssertEqual(route.metadata?["com.barclayd.healthimport.assumedRouteAccuracyMeters"] as? Double, 50)
            try await writer.undo(record)
            for type in types { let remaining = try await query(store, type, record); XCTAssertTrue(remaining.isEmpty) }
        } catch { try? await writer.undo(record); throw error }
        #endif
    }

    @MainActor func testHistoricImportDuplicateAndScopedUndo() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic write tests must only run in a simulator.")
        #else
        let store = HKHealthStore()
        let required: [HKSampleType] = [HKObjectType.workoutType(), HKQuantityType(.distanceWalkingRunning),
                                       HKQuantityType(.heartRate), HKSeriesType.workoutRoute()]
        try XCTSkipUnless(required.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized },
                          "First import the synthetic example in this simulator and allow Health access.")
        let url = try XCTUnwrap(Bundle.main.url(forResource: "historic-run", withExtension: "tcx"))
        // Sea-level and below-sea-level altitudes are valid; an absent reading is not zero.
        let xml = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "<AltitudeMeters>20</AltitudeMeters>", with: "<AltitudeMeters>-5</AltitudeMeters>")
            .replacingOccurrences(of: "<AltitudeMeters>21</AltitudeMeters>", with: "<AltitudeMeters>0</AltitudeMeters>")
            .replacingOccurrences(of: "<AltitudeMeters>22</AltitudeMeters>", with: "")
        let first = try XCTUnwrap(TCXReader.read(Data(xml.replacingOccurrences(of: "2018-", with: "2016-").utf8)).first)
        let second = try XCTUnwrap(TCXReader.read(Data(xml.replacingOccurrences(of: "2018-", with: "2017-").utf8)).first)
        let record = ImportRecord(activity: first)
        let sentinel = ImportRecord(activity: second)
        let writer = HealthWriter()
        do {
            let before = try await writer.hasDuplicate(first)
            XCTAssertFalse(before)
            try await writer.save(first, record: record)
            let duplicate = try await writer.hasDuplicate(first)
            XCTAssertTrue(duplicate)
            let workouts = try await query(store, HKObjectType.workoutType(), record)
            let workout = try XCTUnwrap(workouts.first as? HKWorkout)
            XCTAssertEqual(workouts.count, 1)
            XCTAssertEqual(workout.startDate, first.start)
            XCTAssertEqual(workout.duration, first.duration, accuracy: 0.01)
            let distance = try await query(store, HKQuantityType(.distanceWalkingRunning), record)
            XCTAssertEqual(distance.count, 1)
            XCTAssertEqual((distance.first as? HKQuantitySample)?.quantity.doubleValue(for: .meter()), 5000)
            let heart = try await query(store, HKQuantityType(.heartRate), record)
            XCTAssertEqual(heart.count, 4)
            let routes = try await query(store, HKSeriesType.workoutRoute(), record)
            XCTAssertEqual(routes.count, 1)
            XCTAssertEqual((routes.first as? HKWorkoutRoute)?.count, 4)
            let locations = try await routeLocations(store, XCTUnwrap(routes.first as? HKWorkoutRoute))
            XCTAssertEqual(locations.count, 4)
            XCTAssertEqual(locations.filter { $0.verticalAccuracy > 0 }.map(\.altitude), [-5, 0, -5])
            XCTAssertLessThan(try XCTUnwrap(locations.first { $0.timestamp == first.routePoints[2].date }).verticalAccuracy, 0)
            try await writer.save(second, record: sentinel)
            try await writer.undo(record)
            for type in required {
                let remaining = try await query(store, type, record)
                XCTAssertTrue(remaining.isEmpty, "Undo left samples for \(type.identifier)")
            }
            let untouched = try await query(store, HKObjectType.workoutType(), sentinel)
            XCTAssertEqual(untouched.count, 1, "Undo must not remove another import")
            try await writer.undo(sentinel)
            let after = try await writer.hasDuplicate(first)
            XCTAssertFalse(after)
        } catch {
            try? await writer.undo(record)
            try? await writer.undo(sentinel)
            throw error
        }
        #endif
    }

    @MainActor private func routeLocations(_ store: HKHealthStore, _ route: HKWorkoutRoute) async throws -> [CLLocation] {
        var result: [CLLocation] = []
        for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
            result.append(location)
        }
        return result
    }

    @MainActor private func query(_ store: HKHealthStore, _ type: HKSampleType, _ record: ImportRecord) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForObjects(withMetadataKey: "com.barclayd.healthimport.batch",
                                                    allowedValues: [record.id.uuidString])
        return try await withCheckedThrowingContinuation { continuation in
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                       sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            })
        }
    }
}
