import XCTest
import HealthKit
import ActivityImportCore
@testable import HealthImport

final class HealthWriterTests: XCTestCase {
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
        let xml = try String(contentsOf: url, encoding: .utf8)
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
