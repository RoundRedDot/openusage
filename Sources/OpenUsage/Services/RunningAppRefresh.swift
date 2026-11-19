import Foundation

enum RunningAppRefreshResult: Sendable {
    /// The menu-bar app performed the refresh and returned its limits envelope.
    case handled(UsageReadResult)
    /// Nothing is listening on the local API. The caller may refresh on its own.
    case unavailable
    /// The running app answered, and the id names no card it knows.
    case unknownProvider(String)
    /// A request reached an app and did not produce a limits envelope. The caller must not
    /// start a second refresh.
    case failed(String)
}

/// Asks the running menu-bar app to rediscover accounts and force-refresh. Used by
/// `openusage --force` so the CLI and the menu bar cannot publish two different account sets.
enum RunningAppRefreshClient {
    static func request(providerID: String?) async -> RunningAppRefreshResult {
        let path = providerID.map { "/v1/refresh/\($0)" } ?? "/v1/refresh"
        let url = URL(string: "http://127.0.0.1:\(LocalUsageServer.port)\(path)")
        guard let url else {
            return classify(url: nil, providerID: providerID)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("1", forHTTPHeaderField: LocalUsageServer.refreshHeader)
        // A provider fetch is allowed to take the store's 120s deadline. Stay above that so a slow
        // account is the app's result, not a second refresh started in this process.
        request.timeoutInterval = 150
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return classify(url: url, error: error, providerID: providerID)
        }
        return classify(url: url, response: response, data: data, providerID: providerID)
    }

    /// Decides whether `--force` may refresh in this process. Only a missing address is decided
    /// here before the request; connection refusal is the one transport failure that means nothing
    /// is listening. A timeout, an unreadable response, or any HTTP status other than 200 or 404
    /// means an app was reached.
    static func classify(
        url: URL?,
        error: Error? = nil,
        response: URLResponse? = nil,
        data: Data = Data(),
        providerID: String? = nil
    ) -> RunningAppRefreshResult {
        guard url != nil else {
            return .failed("The local refresh address is invalid.")
        }
        if let error {
            return classify(error: error)
        }
        guard let response else {
            return .failed("The running app returned no response.")
        }
        guard let http = response as? HTTPURLResponse else {
            return .failed("The running app returned a response the client could not read.")
        }
        if http.statusCode == 404 {
            return .unknownProvider(providerID ?? "")
        }
        if http.statusCode == 200 {
            return .handled(UsageReadResult(data: data, warnings: warnings(in: data)))
        }
        if (500...599).contains(http.statusCode) {
            return .failed("The running app failed the refresh (HTTP \(http.statusCode)).")
        }
        return .failed("The running app rejected the refresh (HTTP \(http.statusCode)).")
    }

    private static func classify(error: Error) -> RunningAppRefreshResult {
        if isConnectionRefused(error) {
            return .unavailable
        }
        let urlError = error as? URLError
        if urlError?.code == .timedOut {
            return .failed("The running app did not finish the refresh before the client timed out.")
        }
        if urlError?.code == .badServerResponse || urlError?.code == .cannotParseResponse {
            return .failed("The running app returned a response the client could not read.")
        }
        return .failed("The running app could not complete the refresh (\(error.localizedDescription)).")
    }

    private static func isConnectionRefused(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .cannotConnectToHost {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(POSIXErrorCode.ECONNREFUSED.rawValue) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return isConnectionRefused(underlying)
        }
        return false
    }

    static func warnings(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]]
        else { return [] }
        return errors.compactMap { error in
            guard let id = error["providerId"] as? String, let message = error["message"] as? String else {
                return nil
            }
            return "\(id): \(message)"
        }
    }
}
