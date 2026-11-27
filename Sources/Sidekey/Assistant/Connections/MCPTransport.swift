import Foundation

/// A connection that carries JSON-RPC messages to and from one MCP server.
/// Inbound messages and the end of the connection are delivered in order
/// through `onEvent`.
protocol MCPTransport: AnyObject, Sendable {
    func start(onEvent: @escaping @Sendable (MCPTransportEvent) -> Void) async throws
    /// Sends one message before `deadline`. `responseID` is the id of a
    /// request whose response the caller waits for (HTTP reads the reply from
    /// this POST's body). Cancelling the calling task stops the actual I/O.
    /// `authorize` is checked right before the first byte leaves (and the
    /// deadline before every write); when it fails nothing is sent.
    func send(_ message: Data, responseID: Int?, deadline: Date, authorize: @escaping @Sendable () -> Bool) async throws
    /// HTTP needs the negotiated version on every later request.
    func setProtocolVersion(_ version: String)
    func close() async
}

extension MCPTransport {
    func send(_ message: Data, responseID: Int?, deadline: Date) async throws {
        try await send(message, responseID: responseID, deadline: deadline, authorize: { true })
    }
}

enum MCPTransportEvent: Sendable {
    case message(Data)
    case closed(MCPError)
}

/// How a local server is started.
struct MCPStdioLaunch: Equatable, Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var directory: URL?
    /// Values masked out of the exit reason shown in Settings.
    var secrets: [String] = []
}

final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    private let launch: MCPStdioLaunch
    private let lock = NSLock()
    private var process: MCPProcess?
    private var closed = false

    init(launch: MCPStdioLaunch) { self.launch = launch }

    func start(onEvent: @escaping @Sendable (MCPTransportEvent) -> Void) async throws {
        let mask = SourceSecretMask(launch.secrets)
        guard !lock.withLock({ closed }) else { throw MCPError.cancelled }
        let process = try MCPProcess(
            executable: launch.executable, arguments: launch.arguments, environment: launch.environment,
            directory: launch.directory,
            onLine: { onEvent(.message($0)) },
            onExit: { status, line, overflow in
                if overflow { onEvent(.closed(.tooLarge(limit: MCPProcess.maxLineBytes))); return }
                // Masked whole, then clipped: no fragment of a value survives the clip.
                onEvent(.closed(.exited(status: status, detail: line.map { String(mask($0).prefix(200)) })))
            })
        // Closed while starting: the late process is stopped, never kept.
        let keep = lock.withLock { () -> Bool in
            guard !closed else { return false }
            self.process = process
            return true
        }
        guard keep else { process.stop(); throw MCPError.cancelled }
    }

    func send(_ message: Data, responseID: Int?, deadline: Date, authorize: @escaping @Sendable () -> Bool) async throws {
        guard let process = lock.withLock({ self.process }) else { throw MCPError.notConnected }
        let cancelled = MCPCancelFlag()
        try await withTaskCancellationHandler {
            try await process.write(message, deadline: deadline, isCancelled: { cancelled.isSet }, authorize: authorize)
        } onCancel: { cancelled.raise() }
    }

    func setProtocolVersion(_ version: String) {}

    func close() async {
        guard let process = lock.withLock({ () -> MCPProcess? in closed = true; return self.process }) else { return }
        process.stop()
        await Task.detached { process.waitUntilStopped() }.value
    }

}

