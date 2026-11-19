import Foundation
import Network

/// Loopback-only HTTP/1.1 listener for the usage API on `127.0.0.1:6736`. Starts with
/// the app; when the port is already taken the feature is silently disabled for the session
/// (matching the original app). At most 16 requests are served concurrently — beyond that a
/// connection gets `503 {"error":"server_busy"}` immediately.
///
/// Reads stay `GET`. `POST /v1/refresh` is the one-shot CLI's explicit refresh, and only when
/// the request carries `X-OpenUsage-Refresh`. That header is not listed for CORS, so a browser
/// page cannot trigger a refresh.
@MainActor
final class LocalUsageServer {
    nonisolated static let port: UInt16 = 6736
    nonisolated static let refreshHeader = "X-OpenUsage-Refresh"
    private static let maxConcurrentConnections = 16
    private static let headLimit = 8192

    enum Action: Equatable {
        case refresh(String?)
        case respond(method: String, path: String)
        case rejectMethod
    }

    private let state: @MainActor () -> LocalUsageAPI.State
    var performRefresh: (@MainActor (String?) async -> LocalUsageAPI.Response)?
    private let queue = DispatchQueue(label: "openusage.local-api")
    private var listener: NWListener?
    private var activeConnections = 0

    init(
        state: @escaping @MainActor () -> LocalUsageAPI.State,
        performRefresh: (@MainActor (String?) async -> LocalUsageAPI.Response)? = nil
    ) {
        self.state = state
        self.performRefresh = performRefresh
    }

    /// Classifies a request head. `refresh` is only a POST whose header value is `1`.
    static func action(for head: String) -> Action {
        let (method, path) = parseRequestLine(head)
        let segments = path.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "/")
            .map(String.init)
        let isRefresh = segments.count == 2 && segments[0] == "v1" && segments[1] == "refresh"
            || segments.count == 3 && segments[0] == "v1" && segments[1] == "refresh"
        guard isRefresh else { return .respond(method: method, path: path) }
        guard method == "POST", headerValue(refreshHeader, in: head) == "1" else { return .rejectMethod }
        return .refresh(segments.count == 3 ? segments[2] : nil)
    }

    private static func headerValue(_ name: String, in head: String) -> String? {
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let field = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard field.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: Self.port)!
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            AppLog.info(.localAPI, "disabled: \(error.localizedDescription)")
            return
        }

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                // Most commonly the port is already in use — silently disable for this session.
                AppLog.info(.localAPI, "disabled: \(error.localizedDescription)")
            }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        guard activeConnections < Self.maxConcurrentConnections else {
            Self.send(LocalUsageAPI.busy, over: connection)
            return
        }
        activeConnections += 1
        receiveHead(connection, buffered: Data())
    }

    /// Reads until the end of the request head (`\r\n\r\n`). GET/OPTIONS bodies are irrelevant,
    /// so the head is all the router needs.
    private func receiveHead(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headLimit) { data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffered = buffered
                if let data {
                    buffered.append(data)
                }
                if let headEnd = buffered.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buffered[..<headEnd.lowerBound], encoding: .utf8) ?? ""
                    let response = await self.route(head: head)
                    self.finish(connection, with: response)
                } else if error != nil || isComplete || buffered.count >= Self.headLimit {
                    self.finish(connection, with: nil)
                } else {
                    self.receiveHead(connection, buffered: buffered)
                }
            }
        }
    }

    private func route(head: String) async -> LocalUsageAPI.Response {
        switch Self.action(for: head) {
        case .refresh(let token):
            AppLog.debug(.localAPI, "POST /v1/refresh")
            guard let performRefresh else {
                return LocalUsageAPI.respond(method: "POST", path: "/v1/refresh", state: state())
            }
            return await performRefresh(token)
        case .rejectMethod:
            AppLog.debug(.localAPI, "POST /v1/refresh rejected")
            return LocalUsageAPI.Response(status: 405, body: Data(#"{"error":"method_not_allowed"}"#.utf8))
        case .respond(let method, let path):
            // Path is secret-free (the loopback API serves only normalized usage); Debug-only.
            AppLog.debug(.localAPI, "\(method) \(path)")
            return LocalUsageAPI.respond(method: method, path: path, state: state())
        }
    }

    /// Parse the HTTP request line into `(method, path)`. Tolerates an empty/malformed head: a
    /// request that begins with `\r\n\r\n`, or carries invalid UTF-8 (decoded to `""` at the call
    /// site), yields no request line — which must route to a normal `404` rather than trap. The
    /// previous `head.split(...)[0]` force-index crashed the whole `@MainActor` menu-bar process on
    /// any such loopback payload. `nonisolated` + pure so it's unit-testable without the listener.
    nonisolated static func parseRequestLine(_ head: String) -> (method: String, path: String) {
        guard let requestLine = head.split(separator: "\r\n", maxSplits: 1).first else {
            return ("", "/")
        }
        let parts = requestLine.split(separator: " ")
        let method = parts.indices.contains(0) ? String(parts[0]) : ""
        let path = parts.indices.contains(1) ? String(parts[1]) : "/"
        return (method, path)
    }

    private func finish(_ connection: NWConnection, with response: LocalUsageAPI.Response?) {
        activeConnections -= 1
        if let response {
            Self.send(response, over: connection)
        } else {
            connection.cancel()
        }
    }

    private nonisolated static func send(_ response: LocalUsageAPI.Response, over connection: NWConnection) {
        let reason: String = switch response.status {
        case 200: "OK"
        case 204: "No Content"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 503: "Service Unavailable"
        default: "OK"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Connection: close\r\n"
        if let body = response.body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            head += "Content-Length: 0\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
