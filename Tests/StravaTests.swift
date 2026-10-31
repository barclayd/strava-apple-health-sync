import Foundation
import Testing
@testable import ActivityImportCore

private let fixture = """
{"id":123,"name":"Synthetic ride","sport_type":"Ride","start_date":"2026-10-30T08:00:00Z",
 "elapsed_time":120,"moving_time":90,"distance":800,"manual":false}
"""
private let configuration = StravaConfiguration(clientID: "123", clientSecret: "synthetic-secret", callbackHost: "example.com")

@Test func stravaOAuthCallbackRequiresExactStateScopeAndDestination() throws {
    let prefix = configuration.redirectURI
    #expect(try configuration.code(from: URL(string: prefix + "?state=expected&scope=activity:read_all&code=test")!, expectedState: "expected") == "test")
    let invalid = [
        prefix + "?state=wrong&scope=activity:read_all&code=test",
        prefix + "?state=expected&state=expected&scope=activity:read_all&code=test",
        prefix + "?state=expected&scope=activity:read&code=test",
        prefix + "?state=expected&scope=activity:read_all&code=a&code=b",
        prefix + "?state=expected&scope=activity:read_all&code=test&error=access_denied",
        "healthimport-strava://attacker.example/oauth/callback?state=expected&scope=activity:read_all&code=test",
        "https://example.com/oauth/callback?state=expected&scope=activity:read_all&code=test"
    ]
    for value in invalid {
        #expect(throws: ImportProblem.self) { try configuration.code(from: URL(string: value)!, expectedState: "expected") }
    }
    let url = try configuration.authorisationURL(state: "expected", native: false)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(query.first { $0.name == "scope" }?.value == "activity:read_all")
    #expect(!url.absoluteString.contains(configuration.clientSecret))
    #expect(String(data: StravaClient.form(["code": "a+b&c=d"]), encoding: .utf8) == "code=a%2Bb%26c%3Dd")
}