/// Streamable HTTP (MCP 2025-03-26 and later): each message is a POST; the
/// reply is JSON or a short server-sent event stream. Static headers carry the
/// token, only to this origin: a redirect to another origin is refused.
final class MCPHTTPTransport: NSObject, MCPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    static let maxResponseBytes = 16 * 1_048_576

    let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var sessionID: String?
    /// The session is fixed by the first answer (initialize); a later answer
    /// naming another session ends this client, so tools approved on one
    /// session are never called on another.
    private var answered = false
    private var protocolVersion: String?
    private var onEvent: (@Sendable (MCPTransportEvent) -> Void)?
    private var closed = false

    init(url: URL, headers: [String: String], session: URLSession = .shared) {
        self.url = url; self.headers = headers; self.session = session
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), url.user == nil,
              url.password == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    func start(onEvent: @escaping @Sendable (MCPTransportEvent) -> Void) async throws {
        guard Self.isAllowed(url) else { throw MCPError.insecureURL }
        let started = lock.withLock { () -> Bool in
            guard !closed else { return false }
            self.onEvent = onEvent
            return true
        }
        guard started else { throw MCPError.cancelled }
    }

    func setProtocolVersion(_ version: String) { lock.withLock { protocolVersion = version } }

    func send(_ message: Data, responseID: Int?, deadline: Date, authorize: @escaping @Sendable () -> Bool) async throws {
        guard let deliver = lock.withLock({ onEvent }) else { throw MCPError.notConnected }
        let seconds = MCPDeadline.seconds(until: deadline)
        guard deadline.timeIntervalSinceNow > 0 else { throw MCPError.timedOut(seconds: seconds) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: max(1, deadline.timeIntervalSinceNow))
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (session, version) = lock.withLock { (sessionID, protocolVersion) }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        let bytes: URLSession.AsyncBytes, response: URLResponse
        // The send boundary: nothing leaves after a revocation or the deadline.
        guard authorize() else { throw MCPError.notAllowed }
        guard deadline.timeIntervalSinceNow > 0 else { throw MCPError.timedOut(seconds: seconds) }
        do { (bytes, response) = try await self.session.bytes(for: request, delegate: self) }
        catch is CancellationError { throw MCPError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw MCPError.cancelled }
        catch { throw MCPError.network }
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
        let offered = http.value(forHTTPHeaderField: "Mcp-Session-Id").flatMap { $0.isEmpty ? nil : $0 }
        let sameSession = lock.withLock { () -> Bool in
            defer { answered = true }
            guard let offered else { return true }
            if sessionID == nil, !answered { sessionID = offered; return true }
            return sessionID == offered
        }
        guard sameSession else { bytes.task.cancel(); throw MCPError.sessionExpired }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw MCPError.unauthorized(status: http.statusCode)
        case 404 where session != nil: throw MCPError.sessionExpired
        case 300..<400: throw MCPError.redirectRefused
        default: throw MCPError.httpStatus(http.statusCode)
        }
        guard responseID != nil, http.statusCode != 202 else { return }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        var total = 0
        if type.contains("text/event-stream") {
            var line = Data(), eventData = Data()
            func dispatch() -> Bool {
                defer { eventData.removeAll() }
                guard !eventData.isEmpty else { return false }
                deliver(.message(eventData))
                return Self.isResponse(eventData, id: responseID)
            }
            for try await byte in bytes {
                total += 1
                guard total <= Self.maxResponseBytes else { throw MCPError.tooLarge(limit: Self.maxResponseBytes) }
                if total % 4096 == 0, deadline.timeIntervalSinceNow <= 0 { throw MCPError.timedOut(seconds: seconds) }
                guard byte == 10 else { if byte != 13 { line.append(byte) }; continue }
                if line.isEmpty { if dispatch() { return } }
                else if line.starts(with: Data("data:".utf8)) {
                    var value = line.dropFirst(5)
                    if value.first == 32 { value = value.dropFirst() }
                    if !eventData.isEmpty { eventData.append(10) }
                    eventData.append(contentsOf: value)
                }
                line.removeAll(keepingCapacity: true)
            }
            _ = dispatch()
        } else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                guard body.count <= Self.maxResponseBytes else { throw MCPError.tooLarge(limit: Self.maxResponseBytes) }
                if body.count % 4096 == 0, deadline.timeIntervalSinceNow <= 0 { throw MCPError.timedOut(seconds: seconds) }
            }
            guard !body.isEmpty else { return }
            deliver(.message(body))
        }
    }

    func close() async {
        let id = lock.withLock { () -> String? in
            defer { sessionID = nil; onEvent = nil; closed = true }
            return sessionID
        }
        guard let id else { return }
        // Best effort: tell the server the session is over.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "DELETE"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id")
        // Bounded: the status is enough, the body is never read.
        let session = self.session
        _ = try? await MCPDeadline.run(until: Date().addingTimeInterval(3), timeout: .timedOut(seconds: 3)) { [self] in
            let (bytes, _) = try await session.bytes(for: request, delegate: self)
            bytes.task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let same = request.url?.scheme == url.scheme && request.url?.host == url.host && request.url?.port == url.port
        completionHandler(same ? request : nil)
    }

    private static func isResponse(_ data: Data, id: Int?) -> Bool {
        guard let id, let value = try? MCPValue.decode(data) else { return false }
        let messages = value.array ?? [value]
        return messages.contains { $0["id"]?.int == id && ($0["result"] != nil || $0["error"] != nil) }
    }
}
