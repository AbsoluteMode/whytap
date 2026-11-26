import Foundation

/// A connection that carries JSON-RPC messages to and from one MCP server.
/// Inbound messages and the end of the connection are delivered in order
/// through `onEvent`.
protocol MCPTransport: AnyObject, Sendable {
    func start(onEvent: @escaping @Sendable (MCPTransportEvent) -> Void) async throws
    /// Sends one message. `responseID` is the id of a request whose response
    /// the caller waits for (HTTP reads the reply from this POST's body).
    func send(_ message: Data, responseID: Int?) async throws
    /// HTTP needs the negotiated version on every later request.
    func setProtocolVersion(_ version: String)
    func close() async
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

    init(launch: MCPStdioLaunch) { self.launch = launch }

    func start(onEvent: @escaping @Sendable (MCPTransportEvent) -> Void) async throws {
        let secrets = launch.secrets.filter { $0.count >= 4 }
        let process = try MCPProcess(
            executable: launch.executable, arguments: launch.arguments, environment: launch.environment,
            directory: launch.directory,
            onLine: { onEvent(.message($0)) },
            onExit: { status, line, overflow in
                if overflow { onEvent(.closed(.tooLarge(limit: MCPProcess.maxLineBytes))); return }
                onEvent(.closed(.exited(status: status, detail: line.map { Self.mask($0, secrets: secrets) })))
            })
        lock.withLock { self.process = process }
    }

    func send(_ message: Data, responseID: Int?) async throws {
        guard let process = lock.withLock({ self.process }) else { throw MCPError.notConnected }
        try process.write(message)
    }

    func setProtocolVersion(_ version: String) {}

    func close() async {
        guard let process = lock.withLock({ self.process }) else { return }
        process.stop()
        await Task.detached { process.waitUntilStopped() }.value
    }

    /// Replaces each known secret value, so an echoed token never reaches the UI.
    static func mask(_ text: String, secrets: [String]) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••") }
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
    private var protocolVersion: String?
    private var onEvent: (@Sendable (MCPTransportEvent) -> Void)?

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
        lock.withLock { self.onEvent = onEvent }
    }

    func setProtocolVersion(_ version: String) { lock.withLock { protocolVersion = version } }

    func send(_ message: Data, responseID: Int?) async throws {
        guard let deliver = lock.withLock({ onEvent }) else { throw MCPError.notConnected }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (session, version) = lock.withLock { (sessionID, protocolVersion) }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await self.session.bytes(for: request, delegate: self) }
        catch is CancellationError { throw MCPError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw MCPError.cancelled }
        catch { throw MCPError.network }
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !id.isEmpty { lock.withLock { sessionID = id } }
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
            }
            guard !body.isEmpty else { return }
            deliver(.message(body))
        }
    }

    func close() async {
        let id = lock.withLock { () -> String? in
            defer { sessionID = nil; onEvent = nil }
            return sessionID
        }
        guard let id else { return }
        // Best effort: tell the server the session is over.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "DELETE"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await session.data(for: request, delegate: self)
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