private func streams(times: [Double] = [0, 60, 120], heart: [Double] = [100, 0, 120]) throws -> StravaStreams {
    func stream(_ data: Any) -> [String: Any] { ["data": data, "original_size": 3, "resolution": "high", "series_type": "distance"] }
    let json: [String: Any] = ["time": stream(times), "heartrate": stream(heart),
                               "latlng": stream([[51.0, -0.1], [51.001, -0.1], [51.002, -0.1]])]
    return try StravaJSON.decode(StravaStreams.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func stravaMappingPreservesChronologyAndDoesNotInventTimerOrHeartRate() throws {
    let source = try StravaJSON.decode(StravaActivity.self, from: Data(fixture.utf8))
    let result = try source.activity(streams: streams())
    #expect(result.id == "strava-v1-123")
    #expect(result.duration == 120) // moving_time=90 is deliberately not used as a recording timer.
    #expect(result.end.timeIntervalSince(result.start) == 120)
    #expect(result.points[1].date.timeIntervalSince(result.start) == 60)
    #expect(result.heartRatePoints.count == 2)
    #expect(result.routePoints.count == 3)
    #expect(result.distance == 800)
    #expect(try source.activity(streams: .empty).points.isEmpty)
    let changed = fixture.replacingOccurrences(of: "\"distance\":800", with: "\"distance\":850")
    #expect(try StravaJSON.decode(StravaActivity.self, from: Data(changed.utf8)).activity(streams: .empty).id == result.id)
    #expect(throws: ImportProblem.self) { try source.activity(streams: streams(heart: [100])) }
    #expect(throws: ImportProblem.self) { try source.activity(streams: streams(times: [0, 60, 60])) }
    #expect(throws: ImportProblem.self) { try source.activity(streams: streams(times: [0, 60, 121])) }
    #expect(throws: ImportProblem.self) { try source.activity(streams: streams(heart: [100, 400, 120])) }
}

private actor TokenMemory: StravaTokenStore {
    var token: StravaToken?
    var writes = 0
    init(expired: Bool = false) {
        token = StravaToken(accessToken: "old-access", refreshToken: "old-refresh",
                            expiresAt: expired ? 1 : Date().timeIntervalSince1970 + 3600)
    }
    func read() -> StravaToken? { token }
    func save(_ value: StravaToken) { token = value; writes += 1 }
    func remove() { token = nil }
}

private actor TestServer {
    var requests: [URLRequest] = []
    var failure: Int?
    init(failure: Int? = nil) { self.failure = failure }
    func send(_ request: URLRequest) async throws -> StravaResponse {
        requests.append(request)
        if let failure { return StravaResponse(status: failure, data: Data()) }
        if request.url?.path == "/oauth/token" {
            await Task.yield()
            return StravaResponse(status: 200, data: Data("""
                {"access_token":"new-access","refresh_token":"new-refresh","expires_at":\(Date().timeIntervalSince1970 + 3600)}
                """.utf8))
        }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let nextPage = query.contains { $0.name == "page" && $0.value != "1" }
        return StravaResponse(status: 200, data: Data((nextPage ? "[]" : "[\(fixture)]").utf8))
    }
}

@Test func expiredTokensRefreshOnceAndPersistRotationBeforeReads() async throws {
    let store = TokenMemory(expired: true)
    let server = TestServer()
    let client = StravaClient(configuration: configuration, store: store, transport: server.send)
    let date = ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z")!
    async let first = client.activities(on: date)
    async let second = client.activities(on: date)
    let (a, b) = try await (first, second)
    #expect(a.count == 1 && b.count == 1)
    #expect(await store.writes == 1)
    #expect(await store.token?.refreshToken == "new-refresh")
    let requests = await server.requests
    #expect(requests.filter { $0.url?.path == "/oauth/token" }.count == 1)
    #expect(requests.filter { $0.httpMethod == "GET" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer new-access" })
    try await client.forgetConnection()
    #expect(try await !client.isConnected())
    #expect(await server.requests.count == requests.count) // no shared app revocation
}

@Test func rateLimitDoesNotRetryOrWriteTokens() async throws {
    let store = TokenMemory()
    let server = TestServer(failure: 429)
    let client = StravaClient(configuration: configuration, store: store, transport: server.send)
    await #expect(throws: ImportProblem.self) { try await client.activities(on: Date()) }
    #expect(await server.requests.count == 1)
    #expect(await store.writes == 0)
}

@Test func trialDateUsesLocalCalendarAcrossDaylightSavingBoundary() async throws {
    let store = TokenMemory()
    let server = TestServer()
    let client = StravaClient(configuration: configuration, store: store, transport: server.send)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let date = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
    let result = try await client.activities(on: date, calendar: calendar)
    #expect(result.isEmpty) // out-of-window API rows must not leak into the trial selection.
    let query = URLComponents(url: await server.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
    let after = Double(query.first { $0.name == "after" }!.value!)! + 1
    let before = Double(query.first { $0.name == "before" }!.value!)!
    #expect(before - after == 25 * 3600)
}

@Test func cyclingFixtureMapsAvailableStreamsWithoutAssumingActiveCalories() throws {
    let detailURL = Bundle.module.url(forResource: "synthetic-ride", withExtension: "json", subdirectory: "Fixtures")!
    let streamsURL = Bundle.module.url(forResource: "synthetic-ride-streams", withExtension: "json", subdirectory: "Fixtures")!
    let source = try StravaJSON.decode(StravaActivity.self, from: Data(contentsOf: detailURL))
    let streams = try StravaJSON.decode(StravaStreams.self, from: Data(contentsOf: streamsURL))
    let activity = try source.activity(streams: streams)
    #expect(activity.sport == .cycling)
    #expect(activity.stravaCalories == 20)
    #expect(activity.activeEnergy == nil)
    #expect(activity.elevationGain == 8)
    #expect(activity.indoor == false)
    #expect(activity.powerIsEstimated == false)
    #expect(activity.powerPoints.map(\.power) == [100, 200, 0, 120])
    #expect(activity.cadencePoints.map(\.cadence) == [70, 80, 0, 75])
    #expect(activity.speedPoints.map(\.speed) == [5, 7, 0, 6])
    #expect(activity.points[2].date.timeIntervalSince(activity.start) == 80)
    let bad = try String(contentsOf: streamsURL, encoding: .utf8).replacingOccurrences(of: "[100,200,0,120]", with: "[-100,200,0,120]")
    #expect(throws: ImportProblem.self) {
        try source.activity(streams: StravaJSON.decode(StravaStreams.self, from: Data(bad.utf8)))
    }
}
