import Foundation
import Testing
@testable import ActivityImportCore

private func summaryJSON(_ id: Int64, sport: String = "Ride") -> String {
    """
    {"id":\(id),"name":"Synthetic \(id)","sport_type":"\(sport)","start_date":"2018-06-13T07:00:00Z",
     "elapsed_time":300,"moving_time":120,"distance":800,"manual":true,"calories":20}
    """
}

private func summary(_ id: Int64, sport: String = "Ride") throws -> StravaActivity {
    try StravaJSON.decode(StravaActivity.self, from: Data(summaryJSON(id, sport: sport).utf8))
}

private actor HistoryTokens: StravaTokenStore {
    func read() -> StravaToken? { StravaToken(accessToken: "synthetic", refreshToken: "synthetic", expiresAt: Date().timeIntervalSince1970 + 3600) }
    func save(_ token: StravaToken) {}
    func remove() {}
}

private actor PagedHistoryServer {
    let pages: [[Int64]]
    var requestedPages: [Int] = []
    var beforeValues: [String] = []
    init(_ pages: [[Int64]]) { self.pages = pages }
    func send(_ request: URLRequest) async throws -> StravaResponse {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let page = Int(query.first { $0.name == "page" }!.value!)!
        requestedPages.append(page)
        beforeValues.append(query.first { $0.name == "before" }!.value!)
        let ids = pages.indices.contains(page - 1) ? pages[page - 1] : []
        return StravaResponse(status: 200, data: Data(("[" + ids.map { summaryJSON($0) }.joined(separator: ",") + "]").utf8))
    }
}

@Test func historyContinuesAfterShortPagesAndDeduplicatesRepeatedRows() async throws {
    let server = PagedHistoryServer([[1], [1, 2], []])
    let client = StravaClient(configuration: StravaConfiguration(clientID: "123", clientSecret: "test", callbackHost: "example.com"),
                              store: HistoryTokens(), transport: server.send)
    let result = try await client.history(before: Date(timeIntervalSince1970: 1_900_000_000))
    #expect(Set(result.map(\.id)) == [1, 2])
    #expect(await server.requestedPages == [1, 2, 3])
    #expect(Set(await server.beforeValues).count == 1)
}

@Test func repeatedHistoryPageFailsWithoutReturningAnIncompleteList() async throws {
    let server = PagedHistoryServer([[1], [1]])
    let client = StravaClient(configuration: StravaConfiguration(clientID: "123", clientSecret: "test", callbackHost: "example.com"),
                              store: HistoryTokens(), transport: server.send)
    await #expect(throws: ImportProblem.self) { try await client.history(before: Date()) }
    #expect(await server.requestedPages == [1, 2])
}

@Test func sharedQuotaLeavesHeadroomAndUsesUTCResetBoundaries() throws {
    let now = Date(timeIntervalSince1970: 1000)
    var budget = StravaRequestBudget()
    budget.observe(StravaResponse(status: 200, data: Data(), headers: [
        "X-ReadRateLimit-Limit": "100, 1000", "X-ReadRateLimit-Usage": "89, 89"
    ]), at: now)
    try budget.check(at: now)
    budget.observe(StravaResponse(status: 200, data: Data(), headers: [
        "X-ReadRateLimit-Limit": "100, 1000", "X-ReadRateLimit-Usage": "90, 90"
    ]), at: now)
    #expect(budget.resumeAfter == Date(timeIntervalSince1970: 1801))
    #expect(throws: ImportProblem.self) { try budget.check(at: now) }
    try budget.check(at: Date(timeIntervalSince1970: 1801))
    budget.observe(StravaResponse(status: 200, data: Data(), headers: [
        "X-RateLimit-Limit": "200, 2000", "X-RateLimit-Usage": "10, 1800"
    ]), at: now)
    #expect(budget.resumeAfter == Date(timeIntervalSince1970: 86401))
    var limited = StravaRequestBudget()
    limited.observe(StravaResponse(status: 429, data: Data()), at: now)
    #expect(throws: ImportProblem.self) { try limited.check(at: now) }
}

@MainActor @Test func queueSkipsKnownImportsAndResumesFailedActivityWithoutRepeatingWrites() async throws {
    let queue = HistoryImportQueue(activities: try [summary(1), summary(2), summary(3), summary(4, sport: "Swim"), summary(3)])
    var fetched: [Int64] = []
    var saved: [Int64] = []
    var fail = true
    let fetch: @MainActor (Int64) async throws -> Activity = { id in
        fetched.append(id)
        if id == 3 && fail { throw ImportProblem("Synthetic network interruption") }
        return try summary(id).activity(streams: .empty)
    }
    let save: @MainActor (Activity) async throws -> HistoryImportOutcome = { activity in
        saved.append(activity.stravaID!)
        #expect(activity.activeEnergy == 20)
        return .imported
    }
    await #expect(throws: ImportProblem.self) {
        try await queue.run(completedIDs: ["strava-v1-1"], useCalories: true, usePauses: true, fetch: fetch, save: save)
    }
    #expect(queue.activities.count == 3)
    #expect(queue.outcomes == [1: .alreadyImported, 2: .imported])
    #expect(queue.next?.id == 3)
    fail = false
    try await queue.run(completedIDs: ["strava-v1-1", "strava-v1-2"], useCalories: true, usePauses: true, fetch: fetch, save: save)
    #expect(fetched == [2, 3, 3])
    #expect(saved == [2, 3])
    #expect(queue.next == nil)
}

@MainActor @Test func pauseWaitsForCurrentTransactionAndFetchPauseWritesNothing() async throws {
    let queue = HistoryImportQueue(activities: try [summary(1), summary(2)])
    var saves = 0
    try await queue.run(completedIDs: [], useCalories: false, usePauses: false,
        fetch: { try summary($0).activity(streams: .empty) },
        save: { value in
            #expect(value.activeEnergy == nil && value.pauses.isEmpty)
            saves += 1; queue.pause()
            return .imported
        })
    #expect(saves == 1 && queue.next?.id == 2)
    try await queue.run(completedIDs: [], useCalories: false, usePauses: true,
        fetch: { id in queue.pause(); return try summary(id).activity(streams: .empty) },
        save: { _ in saves += 1; return .imported })
    #expect(saves == 1 && queue.next?.id == 2)
    queue.skipNext()
    #expect(queue.outcomes[2] == .skipped && queue.next == nil)
}

@MainActor @Test func relaunchUsesDurableJournalAndDuplicateMatchesAreSkipped() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try ImportJournal(directory: directory)
    let first = ImportRecord(activity: try summary(1).activity(streams: .empty))
    try journal.append(first); try journal.complete(first.id)
    let recovered = try ImportJournal(directory: directory)
    let queue = HistoryImportQueue(activities: try [summary(1), summary(2)])
    var fetched: [Int64] = []
    try await queue.run(completedIDs: Set(recovered.records.filter(\.completed).map(\.activityID)), useCalories: false, usePauses: true,
        fetch: { id in fetched.append(id); return try summary(id).activity(streams: .empty) },
        save: { _ in .duplicate })
    #expect(fetched == [2])
    #expect(queue.outcomes == [1: .alreadyImported, 2: .duplicate])
}
