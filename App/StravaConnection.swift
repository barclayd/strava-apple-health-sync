import Foundation
import Security
import AuthenticationServices
import UIKit
import Observation
import ActivityImportCore

actor StravaKeychain: StravaTokenStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.barclayd.healthimport.strava",
         kSecAttrAccount as String: "tokens", kSecAttrSynchronizable as String: false]
    }
    func read() throws -> StravaToken? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure() }
        let token = try JSONDecoder().decode(StravaToken.self, from: data)
        try token.validate()
        return token
    }
    func save(_ token: StravaToken) throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(token),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw failure() }
        } else if status != errSecSuccess { throw failure() }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }
    private func failure() -> ImportProblem { ImportProblem("The Strava connection could not be accessed securely. Unlock your device and try again.") }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

enum StravaNetwork {
    static func send(_ request: URLRequest) async throws -> StravaResponse {
        guard request.url?.scheme == "https", request.url?.host == "www.strava.com" else {
            throw ImportProblem("Only direct, secure Strava requests are supported.")
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let path = request.url?.path ?? ""
        let event: AppDiagnostics.Event = path == "/oauth/token" ? .tokenRequest
            : path == "/api/v3/athlete/activities" ? .activityListRequest
            : path.hasSuffix("/streams") ? .activityStreamsRequest : .activityDetailRequest
        await AppDiagnostics.shared.record(event)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ImportProblem("Strava returned an invalid response.") }
            await AppDiagnostics.shared.record(.responseReceived, status: http.statusCode)
            let maximum = 20 * 1024 * 1024
            guard response.expectedContentLength <= maximum else { throw ImportProblem("This activity is too large for the trial.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximum else { throw ImportProblem("This activity is too large for the trial.") }
                data.append(byte)
            }
            return StravaResponse(status: http.statusCode, data: data)
        } catch let error as ImportProblem { await AppDiagnostics.shared.record(.requestFailed); throw error }
        catch {
            await AppDiagnostics.shared.record(.requestFailed, status: (error as? URLError)?.errorCode)
            throw ImportProblem("The connection to Strava was interrupted. Check your internet connection and try again.")
        }
    }
}

@MainActor @Observable final class StravaConnection: NSObject, ASWebAuthenticationPresentationContextProviding {
    var connected = false
    var busy = false
    var authorising = false
    var message: String?
    var activities: [StravaActivity] = []
    var fetched = false
    var trialDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    private(set) var configuration: StravaConfiguration?
    private var client: StravaClient?
    private var authSession: ASWebAuthenticationSession?
    private var pendingState: String?

    override init() {
        super.init()
        // A private, ignored file is copied ONLY into a locally signed Debug build.
        // Never distribute a bundle containing this developer secret.
        #if DEBUG
        if let url = Bundle.main.url(forResource: "LocalStrava", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let configuration = try? PropertyListDecoder().decode(StravaConfiguration.self, from: data),
           (try? configuration.validate()) != nil {
            self.configuration = configuration
            client = StravaClient(configuration: configuration, store: StravaKeychain(), transport: StravaNetwork.send)
        }
        #endif
    }

    func restore() async {
        await AppDiagnostics.shared.record(.appStarted)
        guard let client else { return }
        do {
            connected = try await client.isConnected()
            if connected { await AppDiagnostics.shared.record(.connectionRestored) }
        } catch { await AppDiagnostics.shared.record(.connectionRestoreFailed); message = error.localizedDescription }
    }

    func connect() {
        guard !busy, !authorising, let configuration else { return }
        let state = UUID().uuidString + UUID().uuidString
        pendingState = state; authorising = true
        Task { await AppDiagnostics.shared.record(.authorisationStarted) }
        do {
            let native = try configuration.authorisationURL(state: state, native: true)
            if UIApplication.shared.canOpenURL(native) {
                Task { await AppDiagnostics.shared.record(.nativeAuthorisationOpened) }
                UIApplication.shared.open(native) { [weak self] opened in
                    Task { @MainActor in if !opened { self?.startWeb(state: state) } }
                }
            } else { startWeb(state: state) }
        } catch { cancel(); message = error.localizedDescription }
    }

    private func startWeb(state: String) {
        guard pendingState == state, let configuration else { return }
        do {
            Task { await AppDiagnostics.shared.record(.webAuthorisationOpened) }
            let url = try configuration.authorisationURL(state: state, native: false)
            authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: StravaConfiguration.callbackScheme) { [weak self] url, _ in
                Task { @MainActor in
                    guard let self, self.pendingState == state else { return }
                    if let url { await self.callback(url) } else { self.cancel() }
                }
            }
            authSession?.presentationContextProvider = self
            if authSession?.start() != true { cancel(); message = "Strava sign-in could not open. Try connecting again." }
        } catch { cancel(); message = error.localizedDescription }
    }

    func callback(_ url: URL) async {
        await AppDiagnostics.shared.record(.callbackReceived)
        guard let state = pendingState, let configuration, let client, !busy else { return }
        pendingState = nil; authorising = false; authSession = nil
        busy = true
        do {
            let code = try configuration.code(from: url, expectedState: state)
            await AppDiagnostics.shared.record(.callbackValidated)
            try await client.connect(code: code)
            await AppDiagnostics.shared.record(.connectionSaved)
            connected = true
            busy = false
            await fetch()
        } catch { await AppDiagnostics.shared.record(.authorisationFailed); busy = false; message = error.localizedDescription }
    }

    func cancel() {
        if pendingState != nil { Task { await AppDiagnostics.shared.record(.authorisationCancelled) } }
        pendingState = nil; authorising = false
        authSession?.cancel(); authSession = nil
    }

    func fetch() async {
        guard !busy, connected, let client else { return }
        busy = true; fetched = false; activities = []
        defer { busy = false }
        do { activities = try await client.activities(on: trialDate); fetched = true; await AppDiagnostics.shared.record(.activitiesLoaded) }
        catch { message = error.localizedDescription }
    }

    func preview(_ activity: StravaActivity, into model: ImportModel) async -> Bool {
        guard !busy, !model.busy, let client else { return false }
        busy = true
        defer { busy = false }
        do {
            let (source, value) = try await client.activity(id: activity.id)
            model.activities = [value]; model.example = false; model.stravaSource = source
            await AppDiagnostics.shared.record(.previewLoaded)
            return true
        } catch { await AppDiagnostics.shared.record(.previewFailed); message = error.localizedDescription; return false }
    }

    func forget() async {
        guard !busy, let client else { return }
        busy = true
        defer { busy = false }
        do {
            cancel()
            try await client.forgetConnection()
            connected = false; activities = []; fetched = false
            await AppDiagnostics.shared.record(.connectionForgotten)
        } catch { message = error.localizedDescription }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
