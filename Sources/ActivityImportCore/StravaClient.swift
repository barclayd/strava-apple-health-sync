import Foundation

public struct StravaResponse: Sendable {
    public let status: Int
    public let data: Data
    public let headers: [String: String]
    public init(status: Int, data: Data, headers: [String: String] = [:]) {
        self.status = status; self.data = data
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }
}

public actor StravaClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> StravaResponse
    private let configuration: StravaConfiguration
    private let store: any StravaTokenStore
    private let transport: Transport
    private var refreshing: Task<StravaToken, Error>?
    private var budget = StravaRequestBudget()

    public init(configuration: StravaConfiguration, store: any StravaTokenStore, transport: @escaping Transport) {
        self.configuration = configuration; self.store = store; self.transport = transport
    }

    public func isConnected() async throws -> Bool { try await store.read() != nil }

    public func connect(code: String) async throws {
        let token = try await exchange(["grant_type": "authorization_code", "code": code])
        // Persist before reporting success, including any rotated refresh token.
        try await store.save(token)
    }

    /// Local sign-out does not revoke the shared Stitch application grant.
    public func forgetConnection() async throws {
        if let refreshing {
            refreshing.cancel()
            _ = try? await refreshing.value
            self.refreshing = nil
        }
        try await store.remove()
    }

    public func activities(on date: Date, calendar: Calendar = .current) async throws -> [StravaActivity] {
        guard let day = calendar.dateInterval(of: .day, for: date) else {
            throw ImportProblem("Choose a valid trial date.")
        }
        var result: [StravaActivity] = []
        var seen = Set<Int64>()
        for page in 1...10 {
            let query = [URLQueryItem(name: "after", value: String(Int(day.start.timeIntervalSince1970) - 1)),
                         .init(name: "before", value: String(Int(day.end.timeIntervalSince1970))),
                         .init(name: "per_page", value: "100"), .init(name: "page", value: String(page))]
            let response = try await get(path: "/athlete/activities", query: query)
            let activities = try StravaJSON.decode([StravaActivity].self, from: response.data)
            result += activities.filter { $0.startDate >= day.start && $0.startDate < day.end && seen.insert($0.id).inserted }
            if activities.isEmpty { return result.sorted { $0.startDate > $1.startDate } }
        }
        throw ImportProblem("There are too many activities for this one-day trial. No incomplete list was imported.")
    }

    /// A short page is not necessarily the last page. Stop only at an empty response.
    public func history(before: Date, progress: @Sendable (Int) async -> Void = { _ in }) async throws -> [StravaActivity] {
        var result: [StravaActivity] = []
        var seen = Set<Int64>()
        for page in 1...500 {
            try Task.checkCancellation()
            let response = try await get(path: "/athlete/activities", query: [
                .init(name: "before", value: String(Int(before.timeIntervalSince1970))),
                .init(name: "per_page", value: "200"), .init(name: "page", value: String(page))
            ])
            let values = try StravaJSON.decode([StravaActivity].self, from: response.data)
            if values.isEmpty { return result.sorted { $0.startDate > $1.startDate } }
            let new = values.filter { $0.id > 0 && $0.startDate < before && seen.insert($0.id).inserted }
            guard !new.isEmpty else { throw ImportProblem("Strava repeated a history page. Reload history later; no incomplete list can be imported.") }
            result += new
            await progress(result.count)
        }
        throw ImportProblem("This history exceeds the POC’s 100,000-activity limit. No incomplete list can be imported.")
    }

    public func activity(id: Int64) async throws -> (StravaActivity, Activity) {
        guard id > 0 else { throw ImportProblem("Choose an activity from the Strava list.") }
        let detail = try await get(path: "/activities/\(id)")
        let source = try StravaJSON.decode(StravaActivity.self, from: detail.data)
        guard source.id == id else { throw ImportProblem("Strava returned a different activity. Nothing has been imported.") }
        var streams = StravaStreams.empty
        if source.manual != true {
            let response = try await get(path: "/activities/\(id)/streams", query: [
                .init(name: "keys", value: "time,latlng,altitude,heartrate,watts,cadence,velocity_smooth,moving,distance"), .init(name: "key_by_type", value: "true")
            ], allowMissing: true)
            if response.status != 404 { streams = try StravaJSON.decode(StravaStreams.self, from: response.data) }
        }
        return (source, try source.activity(streams: streams))
    }

    private func accessToken() async throws -> String {
        if let refreshing { return try await refreshing.value.accessToken }
        guard let saved = try await store.read() else { throw ImportProblem("Connect with Strava to continue.") }
        if saved.expiresAt > Date().timeIntervalSince1970 + 120 { return saved.accessToken }
        // The store read suspends, so recheck before starting a shared refresh.
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { () throws -> StravaToken in
            let token = try await self.exchange(["grant_type": "refresh_token", "refresh_token": saved.refreshToken])
            try Task.checkCancellation()
            try await self.store.save(token)
            return token
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value.accessToken
    }

    private func exchange(_ values: [String: String]) async throws -> StravaToken {
        try configuration.validate()
        var values = values
        values["client_id"] = configuration.clientID
        values["client_secret"] = configuration.clientSecret
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(values)
        let response = try await transport(request)
        try Self.check(response)
        let token = try StravaJSON.decode(StravaToken.self, from: response.data)
        try token.validate()
        return token
    }

    private func get(path: String, query: [URLQueryItem] = [], allowMissing: Bool = false) async throws -> StravaResponse {
        try Task.checkCancellation()
        try budget.check(at: Date())
        var parts = URLComponents(string: "https://www.strava.com/api/v3" + path)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport(request)
        budget.observe(response, at: Date())
        if !(allowMissing && response.status == 404) { try Self.check(response) }
        return response
    }

    public static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }

    private static func check(_ response: StravaResponse) throws {
        switch response.status {
        case 200..<300: return
        case 401: throw ImportProblem("Your Strava connection is no longer valid. Forget this connection and connect again.")
        case 403: throw ImportProblem("Strava did not allow this request. Check the app’s access and activity permissions.")
        case 404: throw ImportProblem("This activity is no longer available on Strava.")
        case 429: throw ImportProblem("Strava’s request limit has been reached. Try again later; no automatic retries will run.")
        default: throw ImportProblem("Strava could not complete the request. Try again later; completed imports are kept.")
        }
    }
}
