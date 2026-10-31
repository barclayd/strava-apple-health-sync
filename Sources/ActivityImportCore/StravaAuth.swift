import Foundation

public struct StravaConfiguration: Codable, Sendable {
    public let clientID: String
    public let clientSecret: String
    public let callbackHost: String
    public static let callbackScheme = "healthimport-strava"

    public init(clientID: String, clientSecret: String, callbackHost: String) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.callbackHost = callbackHost
    }

    public func validate() throws {
        guard !clientID.isEmpty, clientID.allSatisfy(\.isNumber), !clientSecret.isEmpty,
              !callbackHost.isEmpty, callbackHost.utf8.allSatisfy({
                  (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              }), !callbackHost.contains("/"), !callbackHost.contains(":") else {
            throw ImportProblem("The local Strava developer configuration is incomplete. See the project’s setup instructions.")
        }
    }

    public var redirectURI: String { "\(Self.callbackScheme)://\(callbackHost)/oauth/callback" }

    public func authorisationURL(state: String, native: Bool) throws -> URL {
        try validate()
        var components = URLComponents(string: native ? "strava://oauth/mobile/authorize" : "https://www.strava.com/oauth/mobile/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "approval_prompt", value: "auto"),
            .init(name: "scope", value: "activity:read_all"), .init(name: "state", value: state)
        ]
        return components.url!
    }

    public func code(from url: URL, expectedState: String) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Self.callbackScheme, parts.host == callbackHost,
              parts.path == "/oauth/callback", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else {
            throw ImportProblem("The Strava callback did not match this connection attempt.")
        }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard !expectedState.isEmpty, value("state") == expectedState else {
            throw ImportProblem("This Strava sign-in has expired. Connect again.")
        }
        guard !items.contains(where: { $0.name == "error" }) else {
            throw ImportProblem("Strava access was cancelled. Nothing has been imported.")
        }
        let scopes = Set((value("scope") ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
        guard scopes.contains("activity:read_all") else {
            throw ImportProblem("Allow access to your activities, including private activities, to run this trial.")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw ImportProblem("Strava did not return an authorisation code. Connect again.")
        }
        return code
    }
}

public struct StravaToken: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: TimeInterval
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at"
    }
    public init(accessToken: String, refreshToken: String, expiresAt: TimeInterval) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
    public func validate() throws {
        guard !accessToken.isEmpty, !refreshToken.isEmpty, expiresAt.isFinite, expiresAt > 0 else {
            throw ImportProblem("Strava returned an incomplete connection. Connect again.")
        }
    }
}

public protocol StravaTokenStore: Sendable {
    func read() async throws -> StravaToken?
    func save(_ token: StravaToken) async throws
    func remove() async throws
}
