import Foundation
import Testing
@testable import ActivityImportCore

private func ride(_ id: Int64, at date: String, sport: String = "Ride") throws -> StravaActivity {
    try StravaJSON.decode(StravaActivity.self, from: Data("""
    {"id":\(id),"name":"Example","sport_type":"\(sport)","start_date":"\(date)",
     "elapsed_time":300,"moving_time":120,"distance":800,"manual":true,"calories":20}
    """.utf8))
}

@Test func selectingIndividualRidesDoesNotIncludeTheRestOfHistory() throws {
    let values = try [ride(1, at: "2018-06-01T08:00:00Z"), ride(2, at: "2018-06-02T08:00:00Z"),
                      ride(3, at: "2018-06-03T08:00:00Z", sport: "Swim")]
    var selection = ActivitySelection()
    #expect(selection.activities(in: values).map(\.id) == [1, 2])
    selection.scope = .individual
    #expect(selection.activities(in: values).isEmpty)
    selection.ids = [2, 3, 999]
    #expect(selection.activities(in: values).map(\.id) == [2])
    selection.scope = .all
    #expect(selection.activities(in: values).map(\.id) == [1, 2])
}

@Test func dateSelectionIncludesEntireLocalEndDayAcrossDaylightSaving() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let date = ISO8601DateFormatter()
    var selection = ActivitySelection()
    selection.scope = .dates
    selection.start = date.date(from: "2026-10-25T12:00:00Z")!
    selection.end = selection.start
    let values = try [
        ride(1, at: "2026-10-24T22:59:59Z"), // Before the local day
        ride(2, at: "2026-10-24T23:00:00Z"), // Midnight, before clocks change
        ride(3, at: "2026-10-25T23:59:59Z"), // Last second of the 25-hour day
        ride(4, at: "2026-10-26T00:00:00Z")
    ]
    #expect(selection.activities(in: values, calendar: calendar).map(\.id) == [2, 3])
    selection.start = date.date(from: "2026-10-27T12:00:00Z")!
    #expect(selection.activities(in: values, calendar: calendar).isEmpty)
}

@MainActor @Test func selectedQueueImportsOnlyChosenRidesWithCalories() async throws {
    let values = try [ride(1, at: "2018-06-01T08:00:00Z"), ride(2, at: "2018-06-02T08:00:00Z")]
    var selection = ActivitySelection()
    selection.scope = .individual; selection.ids = [2]
    let queue = HistoryImportQueue(activities: selection.activities(in: values))
    var saved: [Int64] = []
    try await queue.run(completedIDs: [], useCalories: true, usePauses: true,
        fetch: { id in try #require(values.first { $0.id == id }).activity(streams: .empty) },
        save: { activity in
            #expect(activity.activeEnergy == 20)
            saved.append(try #require(activity.stravaID))
            return .imported
        })
    #expect(saved == [2])
}
