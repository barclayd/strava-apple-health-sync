import XCTest
import ActivityImportCore
@testable import HealthImport

private actor BrowserTokens: StravaTokenStore {
    func read() -> StravaToken? { StravaToken(accessToken: "synthetic", refreshToken: "synthetic", expiresAt: Date().timeIntervalSince1970 + 3600) }
    func save(_ token: StravaToken) {}
    func remove() {}
}

private actor BrowserServer {
    var sizes: [Int] = []
    var pages: [Int] = []
    var afters: [Int?] = []
    var slowMonth = false
    func slow() { slowMonth = true }
    func send(_ request: URLRequest) async throws -> StravaResponse {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let size = Int(items.first { $0.name == "per_page" }!.value!)!
        let page = Int(items.first { $0.name == "page" }!.value!)!
        let after = items.first { $0.name == "after" }.flatMap { Int($0.value!) }
        sizes.append(size); pages.append(page); afters.append(after)
        if slowMonth && sizes.count == 1 {
            // Deliberately ignore cancellation to prove old responses cannot replace a newer month.
            await Task.detached { try? await Task.sleep(for: .milliseconds(150)) }.value
            throw ImportProblem("Old request failed")
        }
        let start = after.map { Date(timeIntervalSince1970: Double($0 + 3601)) } ?? Date(timeIntervalSince1970: 1_500_000_000)
        let json = (0..<size).map { index in
            """
            {"id":\(page * 100 + index),"name":"Synthetic","sport_type":"Ride","start_date":"\(start.ISO8601Format())","elapsed_time":300,"moving_time":120,"distance":800,"manual":true}
            """
        }.joined(separator: ",")
        return StravaResponse(status: 200, data: Data("[\(json)]".utf8))
    }
}

final class ActivityLibraryTests: XCTestCase {
    @MainActor private func connection(_ server: BrowserServer) -> StravaConnection {
        let client = StravaClient(configuration: StravaConfiguration(clientID: "123", clientSecret: "test", callbackHost: "example.com"),
            store: BrowserTokens(), transport: server.send)
        let connection = StravaConnection(client: client)
        connection.connected = true
        return connection
    }

    @MainActor private func wait(_ library: ActivityLibrary) async throws {
        for _ in 0..<200 {
            if !library.loading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Browser load did not finish")
    }

    @MainActor func testBrowserReplacesFiveRowsInsteadOfAccumulatingHistory() async throws {
        let server = BrowserServer(), library = ActivityLibrary(), model = ImportModel()
        let strava = connection(server)
        strava.message = "An earlier connection restore failed"
        library.load(strava: strava, model: model)
        try await wait(library)
        XCTAssertNil(strava.message)
        XCTAssertEqual(library.activities.count, 5)
        XCTAssertEqual(library.activities.first?.id, 100)
        library.load(strava: strava, model: model, page: 2, reset: false)
        try await wait(library)
        XCTAssertEqual(library.activities.count, 5)
        XCTAssertEqual(Set(library.activities.map(\.id)), Set((200...204).map(Int64.init)))
        let sizes = await server.sizes, pages = await server.pages
        XCTAssertEqual(sizes, [5, 5]); XCTAssertEqual(pages, [1, 2])
    }

    @MainActor func testOlderCancelledMonthCannotLeaveAnErrorOnSuccessfulMonth() async throws {
        let server = BrowserServer(), library = ActivityLibrary(), model = ImportModel()
        await server.slow()
        let strava = connection(server)
        library.selection.scope = .individual
        library.month = Date(timeIntervalSince1970: 1_579_046_400) // Mid-Jan 2020
        library.load(strava: strava, model: model)
        try await Task.sleep(for: .milliseconds(20))
        library.month = Date(timeIntervalSince1970: 1_581_724_800) // Mid-Feb 2020
        library.load(strava: strava, model: model)
        try await wait(library)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(library.browseError)
        XCTAssertFalse(model.historyRunning)
        XCTAssertEqual(library.activities.count, 5)
        XCTAssertTrue(library.activities.allSatisfy { Calendar.current.component(.month, from: $0.startDate) == 2 })
    }

    @MainActor func testSuccessfulReadClearsStaleConnectionFailure() async throws {
        let server = BrowserServer(), strava = connection(server)
        strava.message = "The Strava connection could not be accessed securely"
        _ = try await strava.activityPage(query: ActivityQuery(before: Date()), page: 1, size: 5)
        XCTAssertNil(strava.message)
        strava.message = "An earlier failure"
        await strava.restore()
        XCTAssertTrue(strava.connected)
        XCTAssertNil(strava.message)
    }
}
