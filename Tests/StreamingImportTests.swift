import Foundation
import Testing
@testable import ActivityImportCore

private func source(_ id: Int64, date: Date = Date(timeIntervalSince1970: 1_500_000_000)) throws -> StravaActivity {
    try StravaJSON.decode(StravaActivity.self, from: Data("""
    {"id":\(id),"name":"Synthetic","sport_type":"Ride","start_date":"\(date.ISO8601Format())",
     "elapsed_time":300,"moving_time":120,"distance":800,"manual":true,"calories":20}
    """.utf8))
}

@MainActor @Test func fifteenYearsImportKeepsOnlyOnePageAndOneResult() async throws {
    let query = ActivityQuery(before: Date(timeIntervalSince1970: 1_900_000_000))
    let importer = StreamingHistoryImport(query: query)
    var pageCalls = 0, detailCalls = 0, saves = 0, maximumRetained = 0
    try await importer.run(loadPage: { request, page, size in
        #expect(request == query && size == 50)
        pageCalls += 1
        let start = (page - 1) * size
        guard start < 3_000 else { return [] }
        return try (start..<min(start + size, 3_000)).map { index in
            try source(Int64(index + 1), date: query.before.addingTimeInterval(-Double(index + 1) * 172_800))
        }
    }, isImported: { $0 <= 1_500 }, fetch: { id in
        detailCalls += 1
        return try source(id).activity(streams: .empty)
    }, save: { value in
        #expect(value.activeEnergy == 20)
        saves += 1; return .imported
    }, changed: { maximumRetained = max(maximumRetained, importer.retainedSummaryCount) })
    #expect(importer.finished && importer.imported == 1_500 && importer.skipped == 1_500)
    #expect(pageCalls == 61 && detailCalls == 1_500 && saves == 1_500)
    #expect(maximumRetained == 50 && importer.retainedSummaryCount == 0)
}

@MainActor @Test func streamingImportContinuesShortPagesAndPausesRepeatedPages() async throws {
    let importer = StreamingHistoryImport(query: ActivityQuery(before: Date()))
    var pages: [Int] = [], saved = Set<Int64>()
    try await importer.run(loadPage: { _, page, _ in
        pages.append(page)
        return try (page == 1 ? [Int64(1)] : page == 2 ? [1, 2] : []).map { try source($0) }
    }, isImported: { saved.contains($0) }, fetch: { try source($0).activity(streams: .empty) }, save: {
        saved.insert($0.stravaID!); return .imported
    })
    #expect(pages == [1, 2, 3] && saved == [1, 2] && importer.finished)
    let repeating = StreamingHistoryImport(query: ActivityQuery(before: Date()))
    await #expect(throws: ImportProblem.self) {
        try await repeating.run(loadPage: { _, _, _ in [try source(1)] }, isImported: { _ in true },
            fetch: { try source($0).activity(streams: .empty) }, save: { _ in .imported })
    }
    #expect(!repeating.finished && !repeating.running && repeating.processed == 1)
}

@MainActor @Test func pageAndDetailFailuresResumeWithoutRepeatingCompletedWrites() async throws {
    let importer = StreamingHistoryImport(query: ActivityQuery(before: Date()))
    var pageFailure = true, detailFailure = true
    var pages: [Int] = [], saved: [Int64] = []
    let load: @MainActor (ActivityQuery, Int, Int) async throws -> [StravaActivity] = { _, page, _ in
        pages.append(page)
        if page == 2 && pageFailure { throw ImportProblem("Rate limit") }
        return page < 3 ? [try source(Int64(page))] : []
    }
    let fetch: @MainActor (Int64) async throws -> Activity = { id in
        if id == 2 && detailFailure { throw ImportProblem("Network interruption") }
        return try source(id).activity(streams: .empty)
    }
    let save: @MainActor (Activity) async throws -> HistoryImportOutcome = { value in saved.append(value.stravaID!); return .imported }
    await #expect(throws: ImportProblem.self) { try await importer.run(loadPage: load, isImported: { saved.contains($0) }, fetch: fetch, save: save) }
    #expect(saved == [1] && !importer.finished)
    pageFailure = false
    await #expect(throws: ImportProblem.self) { try await importer.run(loadPage: load, isImported: { saved.contains($0) }, fetch: fetch, save: save) }
    #expect(importer.nextID == 2 && saved == [1])
    detailFailure = false
    try await importer.run(loadPage: load, isImported: { saved.contains($0) }, fetch: fetch, save: save)
    #expect(saved == [1, 2] && pages == [1, 2, 2, 3] && importer.finished)
}

@MainActor @Test func selectedIDsNeverScanHistoryAndPauseBeforeWriteIsResumable() async throws {
    let importer = StreamingHistoryImport(ids: [1, 2])
    var saves: [Int64] = []
    try await importer.run(loadPage: { _, _, _ in Issue.record("Individual selection must not list history"); return [] },
        isImported: { _ in false }, fetch: { id in importer.pause(); return try source(id).activity(streams: .empty) },
        save: { _ in Issue.record("Paused fetch must not write"); return .imported })
    #expect(saves.isEmpty && importer.nextID == 1)
    try await importer.run(loadPage: { _, _, _ in []; }, isImported: { _ in false }, fetch: { try source($0).activity(streams: .empty) },
        save: { value in saves.append(value.stravaID!); importer.pause(); return .imported })
    #expect(saves == [1] && importer.nextID == 2)
    importer.skip()
    #expect(importer.finished && importer.imported == 1 && importer.skipped == 1)
}

@Test func monthBoundsAndInclusiveDateBoundsHandleDaylightSaving() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let date = ISO8601DateFormatter()
    let day = date.date(from: "2026-10-25T12:00:00Z")!
    let query = ActivityQuery.days(from: day, through: day, calendar: calendar)
    #expect(query.after == date.date(from: "2026-10-24T23:00:00Z"))
    #expect(query.before == date.date(from: "2026-10-26T00:00:00Z"))
    let month = ActivityQuery.month(containing: day, calendar: calendar)
    #expect(month.after == date.date(from: "2026-09-30T23:00:00Z"))
    #expect(month.before == date.date(from: "2026-11-01T00:00:00Z"))
}
