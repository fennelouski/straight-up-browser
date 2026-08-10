#if os(macOS)
import Foundation
import Network

/// A one-shot OAuth callback receiver for native-app MCP authorization.
///
/// The listener is deliberately IPv4-loopback-only, uses an OS-assigned
/// ephemeral port, accepts bounded HTTP headers, and closes as soon as the
/// exact redirect and OAuth state are observed. No authorization value is
/// logged or persisted here.
nonisolated final class BrowserAgentMCPLoopbackAuthorizationListener: @unchecked Sendable {
    static let callbackPath = "/oauth/callback"
    static let registrationRedirectURI = URL(string: "http://127.0.0.1/oauth/callback")!

    private static let maximumHeaderBytes = 16 * 1_024
    private static let maximumRequests = 24

    private final class ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "com.nathanfennel.browser.mcp-oauth-loopback")
    private let listener: NWListener
    private var redirectURIStorage: URL?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var expectedState: String?
    private var timeoutWorkItem: DispatchWorkItem?
    private var requestCount = 0
    private var finished = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionLimit = 8
    }

    var redirectURI: URL? {
        queue.sync { redirectURIStorage }
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard readyContinuation == nil, redirectURIStorage == nil, !finished else {
                        continuation.resume(throwing: MCPConnectionError.transportFailure)
                        return
                    }
                    readyContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.handleListenerState(state)
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: queue)
                }
            }
        } onCancel: {
            cancel(with: .authorizationDenied)
        }
    }

    func waitForCallback(expectedState: String, timeout: Duration = .seconds(300)) async throws -> URL {
        guard !expectedState.isEmpty else { throw MCPConnectionError.authorizationStateMismatch }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard redirectURIStorage != nil,
                          callbackContinuation == nil,
                          !finished else {
                        continuation.resume(throwing: MCPConnectionError.transportFailure)
                        return
                    }
                    self.expectedState = expectedState
                    callbackContinuation = continuation
                    let timeoutMilliseconds = max(1, Int((timeout.timeInterval * 1_000).rounded()))
                    let workItem = DispatchWorkItem { [weak self] in
                        self?.finish(.failure(MCPConnectionError.timeout(
                            milliseconds: timeoutMilliseconds
                        )))
                    }
                    timeoutWorkItem = workItem
                    queue.asyncAfter(deadline: .now() + timeout.timeInterval, execute: workItem)
                }
            }
        } onCancel: {
            cancel(with: .authorizationDenied)
        }
    }

    func cancel(with error: MCPConnectionError = .authorizationDenied) {
        queue.async { [self] in
            finish(.failure(error))
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch state {
        case .ready:
            guard let port = listener.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(Self.callbackPath)") else {
                finish(.failure(MCPConnectionError.transportFailure))
                return
            }
            redirectURIStorage = url
            readyContinuation?.resume(returning: url)
            readyContinuation = nil
        case .failed:
            finish(.failure(MCPConnectionError.transportFailure))
        case .cancelled:
            if !finished { finish(.failure(MCPConnectionError.transportFailure)) }
        case .setup, .waiting:
            break
        @unknown default:
            finish(.failure(MCPConnectionError.transportFailure))
        }
    }

    private func accept(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else {
            connection.cancel()
            return
        }
        requestCount += 1
        guard requestCount <= Self.maximumRequests else {
            connection.cancel()
            finish(.failure(MCPConnectionError.transportFailure))
            return
        }
        let box = ConnectionBox(connection)
        connection.start(queue: queue)
        receiveRequest(on: box, accumulated: Data())
    }

    private func receiveRequest(on box: ConnectionBox, accumulated: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        let remaining = Self.maximumHeaderBytes - accumulated.count
        guard remaining > 0 else {
            reject(box.connection)
            return
        }
        box.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: remaining
        ) { [weak self, box] content, _, isComplete, error in
            guard let self else {
                box.connection.cancel()
                return
            }
            var received = accumulated
            if let content { received.append(content) }
            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.handleRequest(received, on: box.connection)
            } else if error != nil || isComplete || received.count >= Self.maximumHeaderBytes {
                self.reject(box.connection)
            } else {
                self.receiveRequest(on: box, accumulated: received)
            }
        }
    }

    private func handleRequest(_ data: Data, on connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let callback = validatedCallback(from: data) else {
            reject(connection)
            return
        }
        respond(
            status: "200 OK",
            message: "Authorization complete. You can close this window and return to Straight Up Browser.",
            on: connection
        )
        finish(.success(callback))
    }

    private func validatedCallback(from data: Data) -> URL? {
        guard let headerBoundary = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerBoundary.lowerBound], encoding: .utf8),
              !headerText.unicodeScalars.contains(where: { $0.value == 0 }),
              let redirectURIStorage,
              let expectedState else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              requestParts[0] == "GET",
              requestParts[2] == "HTTP/1.1",
              requestParts[1].first == "/",
              !requestParts[1].hasPrefix("//"),
              !requestParts[1].contains("#") else { return nil }

        let hostValues = lines.dropFirst().compactMap { line -> String? in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare("Host") == .orderedSame else { return nil }
            return line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard hostValues.count == 1,
              let expectedPort = redirectURIStorage.port,
              hostValues[0] == "127.0.0.1:\(expectedPort)",
              let callback = URL(string: "http://\(hostValues[0])\(requestParts[1])"),
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == "http",
              components.host == "127.0.0.1",
              components.port == expectedPort,
              components.percentEncodedPath == Self.callbackPath,
              components.fragment == nil,
              components.user == nil,
              components.password == nil else { return nil }

        let stateValues = (components.queryItems ?? [])
            .filter { $0.name == "state" }
            .compactMap(\.value)
        guard stateValues == [expectedState] else { return nil }
        return callback
    }

    private func reject(_ connection: NWConnection) {
        respond(
            status: "400 Bad Request",
            message: "Authorization callback rejected. Return to Straight Up Browser and try again.",
            on: connection
        )
    }

    private func respond(status: String, message: String, on connection: NWConnection) {
        let body = "<!doctype html><meta charset=\"utf-8\"><title>Straight Up Browser</title><p>\(message)</p>"
        let bodyData = Data(body.utf8)
        let headers = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Cache-Control: no-store\r
        Content-Security-Policy: default-src 'none'; frame-ancestors 'none'; base-uri 'none'\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        \r

        """
        var payload = Data(headers.utf8)
        payload.append(bodyData)
        let box = ConnectionBox(connection)
        connection.send(content: payload, completion: .contentProcessed { _ in
            box.connection.cancel()
        })
    }

    private func finish(_ result: Result<URL, Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        if let readyContinuation {
            self.readyContinuation = nil
            readyContinuation.resume(with: result)
        }
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(with: result)
        }
    }
}

private extension Duration {
    nonisolated var timeInterval: TimeInterval {
        let parts = components
        let seconds = Double(parts.seconds)
        let attoseconds = Double(parts.attoseconds) / 1_000_000_000_000_000_000
        return max(0, seconds + attoseconds)
    }
}
#endif
