import Foundation
import Testing
@testable import ActivityImportCore

private func fixture() throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: "historic-run", withExtension: "tcx", subdirectory: "Fixtures")))
}

private func changed(_ original: String, _ replacement: String) throws -> Data {
    Data(try String(decoding: fixture(), as: UTF8.self).replacingOccurrences(of: original, with: replacement).utf8)
}

@Test func preservesHistoricMeasurements() throws {
    let activities = try TCXReader.read(fixture())
    let activity = try #require(activities.first)
    #expect(activities.count == 1)
    #expect(activity.start == ISO8601DateFormatter().date(from: "2018-06-12T07:00:00Z"))
    #expect(activity.duration == 1800)
    #expect(activity.end.timeIntervalSince(activity.start) == 1800)
    #expect(activity.distance == 5000)
    #expect(activity.routePoints.count == 4)
    #expect(activity.heartRatePoints.map(\.heartRate) == [105, 138, 145, 130])
}

@Test func stableIdentityAcrossEquivalentTimestampsAndCorrections() throws {
    let original = try #require(TCXReader.read(fixture()).first)
    let timezone = try #require(TCXReader.read(changed("2018-06-12T07:00:00Z", "2018-06-12T08:00:00+01:00")).first)
    let fractional = try #require(TCXReader.read(changed("2018-06-12T07:00:00Z", "2018-06-12T07:00:00.000Z")).first)
    let corrected = try #require(TCXReader.read(changed("5000", "5100")).first)
    #expect(original.id == timezone.id)
    #expect(original.id == fractional.id)
    #expect(original.id == corrected.id)
}

@Test func preservesTimerSeparatelyFromElapsedTime() throws {
    let activity = try #require(TCXReader.read(changed("<TotalTimeSeconds>1800</TotalTimeSeconds>", "<TotalTimeSeconds>1700</TotalTimeSeconds>")).first)
    #expect(activity.duration == 1700)
    #expect(activity.end.timeIntervalSince(activity.start) == 1800)
}

@Test(arguments: [
    ("Sport=\"Running\"", "Sport=\"Other\""),
    ("<TotalTimeSeconds>1800</TotalTimeSeconds>", "<TotalTimeSeconds>-1</TotalTimeSeconds>"),
    ("<DistanceMeters>5000</DistanceMeters>", "<DistanceMeters>NaN</DistanceMeters>"),
    ("<LatitudeDegrees>51.5060</LatitudeDegrees>", "<LatitudeDegrees>91</LatitudeDegrees>"),
    ("<LatitudeDegrees>51.5060</LatitudeDegrees>", "<LatitudeDegrees>NaN</LatitudeDegrees>"),
    ("<Value>105</Value>", "<Value>0</Value>"),
    ("2018-06-12T07:10:00Z", "2018-06-12T07:00:00Z"),
    ("<Id>2018-06-12T07:00:00Z</Id>", "<Id>not-a-date</Id>"),
    ("</TrainingCenterDatabase>", "")
]) func rejectsUnsafeOrInconsistentInput(pair: (String, String)) throws {
    let data = try changed(pair.0, pair.1)
    #expect(throws: ImportProblem.self) { try TCXReader.read(data) }
}

@Test func rejectsEntitiesAndOversizedFiles() throws {
    let data = Data("<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><x>&secret;</x>".utf8)
    #expect(throws: ImportProblem.self) { try TCXReader.read(data) }
    #expect(throws: ImportProblem.self) { try TCXReader.read(Data(repeating: 32, count: TCXReader.maximumBytes + 1)) }
}

@Test func duplicateMatchingIsConservative() throws {
    let activity = try #require(TCXReader.read(fixture()).first)
    #expect(DuplicatePolicy.matches(sport: .running, start: activity.start.addingTimeInterval(60), end: activity.end, candidate: activity))
    #expect(DuplicatePolicy.matches(sport: .running, start: activity.start.addingTimeInterval(180), end: activity.end, candidate: activity))
    #expect(!DuplicatePolicy.matches(sport: .cycling, start: activity.start, end: activity.end, candidate: activity))
    #expect(!DuplicatePolicy.matches(sport: .running, start: activity.end.addingTimeInterval(600), end: activity.end.addingTimeInterval(2400), candidate: activity))
}

@MainActor @Test func journalRecoversInterruptedImportAndRemovesOnlyOneRecord() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let activity = try #require(TCXReader.read(fixture()).first)
    let first = ImportRecord(activity: activity)
    let second = ImportRecord(activity: activity)
    let journal = try ImportJournal(directory: directory)
    try journal.append(first)
    try journal.append(second)
    try journal.complete(first.id)
    let reopened = try ImportJournal(directory: directory)
    #expect(reopened.records.count == 2)
    #expect(reopened.records.first?.completed == true)
    #expect(reopened.records.last?.completed == false)
    try reopened.remove(first.id)
    #expect(try ImportJournal(directory: directory).records == [second])
    #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

@MainActor @Test func journalDoesNotIgnoreCorruptHistoryOrFailedWrites() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try ImportJournal(directory: directory)
    let activity = try #require(TCXReader.read(fixture()).first)
    try FileManager.default.removeItem(at: directory)
    #expect(throws: (any Error).self) { try journal.append(ImportRecord(activity: activity)) }
    #expect(journal.records.isEmpty)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: directory.appendingPathComponent("imports.json"))
    #expect(throws: (any Error).self) { try ImportJournal(directory: directory) }
}
